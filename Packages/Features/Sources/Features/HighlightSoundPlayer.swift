import Foundation
import Core
import AudioToolbox
import os
#if os(iOS)
import AVFoundation
#endif

private let logger = AppLogger.make("Features.HighlightSound")

/// Plays a short sound when a highlighted live chat message arrives
/// (self-mention or matched keyword). Throttled to one play per 500ms
/// so a burst of highlights (raid where everyone @s you) doesn't
/// machine-gun the speaker.
///
/// ## Asset strategy
///
/// Per the design spec, this should ship a bundled ambient sound and
/// play it via `AVAudioPlayer` with `AVAudioSession.Category.ambient`
/// (mixes with other audio, doesn't duck/interrupt music or a stream).
///
/// We look for a bundled resource named `highlight` (any of caf / aiff
/// / wav / mp3). If found, we use the AVAudioPlayer + ambient path.
/// If NOT found (current state — no asset committed yet), we fall back
/// to a built-in iOS system sound via `AudioServicesPlaySystemSound`.
/// Dropping a `highlight.caf` into the app bundle later automatically
/// upgrades to the custom-sound path with no code change.
///
/// ## Why @MainActor
///
/// The trigger is `TabChatModel.apply` (already @MainActor). Keeping the
/// player on MainActor means no actor hop on the hot message path and
/// the `lastPlayedAt` throttle state is single-threaded by construction.
/// The actual audio playback is async inside the audio framework — we
/// just kick it.
@MainActor
public final class HighlightSoundPlayer {

    public static let shared = HighlightSoundPlayer()

    /// Throttle window — at most one play per this interval.
    private static let throttleInterval: TimeInterval = 0.5

    /// Timestamp of the last play, for throttling. nil until first play.
    private var lastPlayedAt: Date?

    #if os(iOS)
    /// Lazily-constructed AVAudioPlayer for the bundled custom sound.
    /// nil when no bundled asset exists (we use the system-sound
    /// fallback in that case). Held strongly so it isn't deallocated
    /// mid-play.
    private var audioPlayer: AVAudioPlayer?
    #endif

    /// Whether we've already attempted asset setup. Setup runs once
    /// lazily on first `play()` so we don't touch AVAudioSession at
    /// app launch (it has a non-trivial activation cost).
    private var didSetup = false

    private init() {}

    /// Play the highlight sound, subject to the 500ms throttle. Safe to
    /// call on every highlighted message — excess calls within the
    /// window are dropped silently.
    public func play() {
        // Throttle: drop if we played within the window.
        let now = Date()
        if let last = lastPlayedAt, now.timeIntervalSince(last) < Self.throttleInterval {
            return
        }
        lastPlayedAt = now

        setupIfNeeded()

        #if os(iOS)
        if let player = audioPlayer {
            // Custom bundled sound via AVAudioPlayer (ambient category
            // was configured in setup). `play()` from the start —
            // `currentTime = 0` rewinds in case a prior play is still
            // tailing off (rare given the throttle, but correct).
            player.currentTime = 0
            player.play()
            return
        }
        #endif

        // Fallback: built-in system sound. 1336 is a subtle, short
        // notification tone ("Anticipate") that reads as a ping without
        // being jarring. AudioServices plays it respecting the device's
        // ringer state.
        AudioServicesPlaySystemSound(SystemSoundID(1336))
    }

    // MARK: - Setup

    private func setupIfNeeded() {
        guard !didSetup else { return }
        didSetup = true

        #if os(iOS)
        // Look for a bundled custom sound. Multiple extensions so a
        // future asset can be any common format.
        let candidateExtensions = ["caf", "aiff", "wav", "mp3"]
        var soundURL: URL?
        for ext in candidateExtensions {
            if let url = Bundle.main.url(forResource: "highlight", withExtension: ext) {
                soundURL = url
                break
            }
        }

        guard let url = soundURL else {
            // No bundled asset — we'll use the system-sound fallback.
            // Not an error; this is the current expected state.
            logger.debug("No bundled highlight sound found; using system-sound fallback")
            return
        }

        do {
            // Ambient category: mixes with other audio (music, a stream
            // playing elsewhere), doesn't interrupt or duck. Matches the
            // spec's intent for a non-intrusive ping.
            try AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            audioPlayer = player
            logger.info("Loaded bundled highlight sound: \(url.lastPathComponent, privacy: .public)")
        } catch {
            // Asset existed but failed to load/configure — fall back to
            // system sound rather than crashing.
            logger.warning("Failed to set up bundled highlight sound: \(error.localizedDescription, privacy: .public)")
            audioPlayer = nil
        }
        #endif
    }
}
