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
            try await client.eventSub.subscribe(subscription)
        } catch HelixError.unauthorized {
            logger.info("EventSub subscribe returned unauthorized; refreshing tokens and retrying")
            try await refreshTokenHandler()
            try await client.eventSub.subscribe(subscription)
        } catch HelixError.conflict {
            // 409 means "you already have a subscription for this (type, condition)".
            // This happens when:
            //   - The user closed a channel tab (we destroyed the local session) but
            //     TwitchKit hasn't yet exposed DELETE /eventsub/subscriptions, so the
            //     subscription on Twitch's side is still active.
            //   - The user re-opens the channel — we make a fresh session and try to
            //     subscribe again.
            // The right behavior is to treat this as success: we ARE subscribed, the
            // events will flow through our WebSocket as usual, and our local listener
            // task below will pick them up. The duplicate subscription will be cleaned
            // up by Twitch when the WebSocket disconnects.
            logger.info("EventSub already subscribed to channel.chat.message for #\(self.channelLoginName) — reusing existing subscription")
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

    /// Stops the session: cancels the listener and finishes the lines stream.
    /// (We do NOT delete the EventSub subscription in slice 1 — that's a later slice's concern.)
    public func stop() {
        logger.info("Stopping session for #\(self.channelLoginName)")
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
