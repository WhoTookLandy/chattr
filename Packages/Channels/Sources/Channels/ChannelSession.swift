import Foundation
import TwitchKit
import Core
import os

private let logger = AppLogger.make("Channels.ChannelSession")

/// Owns one chat session for a (account × channel) pair.
///
/// Slice 1 behavior: connects to TwitchKit's EventSub, subscribes to `channel.chat.message`
/// for `channelId × accountUserId`, accumulates messages in a 500-element ring buffer,
/// and emits coalesced snapshots via `lines` every ~15ms while messages arrive.
///
/// Why `actor` (not `@MainActor`): ChannelSession operates only on `String` IDs and
/// TwitchKit's `ChatMessage` value type — no SwiftData `@Model` instances. The actor's
/// private isolation domain is the right fit: snapshot work happens off-main, the
/// `nonisolated` `lines` stream delivers to the consumer without an actor hop.
public actor ChannelSession {

    /// Sliding-window stream of message snapshots. Consumers iterate without actor hops.
    public nonisolated let lines: AsyncStream<[ChatMessage]>
    private let linesContinuation: AsyncStream<[ChatMessage]>.Continuation

    private let client: TwitchClient
    private let channelId: String
    private let channelLoginName: String
    private let accountUserId: String

    /// Ring buffer of received messages, capped at 500.
    private var ring: [ChatMessage] = []
    private static let ringCapacity = 500

    /// Coalesce ticker — debounces snapshot emission to ~15ms.
    private var coalesceTask: Task<Void, Never>?
    private var lastEmittedCount: Int = 0

    /// EventSub event-listening task. Cancelled on `stop()`.
    private var listenerTask: Task<Void, Never>?

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
        (lines, linesContinuation) = AsyncStream.makeStream(of: [ChatMessage].self)
    }

    deinit {
        linesContinuation.finish()
    }

    // MARK: - Public

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

        // Start listening for events.
        listenerTask?.cancel()
        listenerTask = Task { [weak self] in
            guard let self else { return }
            let stream = self.client.eventSub.events
            for await event in stream {
                guard !Task.isCancelled else { return }
                await self.handle(event: event)
            }
        }
    }

    /// Stops the session: deletes the EventSub subscription on Twitch's side,
    /// cancels the local listener, and finishes the lines stream.
    ///
    /// The unsubscribe call is best-effort: if it fails (network blip, token
    /// expiry, server error), we still proceed with local cleanup. Twitch will
    /// garbage-collect the subscription when the WebSocket disconnects, so a
    /// failed delete just means the subscription lingers for the rest of the
    /// app's foreground lifetime — annoying but not a leak.
    public func stop() async {
        logger.info("Stopping session for #\(self.channelLoginName)")

        // 1. Tell Twitch to drop the subscription so we stop consuming our
        //    EventSub quota (each app has a per-WebSocket subscription cap).
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

        // 2. Local cleanup — cancel tasks. The lines AsyncStream stays open
        //    (deinit will finish it) so any in-flight consumers see the end.
        listenerTask?.cancel()
        listenerTask = nil
        coalesceTask?.cancel()
        coalesceTask = nil
    }

    // MARK: - Private

    private func handle(event: EventSubEvent) {
        guard let message = Self.extractChatMessage(from: event) else { return }
        guard message.broadcasterUserId == channelId else { return }

        // Append to ring buffer with cap.
        if ring.count >= Self.ringCapacity {
            ring.removeFirst(ring.count - Self.ringCapacity + 1)
        }
        ring.append(message)

        scheduleCoalescedEmit()
    }

    private func scheduleCoalescedEmit() {
        // If a coalesce task is already pending, leave it — the next emit will include this message.
        if coalesceTask != nil { return }

        coalesceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(15))
            guard let self else { return }
            await self.emitSnapshot()
        }
    }

    private func emitSnapshot() {
        coalesceTask = nil
        guard ring.count != lastEmittedCount else { return }
        lastEmittedCount = ring.count
        linesContinuation.yield(ring)
    }

    /// Extracts a `TwitchKit.ChatMessage` from the `EventSubEvent` enum.
    ///
    /// TwitchKit's `EventSubEvent` exposes `case chatMessage(ChatMessage)` directly —
    /// no intermediate wrapper. This is the slice-1 event we care about.
    private static func extractChatMessage(from event: EventSubEvent) -> ChatMessage? {
        if case let .chatMessage(message) = event { return message }
        return nil
    }
}
