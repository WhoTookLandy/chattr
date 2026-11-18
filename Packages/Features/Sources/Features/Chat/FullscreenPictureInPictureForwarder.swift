#if os(iOS)
import AVKit

/// Forwards PiP events from the fullscreen `AVPlayerViewController` to the
/// same controller hooks the inline player's PiP uses.
@MainActor
final class FullscreenPictureInPictureForwarder: NSObject, @preconcurrency AVPlayerViewControllerDelegate {
    private weak var controller: StreamPlayerController?

    init(controller: StreamPlayerController) {
        self.controller = controller
    }

    // Marked active on *will* start too: fullscreen PiP can begin as the app
    // leaves, and the background handler must see it before it pauses.
    func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        controller?.pictureInPictureDidStart()
    }

    // Undo the early "active" from will-start if PiP never came up.
    func playerViewController(
        _ playerViewController: AVPlayerViewController,
        failedToStartPictureInPictureWithError error: any Error
    ) {
        controller?.pictureInPictureEndedAmbiguously()
    }

    func playerViewControllerDidStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        controller?.pictureInPictureDidStart()
    }

    func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
        controller?.pictureInPictureDidStop()
    }

    func playerViewController(
        _ playerViewController: AVPlayerViewController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        controller?.pictureInPictureWillRestore()
        completionHandler(true)
    }
}
#endif
