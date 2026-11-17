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
struct LiveEventsBannerArea: View {
    let chatModel: ChatTranscriptModel

    @State private var model = LiveEventsModel()

    @AppStorage(LiveEventsSettings.pollsKey) private var showPolls = true
    @AppStorage(LiveEventsSettings.predictionsKey) private var showPredictions = true
    @AppStorage(LiveEventsSettings.hypeTrainKey) private var showHypeTrain = true

    var body: some View {
        let isAttached = chatModel.attachState == .attached
        VStack(spacing: 6) {
            ForEach(LiveEventKind.allCases, id: \.self) { kind in
                banner(for: kind)
            }
        }
        .padding(.horizontal, 12)
        .animation(.snappy(duration: 0.25), value: model.state)
        .animation(.snappy(duration: 0.25), value: model.expanded)
        .animation(.snappy(duration: 0.25), value: model.dismissedIds)
        // Subscribe once the transcript is attached (that's when its session
        // is known); re-runs on detach / re-attach. Cancelling ends
        // `model.run`, which unsubscribes and resets.
        .task(id: isAttached) {
            guard isAttached, let session = chatModel.liveEventsSession else { return }
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
