#if os(iOS)
import UIKit
import AVFoundation

@MainActor
final class NativeStreamEngine: StreamEngine {
    let view: UIView
    let kind = StreamEngineKind.native
    private let playerView = NativePlayer.PlayerLayerView()
    private let coordinator: NativePlayer.Coordinator
    private let controller: StreamPlayerController
    private var tapGesture: UITapGestureRecognizer?
    private var swipeGesture: UISwipeGestureRecognizer?

    var wasPlayingJustNow: Bool {
        coordinator.wasPlayingJustNow
    }

    init(
        login: String,
        audioOnly: Bool,
        quality: PlayerQuality,
        allowsPictureInPicture: Bool = true,
        controller: StreamPlayerController,
        resolver: any StreamPlaylistResolving = TwitchHLS.Resolver()
    ) {
        self.controller = controller
        coordinator = NativePlayer.Coordinator(
            controller: controller,
            resolver: resolver,
            allowsPictureInPicture: allowsPictureInPicture
        )
        view = playerView
        playerView.backgroundColor = .clear
        playerView.playerLayer.videoGravity = .resizeAspect

        if allowsPictureInPicture {
            installInteraction()
        }

        coordinator.load(login: login, audioOnly: audioOnly, quality: quality, into: playerView)
    }

    func setAudioOnly(_ audioOnly: Bool, quality: PlayerQuality) {
        coordinator.setAudioOnly(audioOnly, quality: quality)
    }

    func setInteractive(_ interactive: Bool) {
        if interactive {
            installInteraction()
            coordinator.setAllowsPictureInPicture(true)
        } else {
            removeInteraction()
            coordinator.setAllowsPictureInPicture(false)
        }
    }

    func handleMediaServicesReset() {
        coordinator.handleMediaServicesReset()
    }

    func teardown() {
        removeInteraction()
        coordinator.teardown()
        playerView.playerLayer.player = nil
        playerView.removeFromSuperview()
    }

    private func installInteraction() {
        controller.hostView = playerView
        if tapGesture == nil, swipeGesture == nil {
            let tap = UITapGestureRecognizer(target: coordinator, action: #selector(NativePlayer.Coordinator.tapped))
            let swipe = UISwipeGestureRecognizer(target: coordinator, action: #selector(NativePlayer.Coordinator.swipedDown))
            swipe.direction = .down
            tap.require(toFail: swipe)
            playerView.addGestureRecognizer(swipe)
            playerView.addGestureRecognizer(tap)
            tapGesture = tap
            swipeGesture = swipe
        }
    }

    private func removeInteraction() {
        if controller.hostView === playerView {
            controller.hostView = nil
        }
        if let tap = tapGesture {
            playerView.removeGestureRecognizer(tap)
            tapGesture = nil
        }
        if let swipe = swipeGesture {
            playerView.removeGestureRecognizer(swipe)
            swipeGesture = nil
        }
    }
}
#endif
