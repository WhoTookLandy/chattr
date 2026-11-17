import Foundation
import Core
import os

/// Instruments the `renormalize` interval (stale ring rows refreshed on
/// subscribe). Same category as the `normalize` / `deliver` intervals.
private let signposter = AppLogger.signposter("Channels.Pipeline")

extension ChannelSession {

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
    ///
    /// On a stopped session the subscription comes back already finished
    /// (with the last snapshot): nothing will ever be posted, so its
    /// `wakeups` must end rather than wait forever.
    public func subscribe() -> (subscription: ChannelSubscription, snapshot: [ChannelUpdate]) {
        guard !isStopped else {
            return (hub.makeFinishedSubscriber(), hub.snapshot)
        }
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
        let subscription = isStopped ? hub.makeFinishedSubscriber() : hub.addSubscriber()
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
    func emit(_ updates: [ChannelUpdate]) {
        hub.emit(updates)
    }

    // MARK: - Normalization

    /// The channel's emote table was (re)published. Rows normalized against
    /// the older table — everything a background tab received before its
    /// emotes loaded — are refreshed, and when that changed how any of them
    /// renders, every subscriber gets the ring again as one `.reprime`:
    /// they already hold those rows with emote names as plain text, and
    /// nothing else would correct them until the page was remounted.
    ///
    /// Called by `ChannelSessionRegistry.loadEmotes`. A no-op before the
    /// join backfill is committed (no subscriber exists yet, and whoever
    /// subscribes first refreshes in `subscribe()`) and after `stop()`.
    public func emoteTableDidChange() {
        guard !isStopped, !hub.backfillPending else { return }
        guard refreshStaleNormalization() > 0 else { return }
        hub.reprimeSubscribers()
    }

    /// Re-normalizes ring messages built against an older emote table —
    /// typically history and early live rows normalized before the channel's
    /// 7TV/BTTV/FFZ set finished loading. Called from `subscribe()`, so the
    /// work happens once, off the main actor, and the refreshed rows are what
    /// every later subscriber primes from; and from `emoteTableDidChange()`,
    /// which re-sends them to the subscribers already attached.
    ///
    /// Returns how many rows now render differently (a row with no emote in
    /// it is re-stamped but unchanged).
    @discardableResult
    private func refreshStaleNormalization() -> Int {
        guard normalizer.hasEmoteIndex, !hub.ring.isEmpty else { return 0 }
        let table = normalizer.currentEmoteTable()
        guard table.generation != 0 else { return 0 }

        // A local copy, so the ring rewrite's closure captures a value rather
        // than the actor while `hub` is being mutated.
        let rowNormalizer = normalizer
        var changed = 0
        let interval = signposter.beginInterval("renormalize", id: signposter.makeSignpostID())
        let refreshed = hub.refreshMessages { stale in
            guard let fresh = rowNormalizer.renormalized(stale, table: table) else { return nil }
            if fresh.line.runs != stale.line.runs { changed += 1 }
            return fresh
        }
        signposter.endInterval("renormalize", interval, "refreshed=\(refreshed)")
        return changed
    }
}
