import Foundation
import Core
import os

private let logger = AppLogger.make("Channels.ChannelSession")

/// Instruments the `deliver` interval (one post to every subscriber's
/// mailbox) of the session half of the message pipeline. Same category as
/// the session's `normalize` / `renormalize` intervals.
private let signposter = AppLogger.signposter("Channels.Pipeline")

/// A channel's canonical state plus its fan-out: the ring of display-ready
/// updates, the join-backfill buffering window in front of it, and every
/// subscriber's `ChannelSubscription` mailbox.
///
/// A value type owned by (and only ever mutated inside) `ChannelSession`, so
/// every method runs in one actor turn — that is what keeps a multi-row
/// `emit` contiguous and `subscribe` (register + snapshot) atomic. Nothing
/// here awaits, and posting never waits on a subscriber.
struct ChannelUpdateHub {

    /// Ring buffer of display-ready updates, capped at the Chat History
    /// setting. See `ChannelUpdateRing`.
    private(set) var ring: ChannelUpdateRing

    /// Live events that arrived via `emit` while `backfillPending` is true —
    /// i.e. after we subscribed to EventSub but before the rustlog backfill
    /// resolved. `commitBackfill` drains this into the ring (merged + deduped
    /// against history) and clears it. Empty for the rest of the session's
    /// life once backfill has been applied.
    private var pendingLive: [ChannelUpdate] = []

    /// True from construction until `commitBackfill` runs. While true, `emit`
    /// parks updates in `pendingLive` instead of appending to the ring, so
    /// backfill history can still be inserted ahead of them without
    /// clobbering live events. Flipped to false exactly once.
    private(set) var backfillPending = true

    /// Active subscribers' mailboxes, keyed by their token. Multi-consumer by
    /// design — the same channel in multiple tabs (plus each tab strip's
    /// mention watcher) registers one mailbox each; every mailbox gets every
    /// update, in order. Posting never waits on the consumer.
    private var subscribers: [UUID: ChannelSubscription] = [:]

    /// For log lines only.
    private let channelLoginName: String

    init(capacity: Int, channelLoginName: String) {
        self.ring = ChannelUpdateRing(capacity: capacity)
        self.channelLoginName = channelLoginName
    }

    var capacity: Int { ring.capacity }

    /// The ring's live window. See `ChannelUpdateRing.snapshot`.
    var snapshot: [ChannelUpdate] { ring.snapshot }

    /// Backlog cap per subscriber mailbox: twice the ring, and never tiny.
    /// Past it, a lagging subscriber is re-primed instead (see
    /// `ChannelSubscription`).
    var subscriberBacklogLimit: Int { max(ring.capacity * 2, 1_000) }

    // MARK: - Subscribers

    /// Creates and registers a new mailbox.
    mutating func addSubscriber() -> ChannelSubscription {
        let subscription = ChannelSubscription(capacity: subscriberBacklogLimit)
        subscribers[subscription.token] = subscription
        return subscription
    }

    /// A mailbox that is already closed and never registered: what a
    /// subscriber of a stopped session gets, so its consumer loop ends at
    /// once instead of waiting on a stream nothing will ever finish.
    func makeFinishedSubscriber() -> ChannelSubscription {
        let subscription = ChannelSubscription(capacity: subscriberBacklogLimit)
        subscription.finish()
        return subscription
    }

    /// Removes and closes the mailbox for `token`. Unknown tokens are a no-op.
    mutating func removeSubscriber(_ token: UUID) {
        subscribers.removeValue(forKey: token)?.finish()
    }

    /// Ends every subscriber's stream and forgets them all.
    mutating func finishAllSubscribers() {
        for subscription in subscribers.values {
            subscription.finish()
        }
        subscribers.removeAll()
    }

    // MARK: - Emit

    /// "Buffer or append, then deliver" — the body of `ChannelSession.emit`.
    ///
    /// Synchronous: the whole batch is committed to the ring and posted to
    /// every mailbox in one actor turn, so it lands contiguously — nothing
    /// can interleave inside it. Posting never waits on a subscriber.
    ///
    /// State-only updates (`ChannelUpdate.isStateOnly`) are delivered but
    /// not stored: no replay reads them, so they would only spend ring slots.
    mutating func emit(_ updates: [ChannelUpdate]) {
        guard !updates.isEmpty else { return }
        if backfillPending {
            // Backfill hasn't landed yet — park the updates so history can
            // still be merged ahead of them; `commitBackfill` drains this into
            // the ring. The registry exposes the session only once `start()`
            // returns, so no subscriber normally exists in this window and
            // the delivery below is a no-op.
            for update in updates where !update.isStateOnly {
                pendingLive.append(update)
            }
        } else {
            for update in updates where !update.isStateOnly {
                ring.append(update)
            }
        }
        deliver(updates)
    }

    /// Posts one batch to every mailbox. A mailbox that is too far behind to
    /// take it gets the ring snapshot as a `.reprime` instead — it converges
    /// on the same state without its backlog growing unbounded.
    private func deliver(_ updates: [ChannelUpdate]) {
        guard !subscribers.isEmpty else { return }
        let interval = signposter.beginInterval(
            "deliver",
            id: signposter.makeSignpostID(),
            "updates=\(updates.count) subscribers=\(self.subscribers.count)"
        )
        defer { signposter.endInterval("deliver", interval) }

        var overflowed: [ChannelSubscription] = []
        for subscription in subscribers.values where !subscription.post(updates) {
            overflowed.append(subscription)
        }
        guard !overflowed.isEmpty else { return }
        let snapshot = ring.snapshot
        for subscription in overflowed {
            // The refused batch is in the ring already (emit appends first);
            // only its state-only updates need carrying.
            subscription.reprime(snapshot: snapshot, alsoCarrying: updates)
        }
        logger.warning("\(overflowed.count) subscriber(s) of #\(self.channelLoginName, privacy: .public) fell more than \(self.subscriberBacklogLimit) updates behind; re-priming them")
    }

    /// Re-posts the whole ring to every subscriber as one `.reprime` — for
    /// changes that aren't a tail append. Replaces each backlog: its rows are
    /// already in the ring, and its latest state-only updates are carried
    /// (see `ChannelSubscription.reprime`).
    func reprimeSubscribers() {
        guard !subscribers.isEmpty else { return }
        let snapshot = ring.snapshot
        for subscription in subscribers.values {
            subscription.reprime(snapshot: snapshot)
        }
    }

    // MARK: - Ring rewrites

    /// Merges `history` (and `divider`, between the blocks) ahead of the
    /// buffered live updates into the ring and ends the buffering window.
    /// Returns how many buffered-live updates were drained.
    ///
    /// Synchronous by construction, so the read-of-pendingLive → build-ring →
    /// clear-buffer → flip-flag sequence is atomic with respect to `emit`.
    mutating func commitBackfill(history: [ChannelUpdate], divider: ChannelUpdate?) -> Int {
        ring.replace(with: ChannelHistoryMerge.mergeBackfill(
            history: history,
            pendingLive: pendingLive,
            capacity: ring.capacity,
            divider: divider
        ))
        let bufferedCount = pendingLive.count
        pendingLive = []
        backfillPending = false
        return bufferedCount
    }

    /// Replaces the ring's contents without delivering anything; pair with
    /// `reprimeSubscribers()`.
    mutating func replaceRing(with updates: [ChannelUpdate]) {
        ring.replace(with: updates)
    }

    /// See `ChannelUpdateRing.refreshMessages`.
    mutating func refreshMessages(
        _ transform: (NormalizedMessage) -> NormalizedMessage?
    ) -> Int {
        ring.refreshMessages(transform)
    }
}
