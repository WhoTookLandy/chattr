import Foundation
import os

/// One subscriber's delivery queue — the session posts to it, the
/// subscriber drains it, and neither ever waits on the other.
///
/// ## Why a mailbox, not one stream element per event
///
/// Everything posted since the subscriber last drained comes out of
/// `takePending()` as ONE batch, so a consumer pays one hop (one main-actor
/// turn, one publish) per drain rather than per event; a busier channel or a
/// busier main thread just means bigger batches. `wakeups` is a doorbell
/// buffered to a single pending ring — N posts between drains still wake the
/// consumer once.
///
/// ## Bounded backlog
///
/// The mailbox holds at most `capacity` updates. A post that would exceed it
/// is refused; the session then replaces the whole backlog with a single
/// `.reprime(snapshot)` (preceded by the latest restrictions / mod-status
/// change, which a snapshot can't restore) — so a consumer stalled for a long
/// time costs one ring-sized snapshot, not an ever-growing queue, and still
/// converges on exactly the session's state.
///
/// Typical consumer:
/// ```swift
/// for await _ in subscription.wakeups {
///     apply(subscription.takePending())
/// }
/// ```
public final class ChannelSubscription: Sendable {
    public let token: UUID

    /// Fires (at least once) after anything is posted. Finishes when the
    /// subscription ends (`unsubscribe`, session `stop`).
    public let wakeups: AsyncStream<Void>

    private let doorbell: AsyncStream<Void>.Continuation
    private let mailbox: OSAllocatedUnfairLock<[ChannelUpdate]>
    private let capacity: Int

    init(capacity: Int) {
        self.token = UUID()
        let (wakeups, doorbell) = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        self.wakeups = wakeups
        self.doorbell = doorbell
        self.mailbox = OSAllocatedUnfairLock(initialState: [])
        self.capacity = max(1, capacity)
    }

    /// Everything posted since the last call, in order. Empty when a wakeup
    /// raced an earlier drain that already took it.
    public func takePending() -> [ChannelUpdate] {
        mailbox.withLock { pending in
            var batch: [ChannelUpdate] = []
            swap(&batch, &pending)
            return batch
        }
    }

    /// Session side: queue `updates` and ring the doorbell. Returns false —
    /// queueing nothing — when that would exceed the backlog cap.
    func post(_ updates: [ChannelUpdate]) -> Bool {
        let capacity = self.capacity
        let accepted = mailbox.withLock { pending -> Bool in
            guard pending.count + updates.count <= capacity else { return false }
            pending.append(contentsOf: updates)
            return true
        }
        if accepted { doorbell.yield(()) }
        return accepted
    }

    /// Session side: replace the backlog with one `.reprime(snapshot)`.
    ///
    /// Rows in the backlog (and in `unposted`, a batch that was refused for
    /// being over the cap) are all recoverable from the snapshot, but the
    /// state-only updates are not — a reprime rebuilds rows and nothing else
    /// (a transcript reads restrictions / mod status from their own sources
    /// at attach, not from the ring). So the latest restrictions change and
    /// the latest mod-status change among them survive, ahead of the reprime.
    func reprime(snapshot: [ChannelUpdate], alsoCarrying unposted: [ChannelUpdate] = []) {
        mailbox.withLock { pending in
            var latestRestrictions: ChannelUpdate?
            var latestModeration: ChannelUpdate?
            for update in pending + unposted {
                switch update {
                case .restrictionsUpdated: latestRestrictions = update
                case .moderationStatusChanged: latestModeration = update
                default: break
                }
            }
            pending = [latestRestrictions, latestModeration].compactMap { $0 } + [.reprime(snapshot)]
        }
        doorbell.yield(())
    }

    /// Ends `wakeups`. Anything still queued stays takeable.
    func finish() {
        doorbell.finish()
    }
}
