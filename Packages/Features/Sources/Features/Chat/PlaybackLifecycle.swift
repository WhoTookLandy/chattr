#if os(iOS)
import UIKit
import AVKit
import WebKit

// MARK: - Picture in picture gate

extension StreamPlayerController {
    /// Whether leaving the app may hand this stream to picture in picture,
    /// per Settings → Video & Device → Picture in Picture.
    var allowsAutomaticPictureInPicture: Bool {
        switch PlaybackPreferences.pictureInPicture {
        case .off: false
        case .always: true
        case .whenSoundOn: !isMuted && !isPaused
        }
    }

    /// Keeps the native PiP controller's auto-start flag in step with the
    /// preference and the mute / pause state. Called on every engine state
    /// change (`update`), when the PiP controller is attached, and when the
    /// app is about to resign active (so a settings change made mid-stream
    /// applies). One property compare; no observation, no polling.
    func refreshAutomaticPictureInPicture() {
        guard let pip = pictureInPicture else { return }
        let allow = allowsAutomaticPictureInPicture
        if pip.canStartPictureInPictureAutomaticallyFromInline != allow {
            pip.canStartPictureInPictureAutomaticallyFromInline = allow
        }
    }

    /// The native player is going to PiP (or already is) as the app leaves.
    /// `isPictureInPictureActive` covers PiP started from the fullscreen
    /// `AVPlayerViewController`, which has its own PiP controller that
    /// `pictureInPicture` (the inline one) knows nothing about.
    var continuesInPictureInPicture: Bool {
        if isPictureInPictureActive { return true }
        guard let pip = pictureInPicture else { return false }
        return pip.isPictureInPictureActive
            || (pip.canStartPictureInPictureAutomaticallyFromInline && pip.isPictureInPicturePossible)
    }

}

// MARK: - App lifecycle

/// Decides what the stream does when the app leaves the foreground:
/// continue in picture in picture, keep playing audio (audio-only mode with
/// sound), or pause — and resumes what it paused on return. The pause is
/// a `.background` hold (`PlaybackCenter.holdPlayback(_:)`), the same
/// mechanism a clip uses: it also keeps an engine still loading (or
/// rebuilding) from starting in the background, re-pauses a play reported
/// while it's out, and on release resumes only if the stream was meant to
/// be playing and no other hold (a clip) is still out. Owned by
/// `PlaybackCenter`; selector-based observers unregister themselves when
/// this object goes away.
@MainActor
final class PlaybackLifecycleObserver: NSObject {
    private weak var center: PlaybackCenter?
    /// The hold this observer took on the way out. It lapses on its own if
    /// the stream stops or the channel changes meanwhile.
    private var backgroundHold: PlaybackHold?
    /// Between `didEnterBackground` and `willEnterForeground`. A native
    /// engine that fails while this is true and the stream is audio-only
    /// has no web player to fall back to (`PlaybackCenter`).
    private(set) var isInBackground = false

    init(center: PlaybackCenter) {
        self.center = center
        super.init()
        let notifications = NotificationCenter.default
        notifications.addObserver(
            self, selector: #selector(willResignActive),
            name: UIApplication.willResignActiveNotification, object: nil
        )
        notifications.addObserver(
            self, selector: #selector(didEnterBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil
        )
        notifications.addObserver(
            self, selector: #selector(willEnterForeground),
            name: UIApplication.willEnterForegroundNotification, object: nil
        )
    }

    /// Before the system decides on auto-PiP: make sure the gate reflects
    /// the current preference.
    @objc private func willResignActive() {
        center?.controller.refreshAutomaticPictureInPicture()
    }

    /// Internal (not private) so tests can drive it without posting
    /// app-wide notifications.
    @objc func didEnterBackground() {
        isInBackground = true
        guard let center, center.isPlaying else { return }
        let controller = center.controller
        // Decided on intent, not the displayed paused state: a stream
        // paused only because another hold (a clip) is out still needs
        // this hold, or releasing the other one in the background would
        // resume it there. (It inherits that hold's resume decision.)
        guard controller.wantsPlayback else { return }
        // Held paused, the stream can't hand itself to PiP on the way out.
        let heldPaused = controller.isHeld

        // The native engine, loaded or still resolving its playlist (no
        // AVPlayer yet, so `controller.isNative` is still false).
        if center.engine?.kind == .native {
            // Audio-only: listening with the screen off is the point —
            // unless it's muted, then there's nothing to hear.
            if center.audioOnly, !controller.nativeFailed, !controller.isMuted { return }
            if controller.isPictureInPictureActive { return }
            if !heldPaused, controller.continuesInPictureInPicture { return }
        } else if controller.isPictureInPictureActive
                    || (!heldPaused && controller.allowsAutomaticPictureInPicture) {
            // Web player with PiP allowed, or already in PiP (started by
            // hand): leave WebKit's own behaviour.
            return
        }
        // Pause what's playing now, and hold an engine that's still loading
        // (or rebuilding) paused when it finishes — otherwise it would
        // start playing in the background.
        // (nil while this stream already has one: keep that; a lapsed one
        // from an earlier stream is simply replaced.)
        backgroundHold = center.holdPlayback(.background) ?? backgroundHold
    }

    @objc func willEnterForeground() {
        isInBackground = false
        guard let hold = backgroundHold else { return }
        backgroundHold = nil
        // Resumes at the live edge, only what this hold paused.
        center?.releaseHold(hold)
    }
}
#endif
