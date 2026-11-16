import Foundation
import TwitchKit
import ChatModel
import EmoteSources
import Core
import os

private let logger = AppLogger.make("Channels.ChannelSession")

/// Instruments intervals for the session half of the message pipeline:
/// `renormalize` (stale ring rows refreshed on subscribe) here, plus
/// `normalize` (per live message / per history batch, in
/// `ChannelUpdateNormalizer`) and `deliver` (one post to every subscriber's
/// mailbox, in `ChannelUpdateHub`) under the same category. Pair with
/// `Features.ChatTranscriptModel`'s `apply-batch` interval for the
/// main-actor half.
private let signposter = AppLogger.signposter("Channels.Pipeline")

/// Owns one chat session for a (account × channel) pair.
///
/// ## Pipeline
///
/// ```
/// EventSub socket ─▶ registry dispatcher (detached) ─▶ ChannelEventRouter
///     ─▶ this session's inbox ─▶ handle(event:) [translate + normalize ONCE]
///     ─▶ emit: ring append + post to each subscriber's mailbox (no waiting)
///     ─▶ subscriber drains a batch per hop (ChatTranscriptModel: main actor)
/// ```
///
/// - **Canonical state**: a ring buffer (cap = the Chat History setting) of
///   display-ready `ChannelUpdate`s. Messages are normalized HERE, off the
///   main actor, once per channel — every tab showing the channel shares the
///   same rows, and re-priming a tab is a copy, not a re-tokenize.
///
/// - **Delivery**: each subscriber owns a `ChannelSubscription` mailbox. The
///   session posts and moves on; it never awaits a subscriber, so a slow or
///   stalled consumer can only back up its own mailbox (bounded — see
///   `ChannelSubscription`). Consumers drain everything queued since their
///   last drain as one batch.
///
/// - **Atomic prime + subscribe**: `subscribe()` registers the mailbox AND
///   returns a snapshot of the ring in one actor turn, so a new subscriber
///   can never observe a gap between "rows I primed with" and "rows posted
///   to me." Every mutation that posts (`emit`) is likewise synchronous, so
///   a multi-row batch (a reconnect gap-fill) lands contiguously.
///
/// Why `actor` (not `@MainActor`): ChannelSession operates only on `String`
/// IDs and value types — no `@MainActor` SwiftUI dependencies. Its isolation
/// domain is where the per-message work (translate, normalize, ring append)
/// happens; the main actor only ever sees finished batches.
public actor ChannelSession {

    /// One EventSub event, translated and filtered to this channel — the
    /// raw input to normalization (see `makeUpdate(for:receivedAt:)`).
    /// Internal: subscribers receive `ChannelUpdate`s, never these.
    enum ChannelEvent: Sendable {
        /// A regular chat message, live over EventSub.
        case message(ChatMessage)

        /// A `channel.chat.notification` event — subs, resubs, gift subs,
        /// raids (notification variant), announcements, etc. The Normalizer
        /// (in ChatModel) decodes this into one of `ChatLine.Kind`'s bubble
        /// cases based on `noticeType`.
        case notification(EventSubChatNotification)

        /// A `channel.raid` event — someone raided INTO this channel.
        /// Distinct from `.notification(raid)` which is the older
        /// notification-topic variant; both render as raid bubbles.
        case raid(EventSubRaid)

        /// A `channel.chat.message_delete` event — a moderator deleted one
        /// specific message. Consumers find the matching `ChatLine` by
        /// `targetMessageId` and flip its kind to `.deletedPlaceholder`.
        /// (The actor stores this in the ring so late subscribers see
        /// pre-deleted state too.)
        case messageDeleted(targetMessageId: String)

        /// A `channel.chat.clear` event — the entire chat was cleared
        /// (typically by a mod or chat-clear button). Consumers flip
        /// every existing message to `.deletedPlaceholder`.
        case chatCleared

        /// A `channel.chat.clear_user_messages` event — a moderator
        /// timed out / banned a user, hiding all their prior messages.
        /// Consumers flip every message from `targetUserId` to deleted.
        case messagesClearedFromUser(targetUserId: String)

        /// A `channel.chat_settings.update` event — the broadcaster (or
        /// a mod) changed chat settings mid-stream (toggled slow mode,
        /// enabled followers-only, etc). Consumers update their cached
        /// restrictions snapshot so the compose bar's inline strip
        /// stays accurate without a tab reopen.
        case restrictionsUpdated(ChatRestrictions)

        /// The signed-in account's mod status in this channel changed
        /// mid-session. Emitted from two `channel.moderate` v2 signals
        /// (see `enableModerationEvents`):
        ///   - a `mod`/`unmod` action targeting OUR account → true/false.
        ///   - Twitch revoking our `channel.moderate` subscription →
        ///     false (Twitch revokes it when the subscriber stops being
        ///     a mod, so revocation IS the unmod signal when the action
        ///     event loses the race or doesn't arrive).
        /// Consumers flip `currentUserCanModerate`; no row is produced.
        case moderationStatusChanged(canModerate: Bool)
    }

    private let client: TwitchClient
    /// Public + `nonisolated` because it's set once at init and never
    /// changes. Callers outside the actor (e.g. `ChatTranscriptModel` reading
    /// it to key `DraftStorage` lookups) can read without hopping the
    /// actor boundary.
    public nonisolated let channelId: String
    private let channelLoginName: String
    private let accountUserId: String

    /// Builds display-ready rows from translated events and history, against
    /// the session account's login and the channel's emote index. See
    /// `ChannelUpdateNormalizer`.
    private let normalizer: ChannelUpdateNormalizer

    /// The ring of display-ready updates (capped at the Chat History
    /// setting), the join-backfill buffering window in front of it, and the
    /// subscriber mailboxes it fans out to. Every update reaches it through
    /// `emit`. See `ChannelUpdateHub`.
    private var hub: ChannelUpdateHub

    /// IDs of active EventSub subscriptions, captured from the records that
    /// `subscribe(...)` returns. We track all of them (chat.message + chat
    /// notification + raid + delete + clear + clear_user_messages) so
    /// `stop()` can unsubscribe each individually.
    ///
    /// nil entries are tolerable: if a subscribe call hits `.conflict` we
    /// don't get a record back, but Twitch keeps the subscription alive on
    /// our WebSocket. Twitch will garbage-collect it when the WebSocket
    /// disconnects.
    private var activeSubscriptionIds: [String] = []

    /// The non-blocking chat-restrictions fetch kicked off by `start()`. Stored
    /// so `stop()` can cancel it — otherwise the fire-and-forget Task strongly
    /// retains this actor (plus its event ring) until the Helix round-trip
    /// resolves, leaving a zombie session alive across a fast channel switch.
    private var chatRestrictionsTask: Task<Void, Never>?

    /// Called by `start()` when EventSub subscribe returns unauthorized.
    /// Injected at construction time by `ChannelSessionRegistry` so this actor
    /// doesn't need to know about `AccountStore` or `Account` directly.
    private let refreshTokenHandler: @Sendable () async throws -> Void

    /// Fetches recent chat history (channelLogin, limit) → messages with
    /// their send times. Defaults to `BackfillProvider.fetchRecentMessages`;
    /// tests inject a stub so the join-backfill and reconnect-resync actor
    /// paths run without network. Same closure-injection pattern as
    /// `refreshTokenHandler`.
    private let fetchBackfill: @Sendable (String, Int) async -> [BackfillMessage]

    /// How long `start()` waits for join history, measured from when the
    /// fetch began, before exposing the session without it (late history is
    /// merged in afterwards). Injected so tests can use a short deadline.
    private let joinBackfillTimeout: Duration

    /// True while a `channel.moderate` v2 subscription is live (or being
    /// created) for this session. Makes `enableModerationEvents()`
    /// idempotent — every mod-status path in every attached tab calls it
    /// on promotion, and only the first should subscribe. Reset by
    /// `handle(event:)` on a `.moderationStatusChanged(false)` so a
    /// re-promotion after an unmod/revocation can re-subscribe.
    private var moderationEventsEnabled = false

    public init(
        client: TwitchClient,
        channelId: String,
        channelLoginName: String,
        accountUserId: String,
        accountLogin: String = "",
        ringCapacity: Int = 500,
        emoteIndex: EmoteIndex? = nil,
        refreshTokenHandler: @escaping @Sendable () async throws -> Void = {
            throw AppError(message: "ChannelSession constructed without refreshTokenHandler")
        },
        fetchBackfill: @escaping @Sendable (String, Int) async -> [BackfillMessage] = { login, limit in
            await BackfillProvider.fetchRecentMessages(channelLogin: login, limit: limit)
        },
        joinBackfillTimeout: Duration = .seconds(3)
    ) {
        self.client = client
        self.channelId = channelId
        self.channelLoginName = channelLoginName
        self.accountUserId = accountUserId
        self.normalizer = ChannelUpdateNormalizer(accountLogin: accountLogin, emoteIndex: emoteIndex)
        self.hub = ChannelUpdateHub(capacity: max(1, ringCapacity), channelLoginName: channelLoginName)
        self.refreshTokenHandler = refreshTokenHandler
        self.fetchBackfill = fetchBackfill
        self.joinBackfillTimeout = joinBackfillTimeout
    }

    // MARK: - Lifecycle

    /// Starts the session: connects EventSub (if needed), subscribes to chat
    /// + notification + raid + delete + clear topics, and primes the ring
    /// from rustlog backfill.
    public func start() async throws {
        logger.info("Starting session for #\(self.channelLoginName, privacy: .public) (channelId=\(self.channelId, privacy: .public))")

        // Kick off rustlog backfill in parallel with the WebSocket connect.
        // See BackfillProvider for the design rationale.
        //
        // Ordering (option 2 — subscribe-first + buffer): EventSub is the
        // URGENT thing — we subscribe to live chat BEFORE awaiting the
        // community-history fetch, so live chat connects without waiting on
        // rustlog. While `backfillPending` is true, `handle(event:)` parks
        // incoming live events in `pendingLive` instead of the ring. Once
        // backfill resolves, `applyBackfill` merges history + buffered-live
        // (dedup by messageId) into the ring in one synchronous step.
        //
        // Safety rests on the registry's "expose-late" contract: a session is
        // not returned from `session(...)` (and so cannot be `subscribe()`d
        // by any tab) until `start()` returns. The entire pending window is
        // therefore internal — no subscriber ever observes the empty/partial
        // ring, preserving the atomic prime+subscribe invariant.
        //
        // The history wait is BOUNDED (`joinBackfillTimeout`, ~3s from here):
        // a slow or hung history host no longer holds the channel closed.
        // Past the deadline the session is exposed with live chat only and
        // the history merges in above it when (if) it lands — see
        // `finishJoinBackfill` / `mergeLateBackfill`.
        beginJoinBackfill()

        try await client.eventSub.connect()

        // Subscribe to the EventSub topics we render. The core chat.message
        // subscription throws on failure (no chat = unusable session); the
        // others swallow errors (enrichment, not core function). From the
        // moment chat.message succeeds, the registry's dispatcher routes
        // events to `handle(event:)`, which buffers them while backfill is
        // pending.
        try await subscribeToChat()

        // The six enrichment topics are independent Helix POSTs, none of which
        // gates the first rendered frame (chat.message above is the only
        // required one). Firing them concurrently collapses six serial
        // round-trips into one wall-clock round-trip — the dominant cost on the
        // session-open path. Each call still hops back onto the actor to append
        // its id to `activeSubscriptionIds`, so that mutation stays serialized;
        // only the network waits overlap. We still await the group as a unit so
        // the session isn't exposed until every subscription is live — same
        // guarantee as before, just parallelized.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.subscribeToNotificationTopic(.notification, label: "notification") }
            group.addTask { await self.subscribeToNotificationTopic(.messageDelete, label: "message_delete") }
            group.addTask { await self.subscribeToNotificationTopic(.clear, label: "chat_clear") }
            group.addTask { await self.subscribeToNotificationTopic(.clearUserMessages, label: "clear_user_messages") }
            group.addTask { await self.subscribeToNotificationTopic(.settingsUpdate, label: "settings_update") }
            group.addTask { await self.subscribeToRaid() }
        }

        // Drain backfill and merge — waiting no later than the deadline.
        // Failures are absorbed by BackfillProvider — we never propagate; an
        // empty (or late) backfill just flushes whatever buffered live events
        // accumulated. `applyBackfill` is synchronous (no `await`) so the
        // read-of-pendingLive → build-ring → clear-buffer → flip-flag
        // sequence is atomic with respect to `handle(event:)`.
        await finishJoinBackfill()

        // Fetch chat-settings restrictions WITHOUT blocking session exposure.
        // The restriction strip on the compose bar is enrichment, not part of
        // the first rendered frame, so we no longer pay its Helix round-trip
        // (~150ms) on the critical path. The fetch resolves after `start()`
        // returns and reaches an already-attached tab reactively, via
        // `applyInitialRestrictions`'s `.restrictionsUpdated` fan-out — the same
        // path a live `channel.chat_settings.update` takes. If the fetch happens
        // to resolve before a tab attaches, `attach`'s `currentChatRestrictions()`
        // read picks up the seeded cache instead; either ordering is correct.
        chatRestrictionsTask = Task { [weak self] in await self?.refreshChatRestrictions() }

        // NOTE: We deliberately do NOT iterate `client.eventSub.events` here.
        // That AsyncStream is single-consumer — if every ChannelSession had
        // its own iterator, the events would get split unpredictably between
        // them and messages would silently drop. Instead,
        // `ChannelSessionRegistry` owns one shared dispatcher Task per
        // client that consumes the stream once and routes each event to the
        // matching session via `handle(event:)`.
    }

    /// The core chat.message subscription — required for the session to be
    /// useful. Throws on failure so the registry doesn't keep a session that
    /// can't deliver chat. The other (notification/raid/delete/clear) topics
    /// use `subscribeToNotificationTopic` / `subscribeToRaid` which swallow
    /// errors — those topics are enrichment, not core function.
    private func subscribeToChat() async throws {
        let subscription = EventSubSubscription.Chat.message(
            broadcasterID: channelId,
            userID: accountUserId
        )
        do {
            // Auth-refreshable errors are handled inside `withAuthRetry`
            // (refresh via the bridge, retry once); see its doc comment for
            // the three shapes a stale token takes.
            let record = try await withAuthRetry("EventSub chat.message subscribe") {
                try await client.eventSub.subscribe(subscription)
            }
            activeSubscriptionIds.append(record.id)
        } catch HelixError.conflict {
            // 409 "already subscribed" — Twitch keeps the subscription alive
            // on this WebSocket from a prior session; events still flow.
            logger.info("EventSub already subscribed to channel.chat.message for #\(self.channelLoginName, privacy: .public) — reusing existing subscription (no id captured)")
        }
        logger.info("Subscribed to channel.chat.message for #\(self.channelLoginName, privacy: .public)")
    }

    /// Runs a Helix / EventSub operation; if it fails with an auth-refreshable
    /// error, refreshes tokens via `refreshTokenHandler` and retries ONCE. A
    /// second failure (or a refresh failure) propagates to the caller.
    ///
    /// A stale access token reaches us in one of THREE shapes — not just
    /// `.unauthorized`. In practice `.oauth` is the common one:
    ///   - .unauthorized      — the 401 surfaced to us directly.
    ///   - .oauth(...)        — TwitchKit's HelixClient intercepted the 401,
    ///                          tried its own `/oauth2/token` refresh, and
    ///                          Twitch rejected it ("missing client secret" —
    ///                          we ship no secret; it lives on the Vercel
    ///                          bridge). TwitchKit then wiped its own token
    ///                          store as it threw.
    ///   - .notAuthenticated  — that store-wipe already happened on an earlier
    ///                          call, so the token is simply gone.
    /// All three mean "refresh via the bridge and retry once." This mirrors
    /// `AccountStore.withTokenRefresh`, which nets the same three cases around
    /// the Helix call sites outside this actor. (Previously only the chat
    /// subscribe handled all three; send / delete / chat-settings caught only
    /// `.unauthorized`, so the common `.oauth` shape escaped them.)
    ///
    /// The refresh itself is single-flight in `AccountStore`, so concurrent
    /// retries across sessions share one bridge round-trip.
    @discardableResult
    private func withAuthRetry<T>(
        _ label: String,
        _ operation: () async throws -> T
    ) async throws -> T {
        do {
            return try await operation()
        } catch let error where Self.isAuthRefreshable(error) {
            logger.info("\(label, privacy: .public) needs a token refresh (\(error.localizedDescription, privacy: .public)); refreshing via bridge and retrying once")
            try await refreshTokenHandler()
            return try await operation()
        }
    }

    /// The three `HelixError` shapes a stale (or already-wiped) access token can
    /// take, all of which are recoverable by a bridge refresh + one retry.
    /// Centralizing the predicate keeps `withAuthRetry` in lockstep with
    /// `AccountStore.withTokenRefresh`, which guards every other Helix call site
    /// against exactly these cases.
    private static func isAuthRefreshable(_ error: Error) -> Bool {
        switch error {
        case HelixError.unauthorized, HelixError.oauth, HelixError.notAuthenticated:
            return true
        default:
            return false
        }
    }

    /// Subscribes to one of the chat-related notification topics
    /// (notification, message_delete, clear, clear_user_messages). All use
    /// the same `(broadcasterID, userID)` shape. Failure swallowed — the
    /// session still works without these, just without bubble rendering.
    private enum NotificationKind {
        case notification, messageDelete, clear, clearUserMessages, settingsUpdate

        func subscription(broadcasterID: String, userID: String) -> EventSubSubscription {
            switch self {
            case .notification:       return .Chat.notification(broadcasterID: broadcasterID, userID: userID)
            case .messageDelete:      return .Chat.messageDelete(broadcasterID: broadcasterID, userID: userID)
            case .clear:              return .Chat.clear(broadcasterID: broadcasterID, userID: userID)
            case .clearUserMessages:  return .Chat.clearUserMessages(broadcasterID: broadcasterID, userID: userID)
            case .settingsUpdate:     return .Chat.settingsUpdate(broadcasterID: broadcasterID, userID: userID)
            }
        }
    }

    private func subscribeToNotificationTopic(_ kind: NotificationKind, label: String) async {
        let subscription = kind.subscription(broadcasterID: channelId, userID: accountUserId)
        do {
            let record = try await client.eventSub.subscribe(subscription)
            activeSubscriptionIds.append(record.id)
            logger.info("Subscribed to channel.chat.\(label, privacy: .public) for #\(self.channelLoginName, privacy: .public)")
        } catch HelixError.conflict {
            logger.info("Already subscribed to channel.chat.\(label, privacy: .public) for #\(self.channelLoginName, privacy: .public)")
        } catch {
            // Not fatal — chat still works. Log and move on.
            logger.warning("Failed to subscribe to channel.chat.\(label, privacy: .public) for #\(self.channelLoginName, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Subscribes to `channel.raid` keyed by toBroadcasterID — "raids
    /// arriving at this channel." Failure swallowed for the same reason
    /// as the other notification topics.
    private func subscribeToRaid() async {
        let subscription = EventSubSubscription.Channel.raid(toBroadcasterID: channelId)
        do {
            let record = try await client.eventSub.subscribe(subscription)
            activeSubscriptionIds.append(record.id)
            logger.info("Subscribed to channel.raid for #\(self.channelLoginName, privacy: .public)")
        } catch HelixError.conflict {
            logger.info("Already subscribed to channel.raid for #\(self.channelLoginName, privacy: .public)")
        } catch {
            logger.warning("Failed to subscribe to channel.raid for #\(self.channelLoginName, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Subscribes to `channel.moderate` v2 — the live feed of moderation
    /// actions in this channel, of which chattr currently consumes only
    /// the `mod`/`unmod` actions (and the subscription's own revocation)
    /// to keep `ChatTranscriptModel.currentUserCanModerate` accurate mid-session.
    ///
    /// NOT part of `start()`: Twitch rejects the subscription unless the
    /// `moderator_user_id` user already IS a mod (or the broadcaster) of
    /// the channel, so it can only be created once mod status is
    /// established. `ChatTranscriptModel` calls this from every path that flips
    /// `currentUserCanModerate` true (broadcaster check, moderated-set
    /// seed, badge observation).
    ///
    /// Idempotent: the flag is set synchronously before the first await,
    /// so concurrent calls (two tabs promoting at once — actor reentrancy)
    /// collapse to one subscribe. Failure swallowed like the notification
    /// topics — a 403 here (stale moderated-set cache, or a pre-scope
    /// token missing the `channel.moderate` v2 read bundle) just means
    /// mod status stays attach-time-static, the pre-existing behavior.
    public func enableModerationEvents() async {
        guard !moderationEventsEnabled else { return }
        moderationEventsEnabled = true

        let subscription = EventSubSubscription.Moderation.moderate(
            broadcasterID: channelId,
            moderatorID: accountUserId
        )
        do {
            let record = try await client.eventSub.subscribe(subscription)
            activeSubscriptionIds.append(record.id)
            logger.info("Subscribed to channel.moderate for #\(self.channelLoginName, privacy: .public)")
        } catch HelixError.conflict {
            // Already live on this WebSocket from a prior session — keep
            // the flag, events flow.
            logger.info("Already subscribed to channel.moderate for #\(self.channelLoginName, privacy: .public)")
        } catch {
            // Roll back so a later promotion (e.g. after the user
            // re-signs-in mid-run and picks up the scopes) can retry.
            moderationEventsEnabled = false
            logger.info("Failed to subscribe to channel.moderate for #\(self.channelLoginName, privacy: .public): \(error.localizedDescription, privacy: .public) — mod status stays attach-time-static")
        }
    }

    /// Stops the session: deletes every EventSub subscription on Twitch's
    /// side and clears local state. Subscribers are dropped — the actor
    /// itself is then eligible for deallocation once the registry releases
    /// its reference.
    ///
    /// Each unsubscribe call is best-effort: if it fails (network blip, token
    /// expiry, server error), we still proceed with local cleanup. Twitch will
    /// garbage-collect each subscription when the WebSocket disconnects.
    public func stop() async {
        logger.info("Stopping session for #\(self.channelLoginName, privacy: .public)")

        // Cancel the in-flight restrictions fetch so it stops retaining the
        // actor past teardown (and skips its now-pointless subscriber fan-out).
        chatRestrictionsTask?.cancel()
        chatRestrictionsTask = nil

        // Same for the join-history fetch and its deadline timer, and release
        // a `start()` still parked waiting on them (it then exposes nothing —
        // the registry discards a session stopped mid-start).
        joinBackfillFetch?.cancel()
        joinBackfillFetch = nil
        joinBackfill = .done   // a fetch that completes anyway is not merged
        wakeJoinBackfillWaiter()

        // End every subscriber's stream up front: nothing posted from here on
        // is meant for them, and their consumer loops can wind down while we
        // wait on Twitch below.
        hub.finishAllSubscribers()

        let ids = activeSubscriptionIds
        activeSubscriptionIds = []
        for id in ids {
            do {
                try await client.eventSub.unsubscribe(id: id)
                logger.info("Deleted EventSub subscription \(id, privacy: .public) for #\(self.channelLoginName, privacy: .public)")
            } catch {
                logger.warning("Failed to delete EventSub subscription \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Chat restrictions

    /// Cached restrictions snapshot from the most recent
    /// `refreshChatRestrictions()` call, `channel.chat_settings.update`
    /// EventSub event or local settings PATCH — plus the guard that keeps a
    /// late Helix fetch from clobbering a live update (CR MEDIUM 4). See
    /// `ChatRestrictionsCache`.
    private var restrictionsCache = ChatRestrictionsCache()

    /// Returns the current chat restrictions for this channel, fetching
    /// from Helix on first access and returning the cached value
    /// afterwards. The compose bar in `ChatScreen` reads from this via
    /// `ChatTranscriptModel` to render an inline strip showing what's enabled
    /// (slow mode, followers-only, subscribers-only, etc.).
    ///
    /// Returns nil if the fetch fails — restrictions are bonus polish,
    /// not safety-critical, so the failure case just falls back to "no
    /// restrictions" rather than blocking chat entirely. Twitch will
    /// still return a `dropReason` on `sendChatMessage` if a hidden
    /// restriction blocks the send.
    public func currentChatRestrictions() -> ChatRestrictions? {
        restrictionsCache.value
    }

    /// Refresh the restrictions snapshot from Helix and fan the result out.
    /// Kicked off as a background task by `start()` — deliberately NOT
    /// awaited there, so session exposure doesn't block on this Helix
    /// round-trip (the compose-bar strip is enrichment, not first-frame
    /// critical). The fetched snapshot reaches an already-attached tab
    /// reactively via `applyInitialRestrictions`'s `.restrictionsUpdated`
    /// fan-out — the same path a live `channel.chat_settings.update` takes.
    private func refreshChatRestrictions() async {
        do {
            let settings = try await accountStoreSafeFetch()
            applyInitialRestrictions(ChatRestrictions(from: settings))
            logger.debug("Refreshed chat restrictions for #\(self.channelLoginName, privacy: .public)")
        } catch is CancellationError {
            // Session tear-down racing fetch — silent exit.
        } catch {
            // Non-fatal. Leave whatever was cached (or nil) in place;
            // the user can still chat and Twitch's dropReason will fill
            // in any restriction we miss.
            logger.warning("Failed to fetch chat restrictions: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Commit a start-time restrictions snapshot to the cache and fan it out
    /// to subscribers as `.restrictionsUpdated`, so a tab attached before the
    /// fetch resolved updates its compose-bar strip reactively. Goes through
    /// the same `emit` as `updateChatSettings` / `handle`, so a backgrounded
    /// initial fetch is indistinguishable downstream from a live EventSub update.
    ///
    /// No-ops when:
    ///   - `restrictions` is nil — the Helix fetch failed; leave the cache as is.
    ///   - the cache is already live — a live `chat_settings.update` already
    ///     landed while the fetch was in flight, so the Helix snapshot is older
    ///     than what we hold. Same race guard the awaited refresh used to apply
    ///     inline (CR MEDIUM 4), now that the fetch resolves after exposure.
    ///
    /// Internal (not private) so ChannelsTests can drive the fan-out + guard
    /// offline — same visibility relaxation as `applyBackfill`.
    func applyInitialRestrictions(_ restrictions: ChatRestrictions?) {
        guard let restrictions else { return }
        guard restrictionsCache.applyInitial(restrictions) else {
            logger.debug("Skipping Helix restrictions overwrite — EventSub update already populated cache")
            return
        }
        emit([.restrictionsUpdated(restrictions)])
    }

    /// Wrapper around `fetchChatSettings` with the shared auth-refresh-and-
    /// retry (`withAuthRetry`), matching `send(...)` and `subscribeToChat()`.
    private func accountStoreSafeFetch() async throws -> ChatSettings {
        try await withAuthRetry("fetchChatSettings") {
            try await client.api.fetchChatSettings(broadcasterID: channelId)
        }
    }

    /// The signed-in user's chat name color (GET /chat/color), e.g.
    /// "#FF69B4". Used to stamp optimistic send rows with the right
    /// color BEFORE the first echo of the session teaches us — without
    /// it, the user's first message flashes plain-white for the echo
    /// round-trip (~0.5s). nil on failure or when the user never picked
    /// a color (Twitch returns "" then) — callers fall back to the
    /// echo-taught value.
    public func fetchOwnChatColor() async -> String? {
        do {
            let color = try await client.api.fetchUserChatColors(userIDs: [accountUserId]).first?.color
            return (color?.isEmpty == false) ? color : nil
        } catch {
            // Cosmetic-only data; the echo upgrade corrects the row anyway.
            logger.debug("Own-chat-color fetch failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Update the broadcaster's chat-mode settings (PATCH /chat/settings)
    /// on behalf of the signed-in account, which must be the broadcaster
    /// or a moderator — Twitch enforces that server-side (the UI gates
    /// the controls behind `ChatTranscriptModel.currentUserCanModerate` too).
    /// Requires the `moderator:manage:chat_settings` scope on the token.
    ///
    /// nil parameters are omitted from the PATCH body and left unchanged
    /// on Twitch's side. To enable slow/followers mode with a duration,
    /// pass BOTH the flag and the duration (Twitch's API shape).
    ///
    /// On success the cached restrictions snapshot is replaced with the
    /// PATCH response (the authoritative new state) and a
    /// `.restrictionsUpdated` event fans out to subscribers, so the
    /// compose-bar strip and any open settings UI update instantly
    /// instead of waiting on the EventSub `chat_settings.update` echo.
    /// The echo still arrives and re-applies identical state — both
    /// paths are idempotent.
    @discardableResult
    public func updateChatSettings(
        emoteOnly: Bool? = nil,
        subscribersOnly: Bool? = nil,
        followersOnly: Bool? = nil,
        followersDurationMinutes: Int? = nil,
        slowMode: Bool? = nil,
        slowModeSeconds: Int? = nil
    ) async throws -> ChatRestrictions {
        let update = ChatSettingsUpdate(
            emoteMode: emoteOnly,
            followerMode: followersOnly,
            followerModeDuration: followersDurationMinutes,
            slowMode: slowMode,
            slowModeWaitTime: slowModeSeconds,
            subscriberMode: subscribersOnly
        )
        let settings = try await withAuthRetry("updateChatSettings") {
            try await client.api.updateChatSettings(
                broadcasterID: channelId, moderatorID: accountUserId, with: update
            )
        }

        let restrictions = ChatRestrictions(from: settings)
        restrictionsCache.applyLive(restrictions)

        // Same `emit` as handle(event:), so a local settings change is
        // indistinguishable from an EventSub-delivered one downstream.
        emit([.restrictionsUpdated(restrictions)])
        return restrictions
    }

    // MARK: - Send

    /// Sends a chat message through this session's authenticated user. Wraps
    /// `client.api.sendChatMessage(...)` with a one-shot token-refresh-and-retry
    /// on any auth-refreshable error (`withAuthRetry`), matching
    /// `subscribeToChat()` — sends are short, so we don't go through
    /// `AccountStore.withTokenRefresh` (which is geared at the SwiftData-isolated Account model that doesn't
    /// belong inside this actor).
    ///
    /// Returns the Helix response so the caller can:
    ///   - Inspect `isSent` (a `true` response can still mean "dropped";
    ///     Twitch returns `isSent=false` + a `dropReason` for automod holds,
    ///     rate-limit hits, banned-word triggers, etc.).
    ///   - Read the canonical `messageId` for echo-dedup against the EventSub
    ///     `channel.chat.message` event that arrives ~100ms after a successful
    ///     send.
    ///
    /// Does NOT touch the ring buffer. The send's success is observable via
    /// the EventSub echo, which arrives through the same dispatcher that
    /// drives every other chat event. The send call is fire-then-let-EventSub-
    /// confirm — see `ChatTranscriptModel.send(...)` for the optimistic-insert /
    /// dedup orchestration on top of that.
    public func send(
        _ text: String,
        replyParentMessageId: String? = nil
    ) async throws -> SendChatMessageResponse {
        // Trim leading/trailing whitespace only — preserve internal whitespace
        // so users can put their `:` between word and emote in
        // ":wave: hello :wave:" style messages. Twitch handles the rest.
        let payload = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else {
            throw AppError(message: "Can't send an empty message")
        }
        // Refresh once, retry once. A second auth failure propagates and lets
        // the caller (ChatTranscriptModel.send → ChatScreen) surface the
        // sign-in-expired UX.
        return try await withAuthRetry("sendChatMessage") {
            try await client.api.sendChatMessage(
                broadcasterId: channelId,
                senderId: accountUserId,
                message: payload,
                replyParentMessageId: replyParentMessageId
            )
        }
    }

    // MARK: - Moderation

    /// Deletes a single chat message in this channel. The signed-in
    /// account acts as the moderator — Twitch verifies that the account
    /// is actually a mod (or the broadcaster) of `channelId` before
    /// proceeding; non-mods get `HelixError.unauthorized`.
    ///
    /// Does NOT mutate local state directly. The deletion arrives
    /// through the existing `channel.chat.message_delete` EventSub
    /// subscription as a `.messageDeleted` update — `apply()` in
    /// `ChatTranscriptModel` already flips the corresponding row to
    /// `.deletedPlaceholder` when that arrives, so the visual update
    /// flows through the same path as a moderator's web-UI delete.
    ///
    /// Refresh-and-retry on auth failure (`withAuthRetry`) matches the other
    /// Helix calls (send, fetchChatSettings).
    public func deleteMessage(messageId: String) async throws {
        try await withAuthRetry("deleteChatMessages") {
            try await client.api.deleteChatMessages(
                broadcasterID: channelId,
                moderatorID: accountUserId,
                messageID: messageId
            )
        }
    }

    /// Returns true if `accountUserId == channelId` — i.e., the
    /// signed-in user IS the broadcaster of this channel. This is an
    /// instant, no-network mod-check that's true for broadcasters
    /// before they've sent any message. For mods-who-aren't-the-
    /// broadcaster, we infer from echoed badges (see `ChatTranscriptModel`).
    public nonisolated var isAccountBroadcaster: Bool {
        accountUserId == channelId
    }

    // MARK: - Pub-sub API

    /// Registers a mailbox that receives every update emitted after the call
    /// returns, AND returns the current ring snapshot atomically with
    /// registration. The atomicity guarantee — mailbox installed + ring read
    /// in one actor turn, and every `emit` is itself one turn — means a new
    /// subscriber can never observe a gap between "rows I primed with" and
    /// "rows posted to me."
    ///
    /// Before snapshotting, ring messages normalized against an older emote
    /// table are refreshed (see `refreshStaleNormalization`), so a tab that
    /// attaches after the channel's emotes loaded renders early history with
    /// them — computed once here, off the main actor, for every later tab too.
    ///
    /// Drain `subscription.wakeups` / `takePending()`; pass
    /// `subscription.token` to `unsubscribe(_:)` when done.
    public func subscribe() -> (subscription: ChannelSubscription, snapshot: [ChannelUpdate]) {
        refreshStaleNormalization()
        let subscription = hub.addSubscriber()
        return (subscription, hub.snapshot)
    }

    /// Watcher convenience: runs `handler` once per drained batch on a task
    /// of its own — never on the session — until `unsubscribe(_:)` / `stop()`.
    /// No snapshot (watchers only care about what happens next). A slow
    /// handler only delays its own batches.
    @discardableResult
    public func subscribe(onBatch handler: @escaping @Sendable ([ChannelUpdate]) async -> Void) -> UUID {
        let subscription = hub.addSubscriber()
        Task {
            await Self.drain(subscription, into: handler)
        }
        return subscription.token
    }

    private static func drain(
        _ subscription: ChannelSubscription,
        into handler: @Sendable ([ChannelUpdate]) async -> Void
    ) async {
        for await _ in subscription.wakeups {
            let batch = subscription.takePending()
            if !batch.isEmpty {
                await handler(batch)
            }
        }
    }

    /// Removes and closes the mailbox for the given token. Idempotent —
    /// calling with an unknown token is a no-op. Subscribers are also closed
    /// en masse by `stop()`, so callers don't strictly need to unsubscribe on
    /// session teardown, but doing so is good hygiene for partial detach.
    public func unsubscribe(_ token: UUID) {
        hub.removeSubscriber(token)
    }

    /// Returns the current ring snapshot without subscribing. Useful for one-
    /// shot reads (e.g., debug views, exports). For UI consumers that want
    /// ongoing updates, use `subscribe()` — it primes AND subscribes in one
    /// atomic step.
    public func currentSnapshot() -> [ChannelUpdate] {
        hub.snapshot
    }

    /// The single path every update takes into the session's state and out
    /// to subscribers — live events, local settings changes, the start-time
    /// restrictions fetch and reconnect gap-fills all come through here, so
    /// "buffer or append, then deliver" can't drift between call sites.
    ///
    /// Synchronous: the whole batch is committed to the ring and posted to
    /// every mailbox in one actor turn, so it lands contiguously — nothing
    /// can interleave inside it. Posting never waits on a subscriber. While
    /// the join backfill is pending the batch is parked instead of appended
    /// (see `ChannelUpdateHub.emit`).
    private func emit(_ updates: [ChannelUpdate]) {
        hub.emit(updates)
    }

    // MARK: - Backfill merge

    /// Commits the backfill merge to the ring and ends the buffering window.
    ///
    /// MUST stay synchronous (no `await`): the actor holds its isolation for
    /// the whole call, so reading the hub's buffered live updates, building
    /// the ring, clearing the buffer, and flipping `backfillPending` happen as
    /// one atomic step with respect to `handle(event:)`. An `await` here would
    /// reopen the actor and let a live event slip in between "merge" and
    /// "clear" — it would be lost or double-counted.
    ///
    /// Internal (not private) so ChannelsTests can end the buffering window on
    /// a never-`start()`ed session and drive `resyncAfterReconnect` offline —
    /// same visibility relaxation as `translate(event:...)`. Production's only
    /// caller remains `start()`.
    func applyBackfill(_ backfill: [BackfillMessage]) {
        joinBackfill = .done
        let history = normalizer.normalizeHistory(backfill)
        // Join divider: only when there's actually history to separate —
        // an empty backfill (rustlog down, brand-new channel) would put a
        // meaningless rule at the very top of an all-live transcript.
        let divider: ChannelUpdate? = history.isEmpty ? nil : .row(normalizer.makeDivider())
        let bufferedCount = hub.commitBackfill(history: history, divider: divider)

        let primedCount = hub.ring.count
        if primedCount > 0 {
            logger.info("Primed ring with \(primedCount) event(s) for #\(self.channelLoginName, privacy: .public) — \(history.count) backfilled, \(bufferedCount) buffered-live")
        }
    }

    // MARK: - Join backfill (bounded wait, late merge)

    /// Where the join-time history fetch stands. Every transition happens on
    /// the actor, so "the deadline passed" and "the history arrived" can't
    /// both claim the outcome.
    private enum JoinBackfill {
        /// No fetch started (tests drive `applyBackfill` directly).
        case idle
        /// In flight; `start()` may be waiting on it.
        case fetching
        /// Landed before `start()` stopped waiting; not yet applied.
        case arrived([BackfillMessage])
        /// `start()` gave up waiting and exposed the session; a late arrival
        /// is merged in by `mergeLateBackfill`.
        case abandoned
        /// Applied (on time, late, or as empty).
        case done
    }

    private var joinBackfill: JoinBackfill = .idle
    private var joinBackfillDeadline: ContinuousClock.Instant?
    private var joinBackfillFetch: Task<Void, Never>?
    private var joinBackfillTimer: Task<Void, Never>?
    /// `start()`, parked in `finishJoinBackfill` until the history lands or
    /// the deadline passes — whichever wakes it first.
    private var joinBackfillWaiter: CheckedContinuation<Void, Never>?

    /// Kicks off the join-history fetch and starts its deadline clock.
    /// Internal (not private) so tests can drive the bounded wait offline.
    func beginJoinBackfill() {
        guard case .idle = joinBackfill else { return }
        joinBackfill = .fetching
        joinBackfillDeadline = ContinuousClock.now + joinBackfillTimeout
        let fetch = fetchBackfill
        let login = channelLoginName
        let limit = Self.joinBackfillLimit
        // Unstructured so it can outlive `start()`'s wait: a late answer is
        // still merged. Weak so it never pins a torn-down session.
        joinBackfillFetch = Task { [weak self] in
            let history = await fetch(login, limit)
            await self?.joinBackfillArrived(history)
        }
    }

    /// Waits for the join history — but no later than the deadline — then
    /// commits whatever we have and ends the buffering window, so the session
    /// is exposed on time even when the history service is slow or down.
    /// Internal for the same testing reason as `beginJoinBackfill`.
    func finishJoinBackfill() async {
        if case .fetching = joinBackfill,
           let deadline = joinBackfillDeadline,
           joinBackfillWaiter == nil,       // one waiter (start) — never overwrite one
           !Task.isCancelled {
            // A cancelled start (the registry released the key mid-start)
            // must not sit out the deadline: a re-acquire is queued behind
            // this session's teardown.
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    joinBackfillWaiter = continuation
                    joinBackfillTimer = Task { [weak self] in
                        do {
                            try await Task.sleep(until: deadline, clock: .continuous)
                        } catch {
                            return   // cancelled: whoever cancelled us did the waking
                        }
                        await self?.wakeJoinBackfillWaiter()
                    }
                }
            } onCancel: {
                Task { await self.wakeJoinBackfillWaiter() }
            }
        }
        if Task.isCancelled {
            // This session is about to be discarded; don't keep fetching.
            joinBackfillFetch?.cancel()
        }
        // Decided in one actor turn: whatever state we find is the outcome.
        switch joinBackfill {
        case .arrived(let history):
            applyBackfill(history)
        case .fetching:
            logger.notice("Join history for #\(self.channelLoginName, privacy: .public) not back after \(self.joinBackfillTimeout, privacy: .public); opening with live chat, will merge history if it lands")
            applyBackfill([])
            joinBackfill = .abandoned
        case .idle:
            applyBackfill([])
        case .abandoned, .done:
            break
        }
    }

    private func joinBackfillArrived(_ history: [BackfillMessage]) {
        switch joinBackfill {
        case .fetching:
            joinBackfill = .arrived(history)
            wakeJoinBackfillWaiter()
        case .abandoned:
            mergeLateBackfill(history)
        case .idle, .arrived, .done:
            break
        }
    }

    /// Test hook: a `finishJoinBackfill` is currently parked.
    var isWaitingForJoinBackfill: Bool { joinBackfillWaiter != nil }

    /// Test hook: the join history has been applied or merged (or given up
    /// on by `stop()`) — nothing more will come of it.
    var isJoinBackfillSettled: Bool {
        if case .done = joinBackfill { return true }
        return false
    }

    /// Resumes a `start()` parked in `finishJoinBackfill`, at most once.
    private func wakeJoinBackfillWaiter() {
        joinBackfillTimer?.cancel()
        joinBackfillTimer = nil
        guard let waiter = joinBackfillWaiter else { return }
        joinBackfillWaiter = nil
        waiter.resume()
    }

    /// History that missed the deadline. It's OLDER than every live row the
    /// session has shown since opening, so it goes ABOVE them — the same
    /// layout an on-time backfill produces: `[history…, New, live…]`. Reuses
    /// the reconnect gap-fill's dedup (`missingMessages`) and the join merge
    /// (`mergeBackfill`); because subscribers already hold the live tail,
    /// they get the new ring as one `.reprime` rather than an append.
    private func mergeLateBackfill(_ history: [BackfillMessage]) {
        joinBackfill = .done
        let missing = ChannelHistoryMerge.missingMessages(history, notIn: hub.snapshot)
        guard !missing.isEmpty else { return }
        let merged = ChannelHistoryMerge.mergeBackfill(
            history: normalizer.normalizeHistory(missing),
            pendingLive: hub.snapshot,
            capacity: hub.capacity,
            divider: .row(normalizer.makeDivider())
        )
        // The cap trims from the head, i.e. history first. If live rows
        // already fill the ring, nothing late survives — leave the ring (and
        // every subscriber's transcript) alone rather than reset them for an
        // orphaned divider.
        let historyIds = Set(missing.map(\.message.messageId))
        let anyHistorySurvives = merged.contains { update in
            if case .message(let normalized) = update {
                return historyIds.contains(normalized.message.messageId)
            }
            return false
        }
        guard anyHistorySurvives else { return }
        hub.replaceRing(with: merged)
        logger.info("Merged \(missing.count) late history message(s) above the live rows of #\(self.channelLoginName, privacy: .public)")
        hub.reprimeSubscribers()
    }

    // MARK: - Reconnect resync

    /// True while a reconnect gap-fill is in flight. Set synchronously at the
    /// top of `resyncAfterReconnect` (before its first await) so back-to-back
    /// `.connected` transitions — flapping network, registry resyncing every
    /// session for the account — collapse to one rustlog fetch.
    private var resyncInFlight = false

    /// Join-time backfill fetch size — "comfortable scrollback" (matches the
    /// historical BackfillProvider default this call site used to rely on).
    private static let joinBackfillLimit = 150

    /// Gap-fill fetch size. Smaller than the join backfill's 150: the gap is
    /// usually seconds-to-minutes of missed chat, and anything beyond this in
    /// a single disconnect means the scrollback context is gone anyway.
    private static let reconnectBackfillLimit = 100

    /// Fills the gap left by an EventSub socket drop. TwitchKit reconnects and
    /// re-subscribes on its own, but EventSub has no replay — anything Twitch
    /// broadcast while the socket was down is simply lost. This fetches a small
    /// rustlog backfill, drops everything the ring already has (dedup by
    /// `messageId`), and appends only the missing messages (dimmed as
    /// historical) capped with a "New" divider that marks where LIVE messages
    /// resume — into the ring AND out to subscribers.
    ///
    /// The gap is ONE `emit`: committed and posted to every mailbox in a
    /// single actor turn, so subscribers receive it as one contiguous batch
    /// that no live event can interleave with (the old per-event fan-out
    /// awaited between rows, letting live traffic land inside the gap).
    /// Subscribers that dedup by id (ChatTranscriptModel Path 1) absorb any
    /// overlap with rows they already hold (e.g. a self-send whose lost echo
    /// was locally synthesized).
    ///
    /// Nothing missed → nothing appended: a clean blip doesn't litter the
    /// transcript with dividers.
    ///
    /// Called by `ChannelSessionRegistry`'s connection pump on every
    /// reconnecting→connected (or waitingForNetwork→connected) transition.
    ///
    /// Known small races, accepted:
    ///   - Live events arriving during the rustlog fetch land in the ring
    ///     first, so the gap batch can sit ~one fetch round-trip later than
    ///     strict chronology. (History rows now carry their `tmi-sent-ts`,
    ///     but live rows only a receipt time, so a sort across the two would
    ///     be apples to oranges.)
    ///   - rustlog snapshots at fetch time; messages broadcast between that
    ///     snapshot and TwitchKit's `resubscribeAll()` completing can be
    ///     missed by both sources.
    public func resyncAfterReconnect() async {
        // The initial-backfill window has its own divider + merge path; a
        // resync during it would race `applyBackfill`'s atomic commit.
        guard !hub.backfillPending, !resyncInFlight else { return }
        resyncInFlight = true
        defer { resyncInFlight = false }

        let fetched = await fetchBackfill(channelLoginName, Self.reconnectBackfillLimit)
        guard !fetched.isEmpty else { return }

        let missing = ChannelHistoryMerge.missingMessages(fetched, notIn: hub.snapshot)
        guard !missing.isEmpty else {
            logger.info("Reconnect resync for #\(self.channelLoginName, privacy: .public): no missed messages")
            return
        }
        logger.notice("Reconnect resync for #\(self.channelLoginName, privacy: .public): filling \(missing.count) missed message(s)")

        emit(normalizer.normalizeHistory(missing) + [.row(normalizer.makeDivider())])
    }

    // MARK: - Normalization

    /// Re-normalizes ring messages built against an older emote table —
    /// typically history and early live rows normalized before the channel's
    /// 7TV/BTTV/FFZ set finished loading. Called from `subscribe()`, so the
    /// work happens once, off the main actor, and the refreshed rows are what
    /// every later subscriber primes from. (Rows already delivered to a live
    /// subscriber aren't re-sent — same as before: a re-attach picks them up.)
    private func refreshStaleNormalization() {
        guard normalizer.hasEmoteIndex, !hub.ring.isEmpty else { return }
        let table = normalizer.currentEmoteTable()
        guard table.generation != 0 else { return }

        let normalizer = self.normalizer
        let interval = signposter.beginInterval("renormalize", id: signposter.makeSignpostID())
        let refreshed = hub.refreshMessages { stale in
            normalizer.renormalized(stale, table: table)
        }
        signposter.endInterval("renormalize", interval, "refreshed=\(refreshed)")
    }

    // MARK: - Event handling (driven by this session's router inbox)

    /// Driven by this session's inbox in `ChannelEventRouter`, which the
    /// registry's off-main dispatcher feeds — one event at a time, in arrival
    /// order, never on the main actor.
    ///
    /// Each EventSub event is translated to a `ChannelEvent` (or dropped, for
    /// event types we don't render), normalized ONCE into a display-ready
    /// `ChannelUpdate`, and emitted: ring append + post to every subscriber
    /// mailbox. Synchronous, and it never waits on a subscriber.
    func handle(event: EventSubEvent) {
        guard let channelEvent = Self.translate(
            event: event,
            expectedChannelId: channelId,
            accountUserId: accountUserId
        ) else { return }
        // Captured once and stored on the resulting row: TwitchKit doesn't
        // surface EventSub's envelope `message_timestamp`, so receipt time is
        // the best send-time we have — and every replay must reuse it.
        let receivedAt = Date()

        // Side-effect: losing mod status invalidates the live
        // channel.moderate subscription (Twitch revokes it server-side
        // when the subscriber is unmodded). Clear the local flag so a
        // re-promotion — re-modded later, badge observation proves it —
        // re-subscribes instead of assuming the dead subscription works.
        if case .moderationStatusChanged(false) = channelEvent {
            moderationEventsEnabled = false
        }

        // Side-effect: update the cached restrictions snapshot when the
        // event is a restrictions change. This way a freshly-attached
        // ChatTranscriptModel that reads `currentChatRestrictions()` AFTER the
        // event arrived gets the up-to-date value, not the stale
        // session-start fetch.
        //
        // Also set the live-update flag — refreshChatRestrictions() uses
        // this to back off if its Helix fetch is still in flight when
        // we arrive (the EventSub state is fresher).
        if case .restrictionsUpdated(let restrictions) = channelEvent {
            restrictionsCache.applyLive(restrictions)
        }

        guard let update = normalizer.makeUpdate(for: channelEvent, receivedAt: receivedAt) else { return }
        // Under raid storms (50-200 events/sec) this is the hottest path in
        // the app. It used to await a TaskGroup child per subscriber per
        // event, so the slowest main-actor subscriber set the pace for the
        // whole channel; posting to mailboxes is a lock + append each.
        emit([update])
    }

    /// Translate one TwitchKit EventSub event to a chattr ChannelEvent.
    /// Returns nil for event types we don't render OR events whose
    /// broadcaster ID doesn't match this session (defensive — the registry
    /// already routes by broadcaster, but a misrouted event would corrupt
    /// the ring).
    ///
    /// `accountUserId` filters `channel.moderate` traffic down to the two
    /// actions that target OUR account (`mod`/`unmod`) — bans, timeouts,
    /// and settings flips performed by other mods translate to nil until
    /// chattr grows mod-feed features that render them.
    ///
    /// Internal (not private) so ChannelsTests can drive the
    /// moderate/revocation mapping directly with decoded fixtures.
    static func translate(event: EventSubEvent, expectedChannelId: String, accountUserId: String) -> ChannelEvent? {
        switch event {
        case .chatMessage(let m) where m.broadcasterUserId == expectedChannelId:
            return .message(m)
        case .chatNotification(let n) where n.broadcasterUserId == expectedChannelId:
            return .notification(n)
        case .raid(let r) where r.toBroadcasterUserId == expectedChannelId:
            return .raid(r)
        case .chatMessageDelete(let d) where d.broadcasterUserId == expectedChannelId:
            return .messageDeleted(targetMessageId: d.messageId)
        case .chatClear(let c) where c.broadcasterUserId == expectedChannelId:
            return .chatCleared
        case .chatClearUserMessages(let c) where c.broadcasterUserId == expectedChannelId:
            return .messagesClearedFromUser(targetUserId: c.targetUserId)
        case .chatSettingsUpdate(let s) where s.broadcasterUserId == expectedChannelId:
            // Build a ChatRestrictions directly from the EventSub payload.
            // Mirrors `ChatRestrictions.init(from: ChatSettings)` — same
            // semantic fields, different wire shape (slowModeWaitTimeSeconds
            // vs slowModeWaitTime, etc.). Keeping the construction inline
            // here rather than adding another init keeps the field-name
            // diff visible in one place.
            let restrictions = ChatRestrictions(
                slowModeSeconds: s.slowMode ? s.slowModeWaitTimeSeconds : nil,
                followersOnly: s.followerMode,
                followersDurationMinutes: s.followerMode ? s.followerModeDurationMinutes : nil,
                subscribersOnly: s.subscriberMode,
                emoteOnly: s.emoteMode
            )
            return .restrictionsUpdated(restrictions)
        case .moderate(let m) where m.broadcasterUserId == expectedChannelId:
            // Only the actions that change OUR mod status. The payload's
            // `action` string discriminates; the matching nested object
            // carries the target user. Defensive double-check on both —
            // a `mod` action always carries `mod`, but trusting one field
            // when two must agree invites decoding-drift bugs.
            if m.action == "mod", m.mod?.userId == accountUserId {
                return .moderationStatusChanged(canModerate: true)
            }
            if m.action == "unmod", m.unmod?.userId == accountUserId {
                return .moderationStatusChanged(canModerate: false)
            }
            return nil
        case .revocation(let r)
            where r.type == "channel.moderate"
                && r.condition["broadcaster_user_id"] == expectedChannelId
                && r.condition["moderator_user_id"] == accountUserId:
            // Twitch revokes our channel.moderate subscription when the
            // account stops being a mod of the channel — so the revocation
            // is itself an unmod signal, covering the case where the
            // `unmod` action event never reaches us (revocation raced it).
            // Other revocation causes (authorization revoked, version
            // retired) also mean the live feed is dead; downgrading to
            // "unknown" costs at most one badge-observation round-trip to
            // re-prove status, while NOT downgrading would show mod tools
            // backed by no live feed.
            return .moderationStatusChanged(canModerate: false)
        default:
            return nil
        }
    }

    /// Pulls the broadcaster user ID out of any EventSub event we know how
    /// to route. Used by `ChannelSessionRegistry`'s dispatcher to look up
    /// the owning session before calling `handle(event:)`. Returns nil for
    /// event types we don't subscribe to.
    public static func broadcasterUserId(from event: EventSubEvent) -> String? {
        switch event {
        case let .chatMessage(m):                  return m.broadcasterUserId
        case let .chatNotification(n):             return n.broadcasterUserId
        case let .raid(r):                         return r.toBroadcasterUserId
        case let .chatMessageDelete(d):            return d.broadcasterUserId
        case let .chatClear(c):                    return c.broadcasterUserId
        case let .chatClearUserMessages(c):        return c.broadcasterUserId
        case let .chatSettingsUpdate(s):           return s.broadcasterUserId
        case let .moderate(m):                     return m.broadcasterUserId
        // Revocations of ANY subscription type route by the condition's
        // broadcaster id — translate() then keeps only channel.moderate
        // ones. Conditions without the key (e.g. user-scoped types we
        // don't use) fall out as nil and are dropped, same as before.
        case let .revocation(r):                   return r.condition["broadcaster_user_id"]
        default:                                    return nil
        }
    }
}
