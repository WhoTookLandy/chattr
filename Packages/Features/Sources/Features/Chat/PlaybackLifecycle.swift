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
    var continuesInPictureInPicture: Bool {
        guard let pip = pictureInPicture else { return false }
        return pip.isPictureInPictureActive
            || (pip.canStartPictureInPictureAutomaticallyFromInline && pip.isPictureInPicturePossible)
    }

    /// Pauses for the background. The web player is left alone while its
    /// video is in PiP (started by hand). Returns whether it paused, so the
    /// stream can resume when the app comes back.
    func pauseForBackground() -> Bool {
        if let avPlayer {
            guard avPlayer.timeControlStatus != .paused else { return false }
            avPlayer.pause()
            return true
        }
        guard let webView else { return false }
        webView.evaluateJavaScript(Self.webPauseForBackground)
        return true
    }

    /// Undoes `pauseForBackground`: back to the live edge.
    func resumeAfterBackground() {
        if avPlayer != nil {
            if isPaused { togglePlay() }
            return
        }
        webView?.evaluateJavaScript(Self.webResumeAfterBackground)
    }

    /// Pauses unless in PiP, and remembers that it did (so a video the
    /// user paused themselves isn't resumed later).
    private static let webPauseForBackground = """
    (function () {
      var v = document.querySelector('video');
      if (!v || v.paused || v.webkitPresentationMode === 'picture-in-picture') return;
      window.chattrBackgroundPaused = true;
      v.pause();
    })();
    """

    private static let webResumeAfterBackground = """
    (function () {
      if (!window.chattrBackgroundPaused) return;
      window.chattrBackgroundPaused = false;
      var v = document.querySelector('video');
      if (v && v.paused) { v.play(); }
    })();
    """
}

// MARK: - App lifecycle

/// Decides what the stream does when the app leaves the foreground:
/// continue in picture in picture, keep playing audio (audio-only mode with
/// sound), or pause — and resumes what it paused on return. Owned by
/// `PlaybackCenter`; selector-based observers unregister themselves when
/// this object goes away.
@MainActor
final class PlaybackLifecycleObserver: NSObject {
    private weak var center: PlaybackCenter?
    /// This observer paused the stream on the way out.
    private var pausedForBackground = false

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

    @objc private func didEnterBackground() {
        guard let center, center.isPlaying else { return }
        let controller = center.controller
        guard !controller.isPaused else { return }

        // The native engine, loaded or still resolving its playlist (no
        // AVPlayer yet, so `controller.isNative` is still false).
        if center.engine is NativeStreamEngine {
            // Audio-only: listening with the screen off is the point —
            // unless it's muted, then there's nothing to hear.
            if center.audioOnly, !controller.nativeFailed, !controller.isMuted { return }
            if controller.continuesInPictureInPicture { return }
        } else if controller.allowsAutomaticPictureInPicture {
            // Web player with PiP allowed: leave WebKit's own behaviour.
            return
        }
        // Pause what's playing now, and hold an engine that's still loading
        // (or rebuilding) paused when it finishes — otherwise it would
        // start playing in the background.
        controller.holdsForBackground = true
        _ = controller.pauseForBackground()
        pausedForBackground = true
    }

    @objc private func willEnterForeground() {
        center?.controller.holdsForBackground = false
        guard pausedForBackground else { return }
        pausedForBackground = false
        guard let center, center.isPlaying else { return }
        center.controller.resumeAfterBackground()
    }
}
#endif
