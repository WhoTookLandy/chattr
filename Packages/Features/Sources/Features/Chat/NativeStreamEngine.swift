#if os(iOS)
import UIKit
import AVFoundation

@MainActor
final class NativeStreamEngine: StreamEngine {
    let view: UIView
    let kind = StreamEngineKind.native
    private let playerView = NativePlayer.PlayerLayerView()
    private let coordinator: NativePlayer.Coordinator

    init(
        login: String,
        audioOnly: Bool,
        quality: PlayerQuality,
        controller: StreamPlayerController,
        resolver: any StreamPlaylistResolving = TwitchHLS.Resolver()
    ) {
        coordinator = NativePlayer.Coordinator(controller: controller, resolver: resolver)
        view = playerView
        playerView.backgroundColor = .clear
        playerView.playerLayer.videoGravity = .resizeAspect

        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(NativePlayer.Coordinator.tapped))
        let swipe = UISwipeGestureRecognizer(target: coordinator, action: #selector(NativePlayer.Coordinator.swipedDown))
        swipe.direction = .down
        tap.require(toFail: swipe)
        playerView.addGestureRecognizer(swipe)
        playerView.addGestureRecognizer(tap)

        controller.hostView = playerView
        coordinator.load(login: login, audioOnly: audioOnly, quality: quality, into: playerView)
    }

    func teardown() {
        coordinator.teardown()
        playerView.playerLayer.player = nil
        playerView.removeFromSuperview()
    }
}
#endif
