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
    /// preference and the mute / pause state.
    func refreshAutomaticPictureInPicture() {
        guard let pip = pictureInPicture else { return }
        let allow = allowsAutomaticPictureInPicture
        if pip.canStartPictureInPictureAutomaticallyFromInline != allow {
            pip.canStartPictureInPictureAutomaticallyFromInline = allow
        }
    }

    /// The native player is going to PiP (or already is) as the app leaves.
    var continuesInPictureInPicture: Bool {
        if isPictureInPictureActive { return true }
        guard let pip = pictureInPicture else { return false }
        return pip.isPictureInPictureActive
            || (pip.canStartPictureInPictureAutomaticallyFromInline && pip.isPictureInPicturePossible)
    }
}

// MARK: - App lifecycle

/// Decides what active streams do when the app leaves the foreground:
/// - `primary`: continue in PiP, keep playing native audio-only with sound, or
///   take a `.background` hold.
/// - `pinnedAudio`: unmuted native audio slots continue with the screen locked;
///   muted/volume-0 slots take a `.background` hold so they don't burn battery.
/// Also re-evaluates `PlaybackAudioSession` so a backgrounded web primary
/// yields immediately to an exclusive audio session for Lock Screen Now Playing.
@MainActor
final class PlaybackLifecycleObserver: NSObject {
    private weak var center: PlaybackCenter?
    private var backgroundHold: PlaybackHold?
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

    /// Always adopts the latest active `.background` hold token from
    /// `PlaybackCenter` so replacing a lapsed/dropped background hold
    /// mid-background still releases cleanly on `willEnterForeground`.
    func adoptBackgroundHold(_ hold: PlaybackHold) {
        backgroundHold = hold
    }

    func clearBackgroundHold(ifID id: UUID) {
        if backgroundHold?.id == id {
            backgroundHold = nil
        }
    }

    @objc private func willResignActive() {
        center?.primary?.controller.refreshAutomaticPictureInPicture()
    }

    /// Internal (not private) so tests can drive it without posting app-wide notifications.
    @objc func didEnterBackground() {
        isInBackground = true
        guard let center, center.hasAnyPlayback else { return }
        backgroundHold = center.holdPlayback(.background) ?? backgroundHold
        center.reconcileAudioSession()
        center.refreshNowPlaying()
    }

    @objc func willEnterForeground() {
        isInBackground = false
        guard let center else { return }
        if let hold = backgroundHold {
            backgroundHold = nil
            center.releaseHold(hold)
        }
        center.reconcileAudioSession()
        center.refreshNowPlaying()
    }
}
#endif
