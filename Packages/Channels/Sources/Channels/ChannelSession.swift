import Foundation
import TwitchKit
import ChatModel
import EmoteSources
import Core
import os

private let logger = AppLogger.make("Channels.ChannelSession")

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
///
/// ## Layout
///
/// The actor composes focused helpers — `ChannelUpdateHub` (ring + buffering
/// window + subscriber fan-out), `ChannelUpdateNormalizer`,
/// `ChatRestrictionsCache`, `EventSubTopics`, `HelixChatActions` — and keeps
/// every piece of mutable state here, in its own isolation domain. Its
/// methods are split across sibling files by concern:
///
/// - `ChannelSession.swift` — state, lifecycle (`start` / `stop`), EventSub
///   topic bookkeeping, `handle(event:)`.
/// - `ChannelSession+Subscribers.swift` — pub-sub API and the single `emit`.
/// - `ChannelSession+History.swift` — join backfill (bounded wait, late
///   merge) and reconnect resync.
/// - `ChannelSession+ChatActions.swift` — restrictions, send, delete, chat
///   settings.
/// - `ChannelSession+EventTranslation.swift` — `ChannelEvent` and the
///   EventSub → `ChannelEvent` mapping.
///
/// State the sibling files touch is `internal` (Swift has no cross-file
/// `private`); it is still actor-isolated.
public actor ChannelSession {

    private let client: TwitchClient
    /// Public + `nonisolated` because it's set once at init and never
    /// changes. Callers outside the actor (e.g. `ChatTranscriptModel` reading
    /// it to key `DraftStorage` lookups) can read without hopping the
    /// actor boundary.
    public nonisolated let channelId: String
    let channelLoginName: String
    let accountUserId: String

    /// Builds display-ready rows from translated events and history, against
    /// the session account's login and the channel's emote index. See
    /// `ChannelUpdateNormalizer`.
    let normalizer: ChannelUpdateNormalizer

    /// The ring of display-ready updates (capped at the Chat History
    /// setting), the join-backfill buffering window in front of it, and the
    /// subscriber mailboxes it fans out to. Every update reaches it through
    /// `emit`. See `ChannelUpdateHub`.
    var hub: ChannelUpdateHub

    /// Cached restrictions snapshot from the most recent
    /// `refreshChatRestrictions()` call, `channel.chat_settings.update`
    /// EventSub event or local settings PATCH — plus the guard that keeps a
    /// late Helix fetch from clobbering a live update (CR MEDIUM 4). See
    /// `ChatRestrictionsCache`.
    var restrictionsCache = ChatRestrictionsCache()

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

    /// The EventSub topics this session subscribes to. Stateless: the ids it
    /// returns land in `activeSubscriptionIds`. See `EventSubTopics`.
    private let topics: EventSubTopics

    /// Send / delete / chat-settings / chat-colour Helix calls. See
    /// `HelixChatActions`.
    ///
    /// Both this and `topics` share one `HelixAuthRetry` (refresh via the
    /// bridge, retry once) whose `refreshTokenHandler` is injected at
    /// construction time by `ChannelSessionRegistry`, so this actor doesn't
    /// need to know about `AccountStore` or `Account` directly.
    let chatActions: HelixChatActions

    /// Fetches recent chat history (channelLogin, limit) → messages with
    /// their send times. Defaults to `BackfillProvider.fetchRecentMessages`;
    /// tests inject a stub so the join-backfill and reconnect-resync actor
    /// paths run without network. Same closure-injection pattern as
    /// `refreshTokenHandler`.
    let fetchBackfill: @Sendable (String, Int) async -> [BackfillMessage]

    /// How long `start()` waits for join history, measured from when the
    /// fetch began, before exposing the session without it (late history is
    /// merged in afterwards). Injected so tests can use a short deadline.
    let joinBackfillTimeout: Duration

    // Join backfill state — see `ChannelSession+History.swift`.

    /// Where the join-time history fetch stands. See `JoinBackfill`.
    var joinBackfill: JoinBackfill = .idle
    var joinBackfillDeadline: ContinuousClock.Instant?
    var joinBackfillFetch: Task<Void, Never>?
    var joinBackfillTimer: Task<Void, Never>?
    /// `start()`, parked in `finishJoinBackfill` until the history lands or
    /// the deadline passes — whichever wakes it first.
    var joinBackfillWaiter: CheckedContinuation<Void, Never>?

    /// True while a reconnect gap-fill is in flight. Set synchronously at the
    /// top of `resyncAfterReconnect` (before its first await) so back-to-back
    /// `.connected` transitions — flapping network, registry resyncing every
    /// session for the account — collapse to one rustlog fetch.
    var resyncInFlight = false

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
        let authRetry = HelixAuthRetry(refreshTokenHandler: refreshTokenHandler)
        self.topics = EventSubTopics(
            client: client,
            channelId: channelId,
            accountUserId: accountUserId,
            channelLoginName: channelLoginName,
            authRetry: authRetry
        )
        self.chatActions = HelixChatActions(
            client: client,
            channelId: channelId,
            accountUserId: accountUserId,
            authRetry: authRetry
        )
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

    // MARK: - EventSub topics (bookkeeping stays on the actor)

    /// The core chat.message subscription — required for the session to be
    /// useful. Throws on failure so the registry doesn't keep a session that
    /// can't deliver chat. The other (notification/raid/delete/clear) topics
    /// use `subscribeToNotificationTopic` / `subscribeToRaid` which swallow
    /// errors — those topics are enrichment, not core function.
    private func subscribeToChat() async throws {
        if let id = try await topics.subscribeToChat() {
            activeSubscriptionIds.append(id)
        }
    }

    private func subscribeToNotificationTopic(_ kind: EventSubTopics.NotificationKind, label: String) async {
        if let id = await topics.subscribeToNotificationTopic(kind, label: label) {
            activeSubscriptionIds.append(id)
        }
    }

    private func subscribeToRaid() async {
        if let id = await topics.subscribeToRaid() {
            activeSubscriptionIds.append(id)
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

        switch await topics.subscribeToModeration() {
        case .subscribed(let id):
            activeSubscriptionIds.append(id)
        case .alreadySubscribed:
            // Already live on this WebSocket from a prior session — keep
            // the flag, events flow.
            break
        case .failed:
            // Roll back so a later promotion (e.g. after the user
            // re-signs-in mid-run and picks up the scopes) can retry.
            moderationEventsEnabled = false
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
        await topics.unsubscribe(ids)
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
}
