import Foundation
import TwitchKit
import ChatModel
import Core
import os

private let logger = AppLogger.make("Channels.ChannelSession")

extension ChannelSession {

    // MARK: - Backfill merge

    /// Commits the backfill merge to the ring and ends the buffering window.
    ///
    /// MUST stay synchronous (no `await`): the actor holds its isolation for
    /// the whole call, so reading the hub's buffered live updates, building
    /// the ring, clearing the buffer, and flipping `backfillPending` happen as
    /// one atomic step with respect to `handle(event:)`. An `await` here would
    /// reopen the actor and let a live event slip in between "merge" and
    /// "clear" — it would be lost or double-counted.
    ///
    /// Internal (not private) so ChannelsTests can end the buffering window on
    /// a never-`start()`ed session and drive `resyncAfterReconnect` offline —
    /// same visibility relaxation as `translate(event:...)`. Production's only
    /// caller remains `start()`.
    func applyBackfill(_ backfill: [BackfillMessage]) {
        joinBackfill = .done
        let history = normalizer.normalizeHistory(backfill)
        // Join divider: only when there's actually history to separate —
        // an empty backfill (rustlog down, brand-new channel) would put a
        // meaningless rule at the very top of an all-live transcript.
        let divider: ChannelUpdate? = history.isEmpty ? nil : .row(normalizer.makeDivider())
        let bufferedCount = hub.commitBackfill(history: history, divider: divider)

        let primedCount = hub.ring.count
        if primedCount > 0 {
            logger.info("Primed ring with \(primedCount) event(s) for #\(self.channelLoginName, privacy: .public) — \(history.count) backfilled, \(bufferedCount) buffered-live")
        }
    }

    // MARK: - Join backfill (bounded wait, late merge)

    /// Where the join-time history fetch stands. Every transition happens on
    /// the actor, so "the deadline passed" and "the history arrived" can't
    /// both claim the outcome.
    enum JoinBackfill {
        /// No fetch started (tests drive `applyBackfill` directly).
        case idle
        /// In flight; `start()` may be waiting on it.
        case fetching
        /// Landed before `start()` stopped waiting; not yet applied.
        case arrived([BackfillMessage])
        /// `start()` gave up waiting and exposed the session; a late arrival
        /// is merged in by `mergeLateBackfill`.
        case abandoned
        /// Applied (on time, late, or as empty).
        case done
    }

    /// Kicks off the join-history fetch and starts its deadline clock.
    /// Internal (not private) so tests can drive the bounded wait offline.
    func beginJoinBackfill() {
        guard case .idle = joinBackfill else { return }
        joinBackfill = .fetching
        joinBackfillDeadline = ContinuousClock.now + joinBackfillTimeout
        let fetch = fetchBackfill
        let login = channelLoginName
        let limit = Self.joinBackfillLimit
        // Unstructured so it can outlive `start()`'s wait: a late answer is
        // still merged. Weak so it never pins a torn-down session.
        joinBackfillFetch = Task { [weak self] in
            let history = await fetch(login, limit)
            await self?.joinBackfillArrived(history)
        }
    }

    /// Waits for the join history — but no later than the deadline — then
    /// commits whatever we have and ends the buffering window, so the session
    /// is exposed on time even when the history service is slow or down.
    /// Internal for the same testing reason as `beginJoinBackfill`.
    func finishJoinBackfill() async {
        if case .fetching = joinBackfill,
           let deadline = joinBackfillDeadline,
           joinBackfillWaiter == nil,       // one waiter (start) — never overwrite one
           !Task.isCancelled {
            // A cancelled start (the registry released the key mid-start)
            // must not sit out the deadline: a re-acquire is queued behind
            // this session's teardown.
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    joinBackfillWaiter = continuation
                    joinBackfillTimer = Task { [weak self] in
                        do {
                            try await Task.sleep(until: deadline, clock: .continuous)
                        } catch {
                            return   // cancelled: whoever cancelled us did the waking
                        }
                        await self?.wakeJoinBackfillWaiter()
                    }
                }
            } onCancel: {
                Task { await self.wakeJoinBackfillWaiter() }
            }
        }
        if Task.isCancelled {
            // This session is about to be discarded; don't keep fetching.
            joinBackfillFetch?.cancel()
        }
        // Decided in one actor turn: whatever state we find is the outcome.
        switch joinBackfill {
        case .arrived(let history):
            applyBackfill(history)
        case .fetching:
            logger.notice("Join history for #\(self.channelLoginName, privacy: .public) not back after \(self.joinBackfillTimeout, privacy: .public); opening with live chat, will merge history if it lands")
            applyBackfill([])
            joinBackfill = .abandoned
        case .idle:
            applyBackfill([])
        case .abandoned, .done:
            break
        }
    }

    private func joinBackfillArrived(_ history: [BackfillMessage]) {
        switch joinBackfill {
        case .fetching:
            joinBackfill = .arrived(history)
            wakeJoinBackfillWaiter()
        case .abandoned:
            mergeLateBackfill(history)
        case .idle, .arrived, .done:
            break
        }
    }

    /// Test hook: a `finishJoinBackfill` is currently parked.
    var isWaitingForJoinBackfill: Bool { joinBackfillWaiter != nil }

    /// Test hook: the join history has been applied or merged (or given up
    /// on by `stop()`) — nothing more will come of it.
    var isJoinBackfillSettled: Bool {
        if case .done = joinBackfill { return true }
        return false
    }

    /// Resumes a `start()` parked in `finishJoinBackfill`, at most once.
    func wakeJoinBackfillWaiter() {
        joinBackfillTimer?.cancel()
        joinBackfillTimer = nil
        guard let waiter = joinBackfillWaiter else { return }
        joinBackfillWaiter = nil
        waiter.resume()
    }

    /// History that missed the deadline. It's OLDER than every live row the
    /// session has shown since opening, so it goes ABOVE them — the same
    /// layout an on-time backfill produces: `[history…, New, live…]`. Reuses
    /// the reconnect gap-fill's dedup (`missingMessages`) and the join merge
    /// (`mergeBackfill`); because subscribers already hold the live tail,
    /// they get the new ring as one `.reprime` rather than an append.
    private func mergeLateBackfill(_ history: [BackfillMessage]) {
        joinBackfill = .done
        let missing = ChannelHistoryMerge.missingMessages(history, notIn: hub.snapshot)
        guard !missing.isEmpty else { return }
        let merged = ChannelHistoryMerge.mergeBackfill(
            history: normalizer.normalizeHistory(missing),
            pendingLive: hub.snapshot,
            capacity: hub.capacity,
            divider: .row(normalizer.makeDivider())
        )
        // The cap trims from the head, i.e. history first. If live rows
        // already fill the ring, nothing late survives — leave the ring (and
        // every subscriber's transcript) alone rather than reset them for an
        // orphaned divider.
        let historyIds = Set(missing.map(\.message.messageId))
        let anyHistorySurvives = merged.contains { update in
            if case .message(let normalized) = update {
                return historyIds.contains(normalized.message.messageId)
            }
            return false
        }
        guard anyHistorySurvives else { return }
        hub.replaceRing(with: merged)
        logger.info("Merged \(missing.count) late history message(s) above the live rows of #\(self.channelLoginName, privacy: .public)")
        hub.reprimeSubscribers()
    }

    // MARK: - Reconnect resync

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
    /// historical) capped with a "New" divider that marks where LIVE messages
    /// resume — into the ring AND out to subscribers.
    ///
    /// The gap is ONE `emit`: committed and posted to every mailbox in a
    /// single actor turn, so subscribers receive it as one contiguous batch
    /// that no live event can interleave with (the old per-event fan-out
    /// awaited between rows, letting live traffic land inside the gap).
    /// Subscribers that dedup by id (ChatTranscriptModel Path 1) absorb any
    /// overlap with rows they already hold (e.g. a self-send whose lost echo
    /// was locally synthesized).
    ///
    /// Nothing missed → nothing appended: a clean blip doesn't litter the
    /// transcript with dividers.
    ///
    /// Only rows that can belong to the gap are taken: those sent no earlier
    /// than the last live event before the drop, less `resyncSlack`. Without
    /// that floor, a session whose join history never landed would append up
    /// to a fetch's worth of PRE-join messages below newer live rows. The
    /// floor is the earlier of `droppedAt` (when the registry saw the socket
    /// go down) and the newest live receipt — events that arrive after the
    /// reconnect, before this runs, must not move it past the gap.
    ///
    /// A request that arrives while a fetch is in flight isn't dropped: that
    /// fetch may have been answered before the newer gap existed, so one
    /// follow-up fetch runs after it (any number of requests collapse into
    /// that one).
    ///
    /// Called by `ChannelSessionRegistry`'s connection pump on every
    /// reconnecting→connected (or waitingForNetwork→connected) transition.
    ///
    /// Known small races, accepted:
    ///   - Live events arriving during the rustlog fetch land in the ring
    ///     first, so the gap batch can sit ~one fetch round-trip later than
    ///     strict chronology. (History rows now carry their `tmi-sent-ts`,
    ///     but live rows only a receipt time, so a sort across the two would
    ///     be apples to oranges.)
    ///   - rustlog snapshots at fetch time; messages broadcast between that
    ///     snapshot and TwitchKit's `resubscribeAll()` completing can be
    ///     missed by both sources.
    public func resyncAfterReconnect(droppedAt: Date? = nil) async {
        // The initial-backfill window has its own divider + merge path; a
        // resync during it would race `applyBackfill`'s atomic commit.
        guard !hub.backfillPending, !isStopped else { return }
        let requestFloor = min(lastLiveReceiptAt, droppedAt ?? lastLiveReceiptAt)
        guard !resyncInFlight else {
            resyncFollowUpFloor = min(resyncFollowUpFloor ?? requestFloor, requestFloor)
            return
        }
        resyncInFlight = true
        defer { resyncInFlight = false }

        var next: Date? = requestFloor
        while let gapFloor = next, !isStopped {
            await fillGap(notBefore: gapFloor.addingTimeInterval(-Self.resyncSlack))
            next = resyncFollowUpFloor
            resyncFollowUpFloor = nil
        }
    }

    /// How far before the floor a fetched row may have been sent and still
    /// count as part of the gap. Covers what the floor can't know: a dead
    /// socket goes unnoticed until EventSub's keepalive deadline (~15s), and
    /// `tmi-sent-ts` is Twitch's clock while receipt times are the device's.
    /// Rows this lets through that were received live are deduped by id.
    private static let resyncSlack: TimeInterval = 30

    /// One gap-fill fetch + commit. See `resyncAfterReconnect`.
    private func fillGap(notBefore cutoff: Date) async {
        let fetched = await fetchBackfill(channelLoginName, Self.reconnectBackfillLimit)
        guard !fetched.isEmpty, !isStopped else { return }

        let missing = ChannelHistoryMerge.missingMessages(
            ChannelHistoryMerge.gapCandidates(fetched, notBefore: cutoff),
            notIn: hub.snapshot
        )
        guard !missing.isEmpty else {
            logger.info("Reconnect resync for #\(self.channelLoginName, privacy: .public): no missed messages")
            return
        }
        logger.notice("Reconnect resync for #\(self.channelLoginName, privacy: .public): filling \(missing.count) missed message(s)")

        emit(normalizer.normalizeHistory(missing) + [.row(normalizer.makeDivider())])
    }
}
