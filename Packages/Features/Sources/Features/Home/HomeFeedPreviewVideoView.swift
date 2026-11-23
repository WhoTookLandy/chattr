#if os(iOS)
import SwiftUI
import UIKit
import AVFoundation
import Combine

/// Lightweight `AVPlayerLayer` surface for the single focused `LiveStreamCard`
/// playing an inline live preview on Home → Live.
///
/// Observes `AVPlayerLayer.isReadyForDisplay` and reports back to
/// `HomeFeedPreviewController` so the card keeps its static thumbnail visible
/// until the first real video frame is painted — zero black flash.
struct HomeFeedPreviewVideoView: UIViewRepresentable {
    let controller: HomeFeedPreviewController
    let streamID: String

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    func makeUIView(context: Context) -> NativePlayer.PlayerLayerView {
        let view = NativePlayer.PlayerLayerView()
        view.backgroundColor = .clear
        view.clipsToBounds = true
        view.playerLayer.videoGravity = .resizeAspectFill
        view.playerLayer.player = controller.player
        context.coordinator.observe(layer: view.playerLayer, streamID: streamID)
        return view
    }

    func updateUIView(_ view: NativePlayer.PlayerLayerView, context: Context) {
        if view.playerLayer.player !== controller.player {
            view.playerLayer.player = controller.player
        }
        context.coordinator.observe(layer: view.playerLayer, streamID: streamID)
    }

    static func dismantleUIView(_ view: NativePlayer.PlayerLayerView, coordinator: Coordinator) {
        coordinator.stopObserving()
        view.playerLayer.player = nil
    }

    @MainActor
    final class Coordinator {
        private let controller: HomeFeedPreviewController
        private var observedStreamID: String?
        private var subscription: AnyCancellable?

        init(controller: HomeFeedPreviewController) {
            self.controller = controller
        }

        func observe(layer: AVPlayerLayer, streamID: String) {
            if observedStreamID == streamID, subscription != nil {
                if layer.isReadyForDisplay {
                    notifyReady(streamID: streamID)
                }
                return
            }
            observedStreamID = streamID
            subscription?.cancel()
            subscription = layer.publisher(for: \.isReadyForDisplay)
                .receive(on: DispatchQueue.main)
                .sink { [weak controller] ready in
                    controller?.markVideoReady(for: streamID, isReady: ready)
                }
            if layer.isReadyForDisplay {
                notifyReady(streamID: streamID)
            }
        }

        /// Defers the initial readiness write off `makeUIView` / `updateUIView`
        /// so SwiftUI never sees an `@Observable` mutation mid-view-update.
        private func notifyReady(streamID: String) {
            Task { @MainActor [weak controller] in
                controller?.markVideoReady(for: streamID, isReady: true)
            }
        }

        func stopObserving() {
            subscription?.cancel()
            subscription = nil
            observedStreamID = nil
        }
    }
}
#endif
