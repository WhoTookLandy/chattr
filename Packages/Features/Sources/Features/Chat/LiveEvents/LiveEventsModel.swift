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

    // MARK: - Feed

    /// Drains `session`'s live events until the calling task is cancelled
    /// (the banner area's `.task` going away), then unsubscribes and resets.
    func run(session: ChannelSession) async {
        let subscription = await session.subscribeLiveEvents()
        // AsyncStream iteration ends on task cancellation as well as on
        // `finish()` (unsubscribe / session stop).
        for await _ in subscription.wakeups {
            guard !Task.isCancelled else { break }
            if let latest = subscription.takeLatest() {
                receive(latest)
            }
        }
        await session.unsubscribeLiveEvents(subscription.token)
        reset()
    }

    /// Applies a new state from the session (or from a local prune).
    /// Internal for tests.
    func receive(_ new: LiveEventsState) {
        guard new != state else { return }
        let old = state
        state = new

        if let kind = new.attentionKind(comparedTo: old),
           LiveEventsSettings.isEnabled(kind),
           let id = eventId(of: kind),
           !dismissedIds.contains(id) {
            expand(kind, for: Self.attentionDuration)
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

    private func reset() {
        collapseTask?.cancel()
        pruneTask?.cancel()
        collapseTask = nil
        pruneTask = nil
        state = LiveEventsState()
        expanded = nil
        dismissedIds = []
    }
}
