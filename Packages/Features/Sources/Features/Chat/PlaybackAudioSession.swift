#if os(iOS)
import AVFoundation
import Core
import os

private let logger = AppLogger.make("Features.PlaybackAudioSession")

/// The app's audio session as the native player needs it.
///
/// `setCategory` and `setActive` block — for a noticeable moment when other
/// audio has to be interrupted or handed back — so they run on one serial
/// queue: off the main actor, and still in the order they were asked for.
///
/// A muted stream mixes with other audio, so a video that autoplays silent
/// doesn't cut the user's music; unmuting makes the session the exclusive
/// one. The session is taken down only when native playback really stops
/// (`PlaybackCenter` decides), not for an engine rebuilt on a channel change.
final class PlaybackAudioSession: @unchecked Sendable {
    // @unchecked: `isActive` is only touched on `queue`.

    static let shared = PlaybackAudioSession()

    private let queue = DispatchQueue(label: "com.andrewbeshay.chattr.playback-audio", qos: .userInitiated)
    /// This object brought the session up and hasn't taken it down since.
    private var isActive = false

    private init() {}

    /// Sets the session up for a stream that is `muted` or not and activates
    /// it. Returns once that's done, so the player can be started into the
    /// right category.
    func activate(muted: Bool) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.configure(mixable: muted)
                continuation.resume()
            }
        }
    }

    /// The stream was muted or unmuted. Does nothing while the session is
    /// down — the next `activate` picks the right category itself.
    func setMuted(_ muted: Bool) {
        queue.async {
            guard self.isActive else { return }
            self.configure(mixable: muted)
        }
    }

    /// Native playback stopped: hand audio back to whatever it interrupted.
    func deactivate() {
        queue.async {
            guard self.isActive else { return }
            self.isActive = false
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                logger.warning("Audio session deactivation failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Media services were reset: the session is down, whatever this object
    /// did before.
    func invalidate() {
        queue.async {
            self.isActive = false
        }
    }

    private func configure(mixable: Bool) {
        let session = AVAudioSession.sharedInstance()
        let options: AVAudioSession.CategoryOptions = mixable ? [.mixWithOthers] : []
        do {
            // Compared against the session itself, not a remembered value:
            // a media services reset, or other audio in the app, can have
            // changed it since.
            if session.category != .playback
                || session.mode != .moviePlayback
                || session.categoryOptions != options {
                try session.setCategory(.playback, mode: .moviePlayback, options: options)
            }
            // Also after an interruption, when the system took the session
            // down without telling this object.
            try session.setActive(true)
            isActive = true
        } catch {
            logger.warning("Audio session setup failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
#endif
