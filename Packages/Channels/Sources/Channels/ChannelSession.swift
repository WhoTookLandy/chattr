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
/// clears. Consumers map each variant to whatever they need (TabChatModel
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
        /// A regular chat message.
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
    }

    /// Type for subscriber handlers. `@Sendable` so they can be stored across
    /// the actor boundary; `async` so they can hop to whatever actor the
    /// receiver lives on (typically `@MainActor` for SwiftUI consumers).
    public typealias EventHandler = @Sendable (ChannelEvent) async -> Void

    private let client: TwitchClient
    private let channelId: String
    private let channelLoginName: String
    private let accountUserId: String

    /// Ring buffer of received events, capped at 500.
    private var ring: [ChannelEvent] = []
    private static let ringCapacity = 500

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

    /// Called by `start()` when EventSub subscribe returns unauthorized.
    /// Injected at construction time by `ChannelSessionRegistry` so this actor
    /// doesn't need to know about `AccountStore` or `Account` directly.
    private let refreshTokenHandler: @Sendable () async throws -> Void

    public init(
        client: TwitchClient,
        channelId: String,
        channelLoginName: String,
        accountUserId: String,
        refreshTokenHandler: @escaping @Sendable () async throws -> Void = {
            throw AppError(message: "ChannelSession constructed without refreshTokenHandler")
        }
    ) {
        self.client = client
        self.channelId = channelId
        self.channelLoginName = channelLoginName
        self.accountUserId = accountUserId
        self.refreshTokenHandler = refreshTokenHandler
    }

    // MARK: - Lifecycle

    /// Starts the session: connects EventSub (if needed), subscribes to chat
    /// + notification + raid + delete + clear topics, and primes the ring
    /// from rustlog backfill.
    public func start() async throws {
        logger.info("Starting session for #\(self.channelLoginName) (channelId=\(self.channelId))")

        // Kick off rustlog backfill in parallel with the WebSocket connect.
        // See BackfillProvider for the design rationale. Order matters:
        // backfill MUST complete + populate the ring BEFORE any EventSub
        // subscribe succeeds, otherwise live messages start arriving and
        // fan out to subscribers before the history is in the ring.
        async let backfillTask = BackfillProvider.fetchRecentMessages(channelLogin: channelLoginName)

        try await client.eventSub.connect()

        // Drain backfill. Failures are absorbed by BackfillProvider — we
        // never propagate. If backfill returned nothing, the ring stays
        // empty and we proceed with live-only subscriptions.
        let backfill = await backfillTask
        if !backfill.isEmpty {
            ring = Array(backfill.suffix(Self.ringCapacity)).map { ChannelEvent.message($0) }
            logger.info("Primed ring with \(self.ring.count) backfilled message(s) for #\(self.channelLoginName, privacy: .public)")
        }

        // Subscribe to the five EventSub topics we render. Each subscribe
        // call is independent — a failure on one shouldn't block the
        // others. We log per-topic errors but only THROW if the core chat
        // subscription fails (no chat = unusable session).
        try await subscribeToChat()
        await subscribeToNotificationTopic(.notification, label: "notification")
        await subscribeToNotificationTopic(.messageDelete, label: "message_delete")
        await subscribeToNotificationTopic(.clear, label: "chat_clear")
        await subscribeToNotificationTopic(.clearUserMessages, label: "clear_user_messages")
        await subscribeToRaid()

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
            let record = try await client.eventSub.subscribe(subscription)
            activeSubscriptionIds.append(record.id)
        } catch HelixError.unauthorized {
            logger.info("EventSub chat.message subscribe returned unauthorized; refreshing tokens and retrying")
            try await refreshTokenHandler()
            let record = try await client.eventSub.subscribe(subscription)
            activeSubscriptionIds.append(record.id)
        } catch HelixError.conflict {
            // 409 "already subscribed" — Twitch keeps the subscription alive
            // on this WebSocket from a prior session; events still flow.
            logger.info("EventSub already subscribed to channel.chat.message for #\(self.channelLoginName, privacy: .public) — reusing existing subscription (no id captured)")
        }
        logger.info("Subscribed to channel.chat.message for #\(self.channelLoginName, privacy: .public)")
    }

    /// Subscribes to one of the chat-related notification topics
    /// (notification, message_delete, clear, clear_user_messages). All use
    /// the same `(broadcasterID, userID)` shape. Failure swallowed — the
    /// session still works without these, just without bubble rendering.
    private enum NotificationKind {
        case notification, messageDelete, clear, clearUserMessages

        func subscription(broadcasterID: String, userID: String) -> EventSubSubscription {
            switch self {
            case .notification:       return .Chat.notification(broadcasterID: broadcasterID, userID: userID)
            case .messageDelete:      return .Chat.messageDelete(broadcasterID: broadcasterID, userID: userID)
            case .clear:              return .Chat.clear(broadcasterID: broadcasterID, userID: userID)
            case .clearUserMessages:  return .Chat.clearUserMessages(broadcasterID: broadcasterID, userID: userID)
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

    // MARK: - Send

    /// Sends a chat message through this session's authenticated user. Wraps
    /// `client.api.sendChatMessage(...)` with a one-shot token-refresh-and-retry
    /// on `HelixError.unauthorized`, matching the pattern in `subscribeToChat()`
    /// — sends are short, so we don't go through `AccountStore.withTokenRefresh`
    /// (which is geared at the SwiftData-isolated Account model that doesn't
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
    /// confirm — see `TabChatModel.send(...)` for the optimistic-insert /
    /// dedup orchestration on top of that.
    public func send(_ text: String) async throws -> SendChatMessageResponse {
        // Trim leading/trailing whitespace only — preserve internal whitespace
        // so users can put their `:` between word and emote in
        // ":wave: hello :wave:" style messages. Twitch handles the rest.
        let payload = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else {
            throw AppError(message: "Can't send an empty message")
        }
        do {
            return try await client.api.sendChatMessage(
                broadcasterId: channelId,
                senderId: accountUserId,
                message: payload
            )
        } catch HelixError.unauthorized {
            // Same shape as subscribeToChat's recovery: refresh tokens once,
            // retry once. A second unauthorized error propagates and lets
            // the caller (TabChatModel.send → ChatScreen) surface the
            // sign-in-expired UX.
            logger.info("sendChatMessage unauthorized; refreshing tokens and retrying once")
            try await refreshTokenHandler()
            return try await client.api.sendChatMessage(
                broadcasterId: channelId,
                senderId: accountUserId,
                message: payload
            )
        }
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
        return (token, ring)
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
        ring
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
        guard let channelEvent = Self.translate(event: event, expectedChannelId: channelId) else { return }

        // Append to ring buffer with cap.
        if ring.count >= Self.ringCapacity {
            ring.removeFirst(ring.count - Self.ringCapacity + 1)
        }
        ring.append(channelEvent)

        // Snapshot subscribers so subscribe/unsubscribe during the loop's
        // suspension points don't cause concurrent-modification issues.
        let snapshot = subscribers

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
            for (_, handler) in snapshot {
                group.addTask { await handler(channelEvent) }
            }
        }
    }

    /// Translate one TwitchKit EventSub event to a chattr ChannelEvent.
    /// Returns nil for event types we don't render OR events whose
    /// broadcaster ID doesn't match this session (defensive — the registry
    /// already routes by broadcaster, but a misrouted event would corrupt
    /// the ring).
    private static func translate(event: EventSubEvent, expectedChannelId: String) -> ChannelEvent? {
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
        default:                                    return nil
        }
    }
}
