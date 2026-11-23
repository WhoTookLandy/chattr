import SwiftUI
import Channels

/// The stack of live-event banners at the top of a chat page — Hype Train,
/// prediction, poll, in `LiveEventKind` priority order, each collapsible to
/// one line. Self-contained: it owns its model, its feed subscription and
/// its settings reads, so another top-of-chat banner (a pinned message, a
/// "you were timed out" notice) can stack beside it in `ChatScreen`'s top
/// overlay without either knowing about the other.
///
/// ## Observation scoping
///
/// This body is the ONLY one that reads `LiveEventsModel`, so a vote tick
/// re-renders these few banners and nothing else. From `chatModel` it reads
/// just `attachState` (which changes on attach / detach, never per message)
/// to know when the session is there to subscribe to.
///
/// ## Visible page only
///
/// The pager pre-mounts the neighbouring chat pages, and they stay
/// attached, so attachment alone doesn't mean anyone is looking. This view
/// reads `ChatTabsModel.activeTabId` itself (like `ChatWelcomeOverlay` and
/// `StreamHeaderView`) so a swipe re-runs only this small body, never
/// `ChatScreen` or the transcript. Off-screen it holds no feed subscription
/// and runs no timers (`LiveEventsModel.suspend()`), and its countdowns
/// stop ticking. When the page becomes visible again it re-subscribes and
/// catches up from the session's current state.
struct LiveEventsBannerArea: View {
    let chatModel: ChatTranscriptModel
    /// The pager tab; nil outside the pager (always the visible page).
    let tabId: UUID?

    @Environment(\.chatTabs) private var chatTabs
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = LiveEventsModel()

    @AppStorage(LiveEventsSettings.pollsKey) private var showPolls = true
    @AppStorage(LiveEventsSettings.predictionsKey) private var showPredictions = true
    @AppStorage(LiveEventsSettings.hypeTrainKey) private var showHypeTrain = true

    private var isActive: Bool {
        guard let tabId else { return true }
        return chatTabs?.activeTabId == tabId
    }

    /// What the feed task keys on: it runs only while both hold.
    private struct FeedKey: Equatable {
        let isAttached: Bool
        let isActive: Bool
    }

    var body: some View {
        let isAttached = chatModel.attachState == .attached
        let active = isActive
        VStack(spacing: 6) {
            ForEach(LiveEventKind.allCases, id: \.self) { kind in
                banner(for: kind)
            }
        }
        .padding(.horizontal, 12)
        // Off-screen, popped back to Chats list, or backgrounded: freeze the
        // countdowns (no per-second TimelineView).
        .environment(
            \.liveEventCountdownsRunning,
            active && scenePhase == .active && (chatTabs?.isPresented ?? true)
        )
        .animation(.snappy(duration: 0.25), value: model.state)
        .animation(.snappy(duration: 0.25), value: model.expanded)
        .animation(.snappy(duration: 0.25), value: model.dismissedIds)
        // Subscribe while the transcript is attached (that's when its
        // session is known) AND this page is the visible one. A change to
        // either cancels the running feed, which unsubscribes and suspends.
        .task(id: FeedKey(isAttached: isAttached, isActive: active)) {
            guard isAttached, let session = chatModel.liveEventsSession else {
                // Detached: the session is going away, start clean next time.
                model.reset()
                return
            }
            guard active else { return }
            await model.run(session: session)
        }
    }

    @ViewBuilder
    private func banner(for kind: LiveEventKind) -> some View {
        switch kind {
        case .hypeTrain:
            if showHypeTrain, let train = model.state.hypeTrain, !model.isDismissed(train.id) {
                HypeTrainBannerView(
                    train: train,
                    isExpanded: model.expanded == .hypeTrain,
                    onToggle: { model.toggle(.hypeTrain) },
                    onDismiss: { model.dismiss(.hypeTrain) }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        case .prediction:
            if showPredictions, let prediction = model.state.prediction, !model.isDismissed(prediction.id) {
                PredictionBannerView(
                    prediction: prediction,
                    isExpanded: model.expanded == .prediction,
                    onToggle: { model.toggle(.prediction) },
                    onDismiss: { model.dismiss(.prediction) }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        case .poll:
            if showPolls, let poll = model.state.poll, !model.isDismissed(poll.id) {
                PollBannerView(
                    poll: poll,
                    isExpanded: model.expanded == .poll,
                    onToggle: { model.toggle(.poll) },
                    onDismiss: { model.dismiss(.poll) }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }
}
