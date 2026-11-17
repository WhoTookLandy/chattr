import Foundation
import os

/// One subscriber's view of a channel's live events (polls, predictions,
/// Hype Trains) — a **latest-value** mailbox, unlike `ChannelSubscription`'s
/// ordered queue.
///
/// Consumers only ever need the current state, so the session overwrites a
/// single slot and rings a doorbell buffered to one pending ring: any number
/// of updates between drains cost the consumer one wakeup and one apply, and
/// the backlog can never grow. The session never waits on the consumer.
///
/// ```swift
/// for await _ in subscription.wakeups {
///     if let state = subscription.takeLatest() { apply(state) }
/// }
/// ```
public final class LiveEventsSubscription: Sendable {
    public let token: UUID

    /// Fires (at least once) after a new state is posted. Finishes when the
    /// subscription ends (`unsubscribeLiveEvents`, session `stop`).
    public let wakeups: AsyncStream<Void>

    private let doorbell: AsyncStream<Void>.Continuation
    private let slot: OSAllocatedUnfairLock<LiveEventsState?>

    /// Primed with `initial` and already rung, so the consumer's first
    /// wakeup delivers the state the channel had at subscribe time.
    init(initial: LiveEventsState) {
        self.token = UUID()
        let (wakeups, doorbell) = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        self.wakeups = wakeups
        self.doorbell = doorbell
        self.slot = OSAllocatedUnfairLock(initialState: initial)
        doorbell.yield(())
    }

    /// The newest state since the last call, or nil when a wakeup raced an
    /// earlier take that already consumed it.
    public func takeLatest() -> LiveEventsState? {
        slot.withLock { latest in
            let value = latest
            latest = nil
            return value
        }
    }

    /// Session side: replace the pending state and ring.
    func post(_ state: LiveEventsState) {
        slot.withLock { $0 = state }
        doorbell.yield(())
    }

    /// Ends `wakeups`. A state still pending stays takeable.
    func finish() {
        doorbell.finish()
    }
}
