import Foundation
import Observation
import Channels

/// The live-event banners' state for one chat page: the channel's current
/// poll / prediction / Hype Train, which banner (if any) is expanded, and
/// which events the user hid.
///
/// ## Why its own observable
///
/// Vote, point and progress ticks land every few seconds for minutes at a
/// time. Living here — owned by `LiveEventsBannerArea` as `@State` and fed
/// by the session's latest-value `LiveEventsSubscription`, not the chat
/// mailbox — they invalidate only the banner area's body. `ChatScreen`,
/// `ChatTranscript` and the collection view never read anything on this
/// type, so the transcript is untouched by a tick.
///
/// Countdowns aren't driven from here either: each visible banner runs its
/// own `TimelineView` (see `LiveEventCountdown`), so there's no global timer
/// and nothing ticks while no banner is up.
///
/// Only the visible chat page does any of this. Neighbouring pages are
/// pre-mounted, so `LiveEventsBannerArea` runs the feed only while its page
/// is the active one and `suspend()`s otherwise (no subscription, no
/// timers, frozen countdowns).
@MainActor
@Observable
final class LiveEventsModel {

    /// How long a banner pops open when something worth noticing happens
    /// (it starts, locks, resolves, levels up) before folding to one line.
    static let attentionDuration: Duration = .seconds(5)
    /// How long a banner the user tapped open stays open on its own — so an
    /// expanded banner can never cover chat for good.
    static let manualExpandDuration: Duration = .seconds(12)

    private(set) var state = LiveEventsState()
    private(set) var expanded: LiveEventKind?
    /// Event ids the user closed. A closed event stays hidden through its
    /// remaining updates and result; the next poll / prediction / train has
    /// a new id and shows normally.
    private(set) var dismissedIds: Set<String> = []

    @ObservationIgnored private var collapseTask: Task<Void, Never>?
    @ObservationIgnored private var pruneTask: Task<Void, Never>?
    /// Ownership token of the `run` in charge of the feed and the shared
    /// timers: each `run` bumps it on entry and keeps its own value, so the
    /// newest run is the owner. Cancelling a run doesn't stop it
    /// at once — it can still be suspended in `unsubscribeLiveEvents` when a
    /// rapid switch away and back starts its replacement — so after every
    /// suspension a run checks it is still the owner before it applies a
    /// state or resumes / suspends the timers. A superseded run only cleans
    /// up its own subscription.
    @ObservationIgnored private var runOwner: UInt64 = 0

    // MARK: - Feed

    /// Drains `session`'s live events until the calling task is cancelled
    /// (the banner area's `.task` going away: the page left the screen or
    /// the transcript detached), then unsubscribes and suspends.
    ///
    /// The banner area runs this only while its page is the visible one.
    /// Off-screen there is no subscription at all, so ticks cost a
    /// pre-mounted neighbour page nothing. Coming back subscribes again: the
    /// session primes the new subscription with its current (pruned) state,
    /// and `receive` diffs it against what was on screen before, so anything
    /// that started, locked or ended meanwhile pops open as usual.
    func run(session: ChannelSession) async {
        runOwner &+= 1
        let owner = runOwner

        let subscription = await session.subscribeLiveEvents()
        // A newer run took over while this one was subscribing: it owns the
        // timers now, so leave them alone and just drop this subscription.
        guard runOwner == owner else {
            await session.unsubscribeLiveEvents(subscription.token)
            return
        }
        // `suspend()` cancelled the result timeout. If the primed state
        // equals what is on screen (back within a result's linger, nothing
        // new), `receive` changes nothing, so re-arm it here or the result
        // would stay up for good in a quiet channel.
        resume()
        // AsyncStream iteration ends on task cancellation as well as on
        // `finish()` (unsubscribe / session stop).
        for await _ in subscription.wakeups {
            guard !Task.isCancelled, runOwner == owner else { break }
            if let latest = subscription.takeLatest() {
                receive(latest)
            }
        }
        await session.unsubscribeLiveEvents(subscription.token)
        // Only the owner suspends: a replacement that started while this
        // run was unsubscribing has already re-armed its own prune timer.
        guard runOwner == owner else { return }
        suspend()
    }

    /// Applies a new state from the session (or from a local prune).
    /// Internal for tests.
    func receive(_ new: LiveEventsState) {
        guard new != state else { return }
        let old = state
        state = new

        // Only banners that would actually show compete for attention: a
        // disabled or dismissed kind must not mask, say, a poll result that
        // lands in the same snapshot as a hidden Hype Train level-up.
        let attention = new.attentionKind(comparedTo: old) { kind in
            guard LiveEventsSettings.isEnabled(kind), let id = eventId(of: kind) else { return false }
            return !dismissedIds.contains(id)
        }
        if let attention {
            expand(attention, for: Self.attentionDuration)
        } else if let expanded, eventId(of: expanded) == nil {
            collapse()
        }
        schedulePrune()
    }

    // MARK: - User actions

    /// Tap on a banner: open it (folding any other), or fold it if open.
    func toggle(_ kind: LiveEventKind) {
        if expanded == kind {
            collapse()
        } else {
            expand(kind, for: Self.manualExpandDuration)
        }
    }

    /// The banner's close button: hide this event for the rest of its life.
    func dismiss(_ kind: LiveEventKind) {
        if let id = eventId(of: kind) {
            dismissedIds.insert(id)
        }
        if expanded == kind { collapse() }
    }

    func isDismissed(_ id: String) -> Bool { dismissedIds.contains(id) }

    // MARK: - Internals

    private func eventId(of kind: LiveEventKind) -> String? {
        switch kind {
        case .poll: return state.poll?.id
        case .prediction: return state.prediction?.id
        case .hypeTrain: return state.hypeTrain?.id
        }
    }

    private func expand(_ kind: LiveEventKind, for duration: Duration) {
        expanded = kind
        collapseTask?.cancel()
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self, self.expanded == kind else { return }
            self.expanded = nil
        }
    }

    private func collapse() {
        collapseTask?.cancel()
        collapseTask = nil
        expanded = nil
    }

    /// One sleeping task for the next result to time out (see
    /// `LiveEventsState.nextPruneDate`). The session prunes too, but only
    /// when another event arrives — this makes a finished banner go away on
    /// time in a quiet channel.
    /// Whether a result timeout is armed. Internal for tests.
    var isPruneScheduled: Bool { pruneTask != nil }

    private func schedulePrune() {
        pruneTask?.cancel()
        pruneTask = nil
        guard let date = state.nextPruneDate() else { return }
        // A hair of slack so the wake lands strictly past the threshold.
        let delay = max(0, date.timeIntervalSinceNow) + 0.1
        pruneTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            var next = self.state
            if next.prune(now: Date()) {
                self.receive(next)
            }
        }
    }

    /// The page left the screen: stop every timer (auto-collapse, result
    /// timeout) and fold any open banner. `state` and `dismissedIds` stay,
    /// so the next `run` catches up from where the user left off and a
    /// hidden event stays hidden. Internal for tests.
    func suspend() {
        collapseTask?.cancel()
        pruneTask?.cancel()
        collapseTask = nil
        pruneTask = nil
        expanded = nil
    }

    /// The page is visible again: re-arm every timer `suspend()` cancelled,
    /// whether or not the next snapshot differs. That is only the result
    /// timeout: `suspend()` folded the open banner, so there is no
    /// auto-collapse to restore. Internal for tests.
    func resume() {
        schedulePrune()
    }

    /// The transcript detached (its session is going away): forget
    /// everything. The next attach starts clean.
    func reset() {
        suspend()
        state = LiveEventsState()
        dismissedIds = []
    }
}
