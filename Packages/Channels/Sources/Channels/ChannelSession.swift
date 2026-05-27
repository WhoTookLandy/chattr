import Foundation
import TwitchKit
import Core
import os

private let logger = AppLogger.make("Channels.ChannelSession")

/// Owns one chat session for a (account × channel) pair.
///
/// Architecture (post-pub-sub refactor):
///
/// - **Canonical state**: a 500-element ring buffer of every chat message we've
///   received since this session was created. The ring is the source of truth
///   for "what's the latest message history for this channel."
///
/// - **Delivery**: a pub-sub subscriber list. Consumers (UI views, future
///   analytics, etc.) register handlers via `subscribe(_:)` and receive each
///   new message via callback. Subscribers can come and go; the ring keeps
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
/// Why `actor` (not `@MainActor`): ChannelSession operates only on `String`
/// IDs and TwitchKit's `ChatMessage` value type — no `@MainActor` SwiftUI
/// dependencies. The actor's private isolation domain keeps message
/// processing off-main; the per-subscriber `Task` invocations hop to
/// whichever actor the handler captured (typically `@MainActor` for UI).
public actor ChannelSession {

    /// Type for subscriber handlers. `@Sendable` so they can be stored across
    /// the actor boundary; `async` so they can hop to whatever actor the
    /// receiver lives on (typically `@MainActor` for SwiftUI consumers).
    public typealias MessageHandler = @Sendable (ChatMessage) async -> Void

    private let client: TwitchClient
    private let channelId: String
    private let channelLoginName: String
    private let accountUserId: String

    /// Ring buffer of received messages, capped at 500.
    private var ring: [ChatMessage] = []
    private static let ringCapacity = 500

    /// Active subscribers keyed by an opaque token returned from `subscribe(_:)`.
    /// Replaces the previous `AsyncStream<[ChatMessage]>` + coalesce machinery.
    /// Multi-consumer by design — same channel in multiple tabs registers
    /// multiple handlers; each gets every new message in arrival order.
    private var subscribers: [UUID: MessageHandler] = [:]

    /// ID of the active EventSub subscription, captured from the record that
    /// `subscribe(...)` returns. `nil` when:
    ///   - `start()` hasn't been called yet
    ///   - `start()` hit `HelixError.conflict` (subscription already existed
    ///     from a previous app session — we don't get a record back, so we
    ///     can't unsubscribe by ID; Twitch will clean it up when the
    ///     WebSocket disconnects)
    /// `stop()` uses this to call `eventSub.unsubscribe(id:)` and properly
    /// release the subscription on Twitch's side.
    private var activeSubscriptionId: String?

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

    /// Starts the session: connects EventSub (if needed) and subscribes to chat messages.
    public func start() async throws {
        logger.info("Starting session for #\(self.channelLoginName) (channelId=\(self.channelId))")

        // EventSub.connect() waits for session_welcome before returning.
        try await client.eventSub.connect()

        // Subscribe to channel.chat.message for this channel + our identity.
        let subscription = EventSubSubscription.Chat.message(
            broadcasterID: channelId,
            userID: accountUserId
        )
        do {
            let record = try await client.eventSub.subscribe(subscription)
            activeSubscriptionId = record.id
        } catch HelixError.unauthorized {
            logger.info("EventSub subscribe returned unauthorized; refreshing tokens and retrying")
            try await refreshTokenHandler()
            let record = try await client.eventSub.subscribe(subscription)
            activeSubscriptionId = record.id
        } catch HelixError.conflict {
            // 409 "already subscribed" — a previous session opened this same
            // (type, condition) and we never got to call unsubscribe (e.g. app
            // crash, force-quit). Twitch keeps the subscription alive on this
            // WebSocket; events will flow through our listener as normal.
            //
            // Caveat: we don't get a record back, so `activeSubscriptionId`
            // stays nil — our subsequent stop() can't explicitly unsubscribe.
            // That's fine: Twitch cleans up orphaned subscriptions when the
            // WebSocket disconnects.
            logger.info("EventSub already subscribed to channel.chat.message for #\(self.channelLoginName) — reusing existing subscription (no id captured)")
        }
        logger.info("Subscribed to channel.chat.message for #\(self.channelLoginName)")

        // NOTE: We deliberately do NOT iterate `client.eventSub.events` here.
        // That AsyncStream is single-consumer — if every ChannelSession had its
        // own iterator, the events would get split unpredictably between them
        // and messages would silently drop. Instead, `ChannelSessionRegistry`
        // owns one shared dispatcher Task per client that consumes the stream
        // once and routes each event to the matching session via `handle(event:)`.
    }

    /// Stops the session: deletes the EventSub subscription on Twitch's side
    /// and clears local state. Subscribers are dropped — the actor itself
    /// is then eligible for deallocation once the registry releases its
    /// reference.
    ///
    /// The unsubscribe call is best-effort: if it fails (network blip, token
    /// expiry, server error), we still proceed with local cleanup. Twitch will
    /// garbage-collect the subscription when the WebSocket disconnects, so a
    /// failed delete just means the subscription lingers for the rest of the
    /// app's foreground lifetime — annoying but not a leak.
    public func stop() async {
        logger.info("Stopping session for #\(self.channelLoginName)")

        // Tell Twitch to drop the subscription so we stop consuming our
        // EventSub quota (each app has a per-WebSocket subscription cap).
        if let id = activeSubscriptionId {
            do {
                try await client.eventSub.unsubscribe(id: id)
                logger.info("Deleted EventSub subscription \(id) for #\(self.channelLoginName)")
            } catch {
                // Non-fatal — Twitch will clean up on WebSocket disconnect.
                logger.error("Failed to delete EventSub subscription \(id): \(error.localizedDescription)")
            }
            activeSubscriptionId = nil
        }

        // Subscribers held strong references to their handlers; clearing the
        // dictionary releases those closures (and any captured state).
        subscribers.removeAll()
    }

    // MARK: - Pub-sub API

    /// Registers a handler that receives every chat message arriving after the
    /// call returns, AND returns the current ring snapshot atomically with
    /// registration. The atomicity guarantee — handler installed + ring read
    /// happen between any two `handle(event:)` invocations — means a new
    /// subscriber can never observe a gap between "messages I primed with"
    /// and "messages I receive via callback."
    ///
    /// Returns a `(token, snapshot)` tuple. Pass `token` back to
    /// `unsubscribe(_:)` when done. The snapshot is the caller's starting state.
    public func subscribe(_ handler: @escaping MessageHandler) -> (token: UUID, snapshot: [ChatMessage]) {
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
    public func currentSnapshot() -> [ChatMessage] {
        ring
    }

    // MARK: - Event handling (driven by registry's dispatcher)

    /// Driven by `ChannelSessionRegistry`'s shared event dispatcher — the
    /// registry pulls events off `client.eventSub.events` once and calls this
    /// on the session whose `channelId` matches the event's broadcaster ID.
    ///
    /// Fans out to every subscriber serially within this actor's queue:
    ///   - Snapshot the subscriber dict (defensive against subscribe/unsubscribe
    ///     racing with the `await handler(message)` suspension below).
    ///   - For each handler, `await` the callback. Sequential ordering means
    ///     each subscriber sees messages in the same order — critical for
    ///     chat readability. Concurrent fan-out (e.g., `Task { await ... }`
    ///     per subscriber) would let message N reach a subscriber BEFORE
    ///     message N-1 under contention.
    ///
    /// Cost: handler invocations block the actor until they return. Since
    /// handlers typically just hop to MainActor and update an @Observable
    /// property (microseconds), this is fine in practice. If a handler ever
    /// did slow I/O it would back-pressure event processing — but that's the
    /// handler's responsibility to keep fast.
    ///
    /// `internal` (default access) rather than `private` so the registry can
    /// call it. Module boundary keeps it from leaking out.
    func handle(event: EventSubEvent) async {
        guard let message = Self.extractChatMessage(from: event) else { return }
        guard message.broadcasterUserId == channelId else { return }

        // Append to ring buffer with cap.
        if ring.count >= Self.ringCapacity {
            ring.removeFirst(ring.count - Self.ringCapacity + 1)
        }
        ring.append(message)

        // Snapshot subscribers so subscribe/unsubscribe during the loop's
        // suspension points don't cause concurrent-modification issues.
        let snapshot = subscribers
        for (_, handler) in snapshot {
            await handler(message)
        }
    }

    /// Extracts a `TwitchKit.ChatMessage` from the `EventSubEvent` enum.
    ///
    /// TwitchKit's `EventSubEvent` exposes `case chatMessage(ChatMessage)` directly —
    /// no intermediate wrapper. This is the slice-1 event we care about.
    private static func extractChatMessage(from event: EventSubEvent) -> ChatMessage? {
        if case let .chatMessage(message) = event { return message }
        return nil
    }

    /// Pulls the broadcaster user ID out of any EventSub event we know how to
    /// route. Used by `ChannelSessionRegistry`'s dispatcher to look up the
    /// owning session before calling `handle(event:)`. Returns nil for event
    /// types we don't subscribe to (those would never have an owning session
    /// anyway — defensive).
    public static func broadcasterUserId(from event: EventSubEvent) -> String? {
        switch event {
        case let .chatMessage(message):
            return message.broadcasterUserId
        default:
            // Future event types (channel.subscribe, channel.raid, etc.) would
            // add their cases here.
            return nil
        }
    }
}
