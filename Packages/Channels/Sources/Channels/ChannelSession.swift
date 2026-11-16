import Foundation
import TwitchKit
import Core
import os

private let logger = AppLogger.make("Channels.ChannelSession")

/// Owns one chat session for a (account × channel) pair.
///
/// Architecture (post-pub-sub refactor):
///
/// - **Canonical state**: a 500-element ring buffer of every chat event we've
///   received since this session was created. The ring is the source of truth
///   for "what's happened in this channel since I joined."
///
/// - **Delivery**: a pub-sub subscriber list. Consumers (UI views, future
///   analytics, etc.) register handlers via `subscribe(_:)` and receive each
///   new event via callback. Subscribers can come and go; the ring keeps
///   accruing regardless.
///
/// - **Atomic prime + subscribe**: `subscribe(_:)` returns both a token AND a
///   snapshot of the current ring. This is critical — without atomicity, a
///   new subscriber could read snapshot=[m1,m2], then m3 arrives and fans
///   out to existing subscribers (but the new one hasn't registered yet),
///   then the new subscriber registers and starts at m4. They'd miss m3.
///   The actor's isolation guarantees that subscribe's two operations
///   (register + read ring) happen between any two `handle(event:)` calls.
///
/// ## Event types (Phase 2.3)
///
/// The pub-sub event type is `ChannelEvent` — a union covering chat messages,
/// system notifications (subs/resubs/gift subs/raids/announcements), incoming
/// raids on the dedicated `channel.raid` topic, message deletions, and chat
/// clears. Consumers map each variant to whatever they need (ChatTranscriptModel
/// converts each to a `ChatLine` via the Normalizer in `ChatModel`).
///
/// Why `actor` (not `@MainActor`): ChannelSession operates only on `String`
/// IDs and TwitchKit's value types — no `@MainActor` SwiftUI dependencies.
/// The actor's private isolation domain keeps message processing off-main;
/// the per-subscriber `Task` invocations hop to whichever actor the handler
/// captured (typically `@MainActor` for UI).
public actor ChannelSession {

    /// Channel-level events. Subscribers receive these in arrival order via
    /// the handler passed to `subscribe(_:)`. The ring buffer stores these
    /// for late subscribers' prime snapshot.
    public enum ChannelEvent: Sendable {
        /// A regular chat message. `isHistorical` is true when the message
        /// came from a rustlog history fetch (join backfill or reconnect
        /// gap-fill) instead of arriving live over EventSub — consumers
        /// render those dimmed so witnessed-live and fetched-history are
        /// distinguishable at a glance. Part of the ring event, so re-primes
        /// replay the same provenance.
        case message(ChatMessage, isHistorical: Bool)

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

        /// A synthetic "New" rule separating messages from before the user
        /// was receiving live chat from messages after. Never arrives from
        /// Twitch — the session mints one in two places:
        ///   - `applyBackfill`: between rustlog history and live events,
        ///     so a freshly-joined channel shows where "you joined" sits.
        ///   - `resyncAfterReconnect`: after the gap-filled messages, so
        ///     the rule always reads "live from here down" — the fetched
        ///     gap renders dimmed above it.
        /// `id` is minted with the event and stored in the ring so every
        /// replay (tab re-attach) produces the same stable `ChatLine.id`.
        case newMessagesDivider(id: String, timestamp: Date)

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

    /// Type for subscriber handlers. `@Sendable` so they can be stored across
    /// the actor boundary; `async` so they can hop to whatever actor the
    /// receiver lives on (typically `@MainActor` for SwiftUI consumers).
    public typealias EventHandler = @Sendable (ChannelEvent) async -> Void

    private let client: TwitchClient
    /// Public + `nonisolated` because it's set once at init and never
    /// changes. Callers outside the actor (e.g. `ChatTranscriptModel` reading
    /// it to key `DraftStorage` lookups) can read without hopping the
    /// actor boundary.
    public nonisolated let channelId: String
    private let channelLoginName: String
    private let accountUserId: String

    /// Ring buffer of received events, capped at `ringCapacity`. Head-index
    /// ring: the live window is `ring[ringHead...]`; everything before
    /// `ringHead` is dead and reclaimed at the next batch compaction (see
    /// `appendToRing`). Same technique as `ChatBuffer` — a front trim is an
    /// O(1) pointer bump, not an O(count) `removeFirst` memmove per event.
    /// Readers go through `ringSnapshot`, never `ring` directly.
    private var ring: [ChannelEvent] = []
    private var ringHead: Int = 0

    /// The live window, materialized. O(count) copy — acceptable on the cold
    /// paths that read it (subscribe prime, one-shot snapshot, resync dedup),
    /// never touched on the per-event hot path.
    private var ringSnapshot: [ChannelEvent] {
        ringHead == 0 ? ring : Array(ring[ringHead...])
    }
    /// Set at construction from the user's Chat History setting (default
    /// 500). Fixed for the session's lifetime — a changed setting applies
    /// to sessions created after it (i.e. newly opened channel tabs).
    private let ringCapacity: Int

    /// Live events that arrived via `handle(event:)` while `backfillPending`
    /// is true — i.e. after we subscribed to EventSub but before the rustlog
    /// backfill resolved. `applyBackfill` drains this into the ring (merged +
    /// deduped against history) and clears it. Empty for the rest of the
    /// session's life once backfill has been applied.
    private var pendingLive: [ChannelEvent] = []

    /// True from construction until `applyBackfill` runs. While true,
    /// `handle(event:)` parks events in `pendingLive` instead of appending to
    /// the ring, so backfill history can still be inserted ahead of them
    /// without clobbering live events. Flipped to false exactly once.
    private var backfillPending = true

    /// Active subscribers keyed by an opaque token returned from `subscribe(_:)`.
    /// Replaces the previous `AsyncStream<[ChatMessage]>` + coalesce machinery.
    /// Multi-consumer by design — same channel in multiple tabs registers
    /// multiple handlers; each gets every new event in arrival order.
    private var subscribers: [UUID: EventHandler] = [:]

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

    /// Fetches recent chat history (channelLogin, limit) → messages. Defaults
    /// to `BackfillProvider.fetchRecentMessages`; tests inject a stub so the
    /// join-backfill and reconnect-resync actor paths run without network.
    /// Same closure-injection pattern as `refreshTokenHandler`.
    private let fetchBackfill: @Sendable (String, Int) async -> [ChatMessage]

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
        ringCapacity: Int = 500,
        refreshTokenHandler: @escaping @Sendable () async throws -> Void = {
            throw AppError(message: "ChannelSession constructed without refreshTokenHandler")
        },
        fetchBackfill: @escaping @Sendable (String, Int) async -> [ChatMessage] = { login, limit in
            await BackfillProvider.fetchRecentMessages(channelLogin: login, limit: limit)
        }
    ) {
        self.client = client
        self.channelId = channelId
        self.channelLoginName = channelLoginName
        self.accountUserId = accountUserId
        self.ringCapacity = max(1, ringCapacity)
        self.refreshTokenHandler = refreshTokenHandler
        self.fetchBackfill = fetchBackfill
    }

    // MARK: - Lifecycle

    /// Starts the session: connects EventSub (if needed), subscribes to chat
    /// + notification + raid + delete + clear topics, and primes the ring
    /// from rustlog backfill.
    public func start() async throws {
        logger.info("Starting session for #\(self.channelLoginName) (channelId=\(self.channelId))")

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
        // not returned from `session(...)` (and so cannot be `subscribe(_:)`d
        // by any tab) until `start()` returns. The entire pending window is
        // therefore internal — no subscriber ever observes the empty/partial
        // ring, preserving the atomic prime+subscribe invariant.
        async let backfillTask = fetchBackfill(channelLoginName, Self.joinBackfillLimit)

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

        // Drain backfill and merge. Failures are absorbed by BackfillProvider —
        // we never propagate; an empty backfill just flushes whatever buffered
        // live events accumulated. `applyBackfill` is synchronous (no `await`)
        // so the read-of-pendingLive → build-ring → clear-buffer → flip-flag
        // sequence is atomic with respect to `handle(event:)`.
        let backfill = await backfillTask
        applyBackfill(backfill)

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
        logger.info("Stopping session for #\(self.channelLoginName)")

        // Cancel the in-flight restrictions fetch so it stops retaining the
        // actor past teardown (and skips its now-pointless subscriber fan-out).
        chatRestrictionsTask?.cancel()
        chatRestrictionsTask = nil

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

        subscribers.removeAll()
    }

    // MARK: - Chat restrictions

    /// Cached restrictions snapshot from the most recent
    /// `refreshChatRestrictions()` call OR `channel.chat_settings.update`
    /// EventSub event. nil before we've seen either.
    ///
    /// Storing inside the actor (rather than passing through Helix every
    /// time the compose bar wants to render) means the compose bar reads
    /// from a stable snapshot. EventSub updates flow in via `handle()`'s
    /// `.restrictionsUpdated` side-effect; the start-time Helix fetch
    /// populates the initial value.
    private var cachedRestrictions: ChatRestrictions?

    /// True once we've received at least one `chat_settings.update`
    /// EventSub event. Used by `refreshChatRestrictions()` to AVOID
    /// overwriting a fresh live update with a late-resolving Helix
    /// fetch.
    ///
    /// The race this prevents (CR MEDIUM 4):
    ///   1. `start()` kicks `refreshChatRestrictions()` (Helix in flight).
    ///   2. EventSub subscribe completes, broadcaster toggles slow mode,
    ///      a `chat_settings.update` event arrives BEFORE the Helix fetch
    ///      resolves.
    ///   3. `handle()` sets cachedRestrictions = X (new state).
    ///   4. Helix fetch completes with OLD state (snapshot taken before
    ///      the broadcaster's toggle).
    ///   5. Without the flag, refreshChatRestrictions overwrites
    ///      cachedRestrictions with stale Helix data → strip shows
    ///      pre-toggle state until the next event.
    ///
    /// With the flag, Helix backs off once an EventSub update has
    /// arrived. EventSub is the authoritative live source after that.
    private var cachedRestrictionsAreLive: Bool = false

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
        cachedRestrictions
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
            await applyInitialRestrictions(ChatRestrictions(from: settings))
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
    /// fetch resolved updates its compose-bar strip reactively. Mirrors the
    /// ring + fan-out shape of `updateChatSettings` / `handle` so a backgrounded
    /// initial fetch is indistinguishable downstream from a live EventSub update.
    ///
    /// No-ops when:
    ///   - `restrictions` is nil — the Helix fetch failed; leave the cache as is.
    ///   - `cachedRestrictionsAreLive` — a live `chat_settings.update` already
    ///     landed while the fetch was in flight, so the Helix snapshot is older
    ///     than what we hold. Same race guard the awaited refresh used to apply
    ///     inline (CR MEDIUM 4), now that the fetch resolves after exposure.
    ///
    /// Internal (not private) so ChannelsTests can drive the fan-out + guard
    /// offline — same visibility relaxation as `applyBackfill`.
    func applyInitialRestrictions(_ restrictions: ChatRestrictions?) async {
        guard let restrictions else { return }
        guard !cachedRestrictionsAreLive else {
            logger.debug("Skipping Helix restrictions overwrite — EventSub update already populated cache")
            return
        }
        cachedRestrictions = restrictions

        let event: ChannelEvent = .restrictionsUpdated(restrictions)
        if backfillPending {
            pendingLive.append(event)
        } else {
            appendToRing(event)
        }
        let handlers = Array(subscribers.values)
        await withTaskGroup(of: Void.self) { group in
            for handler in handlers {
                group.addTask { await handler(event) }
            }
        }
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
        cachedRestrictions = restrictions
        cachedRestrictionsAreLive = true

        // Mirror handle(event:)'s ring + fan-out semantics so a local
        // settings change is indistinguishable from an EventSub-delivered
        // one downstream.
        let channelEvent: ChannelEvent = .restrictionsUpdated(restrictions)
        if backfillPending {
            pendingLive.append(channelEvent)
        } else {
            appendToRing(channelEvent)
        }
        let handlers = Array(subscribers.values)
        await withTaskGroup(of: Void.self) { group in
            for handler in handlers {
                group.addTask { await handler(channelEvent) }
            }
        }
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
    /// subscription as a `messageDeleted` ChannelEvent — `apply()` in
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

    /// Registers a handler that receives every channel event arriving after
    /// the call returns, AND returns the current ring snapshot atomically
    /// with registration. The atomicity guarantee — handler installed + ring
    /// read happen between any two `handle(event:)` invocations — means a
    /// new subscriber can never observe a gap between "events I primed
    /// with" and "events I receive via callback."
    ///
    /// Returns a `(token, snapshot)` tuple. Pass `token` back to
    /// `unsubscribe(_:)` when done. The snapshot is the caller's starting state.
    public func subscribe(_ handler: @escaping EventHandler) -> (token: UUID, snapshot: [ChannelEvent]) {
        let token = UUID()
        subscribers[token] = handler
        return (token, ringSnapshot)
    }

    /// Removes the handler for the given token. Idempotent — calling with an
    /// unknown token is a no-op. Subscribers are also cleared en masse by
    /// `stop()`, so callers don't strictly need to unsubscribe on session
    /// teardown, but doing so is good hygiene for partial detach scenarios.
    public func unsubscribe(_ token: UUID) {
        subscribers.removeValue(forKey: token)
    }

    /// Returns the current ring snapshot without subscribing. Useful for one-
    /// shot reads (e.g., debug views, exports). For UI consumers that want
    /// ongoing updates, use `subscribe(_:)` — it primes AND subscribes in one
    /// atomic step.
    public func currentSnapshot() -> [ChannelEvent] {
        ringSnapshot
    }

    /// Appends one event to the ring, dropping the oldest past `ringCapacity`.
    /// The single owner of the cap invariant — every post-backfill ring write
    /// (live dispatch, local settings change, reconnect gap-fill) goes through
    /// here so the trim logic can't drift between call sites.
    ///
    /// O(1) amortized: at capacity (the steady state for any long-open
    /// channel) each append bumps `ringHead` instead of paying an O(count)
    /// `removeFirst` memmove — under raid bursts (50-200 events/sec) that
    /// memmove compounded on every single event. The dead prefix is reclaimed
    /// in one batch once per `ringCapacity` appends.
    private func appendToRing(_ event: ChannelEvent) {
        ring.append(event)
        if ring.count - ringHead > ringCapacity {
            ringHead += 1
        }
        if ringHead >= ringCapacity {
            ring.removeFirst(ringHead)
            ringHead = 0
        }
    }

    // MARK: - Backfill merge

    /// Merges rustlog `history` with `pendingLive` (events buffered while the
    /// backfill fetch was in flight), deduplicating by `messageId` and capping
    /// to `capacity`. When `divider` is non-nil it's inserted between the two
    /// blocks — after every history event, before the first buffered-live one —
    /// marking "everything above happened before you joined."
    ///
    /// `static` + pure so it's unit-testable without a `TwitchClient`. The
    /// instance wrapper `applyBackfill(_:)` calls this and commits the result
    /// to `ring`.
    static func mergeBackfill(
        history: [ChannelEvent],
        pendingLive: [ChannelEvent],
        capacity: Int,
        divider: ChannelEvent? = nil
    ) -> [ChannelEvent] {
        var seenMessageIds = Set<String>()
        var merged: [ChannelEvent] = []
        merged.reserveCapacity(history.count + pendingLive.count + 1)

        // History first (oldest scrollback), then buffered-live in arrival
        // order. Chat messages dedup by canonical `messageId` — the same
        // message can land in BOTH rustlog history and the live buffer during
        // the fetch-overlap window. First occurrence wins, so a duplicate keeps
        // its chronological history position rather than jumping to the live tail.
        // Non-message events (notifications/raids/clears) never appear in
        // backfill and carry no shared id, so they pass through untouched.
        //
        // The divider goes between the blocks (not appended after dedup) so a
        // live duplicate that kept its history position still lands above it.
        for event in history {
            if case .message(let message, _) = event {
                guard seenMessageIds.insert(message.messageId).inserted else { continue }
            }
            merged.append(event)
        }
        if let divider {
            merged.append(divider)
        }
        for event in pendingLive {
            if case .message(let message, _) = event {
                guard seenMessageIds.insert(message.messageId).inserted else { continue }
            }
            merged.append(event)
        }

        return merged.count > capacity ? Array(merged.suffix(capacity)) : merged
    }

    /// Commits the backfill merge to the ring and ends the buffering window.
    ///
    /// MUST stay synchronous (no `await`): the actor holds its isolation for
    /// the whole call, so reading `pendingLive`, building `ring`, clearing the
    /// buffer, and flipping `backfillPending` happen as one atomic step with
    /// respect to `handle(event:)`. An `await` here would reopen the actor and
    /// let a live event slip in between "merge" and "clear" — it would be lost
    /// or double-counted.
    ///
    /// Internal (not private) so ChannelsTests can end the buffering window on
    /// a never-`start()`ed session and drive `resyncAfterReconnect` offline —
    /// same visibility relaxation as `translate(event:...)`. Production's only
    /// caller remains `start()`.
    func applyBackfill(_ backfill: [ChatMessage]) {
        let history = backfill.map { ChannelEvent.message($0, isHistorical: true) }
        // Join divider: only when there's actually history to separate —
        // an empty backfill (rustlog down, brand-new channel) would put a
        // meaningless rule at the very top of an all-live transcript.
        let divider: ChannelEvent? = history.isEmpty
            ? nil
            : .newMessagesDivider(id: "divider-\(UUID().uuidString)", timestamp: .now)
        ring = Self.mergeBackfill(
            history: history,
            pendingLive: pendingLive,
            capacity: ringCapacity,
            divider: divider
        )
        ringHead = 0
        let bufferedCount = pendingLive.count
        pendingLive = []
        backfillPending = false

        if !ring.isEmpty {
            logger.info("Primed ring with \(self.ring.count) event(s) for #\(self.channelLoginName, privacy: .public) — \(history.count) backfilled, \(bufferedCount) buffered-live")
        }
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
    /// historical) capped with a "New" divider — both into the ring AND
    /// fanned out to live subscribers.
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
    ///     strict chronology. (Backfilled rows carry no server timestamp, so
    ///     a sort isn't possible anyway.)
    ///   - rustlog snapshots at fetch time; messages broadcast between that
    ///     snapshot and TwitchKit's `resubscribeAll()` completing can be
    ///     missed by both sources.
    public func resyncAfterReconnect() async {
        // The initial-backfill window has its own divider + merge path; a
        // resync during it would race `applyBackfill`'s atomic commit.
        guard !backfillPending, !resyncInFlight else { return }
        resyncInFlight = true
        defer { resyncInFlight = false }

        let fetched = await fetchBackfill(channelLoginName, Self.reconnectBackfillLimit)
        guard !fetched.isEmpty else { return }

        let gapEvents = Self.reconnectGapEvents(
            fetched: fetched,
            ring: ringSnapshot,
            dividerId: "divider-\(UUID().uuidString)",
            timestamp: .now
        )
        guard !gapEvents.isEmpty else {
            logger.info("Reconnect resync for #\(self.channelLoginName, privacy: .public): no missed messages")
            return
        }
        logger.notice("Reconnect resync for #\(self.channelLoginName, privacy: .public): filling \(gapEvents.count - 1) missed message(s)")

        // Commit the whole batch to the ring synchronously (no await between
        // appends) so a live `handle(event:)` can't interleave INSIDE the
        // divider+messages block.
        for event in gapEvents {
            appendToRing(event)
        }

        // Fan out after the ring commit, one event at a time in order —
        // same TaskGroup shape as `handle(event:)`. Subscribers that dedup
        // by id (ChatTranscriptModel Path 1) absorb any overlap with rows they
        // already hold (e.g. a self-send whose lost echo was locally
        // synthesized).
        let handlers = Array(subscribers.values)
        for event in gapEvents {
            await withTaskGroup(of: Void.self) { group in
                for handler in handlers {
                    group.addTask { await handler(event) }
                }
            }
        }
    }

    /// Pure gap computation: which of the freshly-fetched rustlog messages are
    /// NOT already in the ring (flagged historical), followed by a
    /// `.newMessagesDivider` when the gap is non-empty — the divider trails
    /// the gap so it always marks where LIVE messages resume; the fetched
    /// gap renders dimmed above it. Returns `[]` when nothing was missed —
    /// the caller then appends nothing (no divider for a clean reconnect).
    ///
    /// `static` + pure for the same testability reason as `mergeBackfill`.
    static func reconnectGapEvents(
        fetched: [ChatMessage],
        ring: [ChannelEvent],
        dividerId: String,
        timestamp: Date
    ) -> [ChannelEvent] {
        var knownMessageIds = Set<String>()
        for event in ring {
            if case .message(let message, _) = event {
                knownMessageIds.insert(message.messageId)
            }
        }
        let missing = fetched.filter { !knownMessageIds.contains($0.messageId) }
        guard !missing.isEmpty else { return [] }
        return missing.map { ChannelEvent.message($0, isHistorical: true) }
            + [.newMessagesDivider(id: dividerId, timestamp: timestamp)]
    }

    // MARK: - Event handling (driven by registry's dispatcher)

    /// Driven by `ChannelSessionRegistry`'s shared event dispatcher — the
    /// registry pulls events off `client.eventSub.events` once and calls this
    /// on the session whose broadcaster ID matches the event's owner.
    ///
    /// Each EventSub event is translated to a `ChannelEvent` variant (or
    /// dropped, for event types we don't render). The event is appended to
    /// the ring + fanned out to subscribers.
    func handle(event: EventSubEvent) async {
        guard let channelEvent = Self.translate(
            event: event,
            expectedChannelId: channelId,
            accountUserId: accountUserId
        ) else { return }

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
            cachedRestrictions = restrictions
            cachedRestrictionsAreLive = true
        }

        if backfillPending {
            // Backfill hasn't landed yet — park the event so history can still
            // be merged ahead of it. `applyBackfill` drains this into the ring.
            // No subscriber exists during this window (the registry exposes the
            // session only after `start()` returns), so skipping the fan-out
            // below would be harmless — but the empty subscriber set makes it a
            // no-op anyway, so we fall through for uniformity.
            pendingLive.append(channelEvent)
        } else {
            appendToRing(channelEvent)
        }

        // Snapshot subscribers so subscribe/unsubscribe during the loop's
        // suspension points don't cause concurrent-modification issues.
        //
        // `Array(subscribers.values)` instead of `let snapshot = subscribers`:
        // the dict copy used to allocate an entire hash table (keys + buckets
        // + values) per event. The values-array form allocates a flat array
        // of N closures and no hash overhead. With N=1 (single-tab MVP) the
        // diff is invisible; with multi-channel + multi-tab the win grows
        // linearly — and this is the hottest path in the app under raid
        // storms.
        let handlers = Array(subscribers.values)

        // Fan out to handlers in parallel via TaskGroup. The group is
        // awaited as a unit, so `handle(event:)` still runs to completion
        // before the actor processes the next event — event ordering is
        // preserved. The change is that subscribers' handlers no longer
        // serialize: 2 tabs × 50ms hop each used to be 100ms of actor
        // suspension; now it's ~50ms.
        //
        // Why this matters: under raid storms / mass-gifting (50-200
        // events/sec), serial fanout creates head-of-line blocking — the
        // actor's executor queue grows faster than it drains. Parallel
        // fanout collapses to O(slowest handler) instead of O(sum of all
        // handlers), eliminating the queue pileup.
        await withTaskGroup(of: Void.self) { group in
            for handler in handlers {
                group.addTask { await handler(channelEvent) }
            }
        }
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
            return .message(m, isHistorical: false)
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
