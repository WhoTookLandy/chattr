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
/// The trigger is `ChatTranscriptModel.apply` (already @MainActor). Keeping the
/// player on MainActor means no actor hop on the hot message path and
/// the `lastPlayedAt` throttle state is single-threaded by construction.
/// The actual audio playback is async inside the audio framework — we
/// just kick it.
///
/// The one-time setup is the exception: the first `play()` only starts
/// it and returns, and the sound follows when it finishes. Configuring the
/// audio session and decoding the asset are blocking calls, and `play()`
/// is called while a batch of messages is being applied.
@MainActor
public final class HighlightSoundPlayer {

    public static let shared = HighlightSoundPlayer()

    /// Throttle window — at most one play per this interval.
    private static let throttleInterval: TimeInterval = 0.5

    /// Built-in iOS system sound used when no custom `highlight.*` asset is
    /// bundled. `1003` (`ReceivedMessage.caf`) is iOS's short, native in-app
    /// Messages received ping — brief and crisp instead of the multi-second
    /// alert jingles (`1320`–`1336`).
    static let fallbackSystemSoundID: SystemSoundID = 1003

    /// Timestamp of the last play, for throttling. nil until first play.
    private var lastPlayedAt: Date?

    #if os(iOS)
    /// Lazily-constructed AVAudioPlayer for the bundled custom sound.
    /// nil when no bundled asset exists (we use the system-sound
    /// fallback in that case). Held strongly so it isn't deallocated
    /// mid-play.
    private var audioPlayer: AVAudioPlayer?
    #endif

    /// Asset setup runs once, started lazily by the first `play()` so we
    /// don't touch AVAudioSession at app launch (it has a non-trivial
    /// activation cost).
    private enum Setup {
        case notStarted
        case running
        case done
    }

    private var setup = Setup.notStarted

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

        switch setup {
        case .done:
            playNow()
        case .running:
            // The play that started setup sounds when it finishes; this one
            // would only stack on top of it.
            break
        case .notStarted:
            setup = .running
            Task {
                await self.runSetup()
                self.setup = .done
                self.playNow()
            }
        }
    }

    private func playNow() {
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

        // Fallback: built-in system sound (`ReceivedMessage.caf`, the short
        // native in-app Messages received ping). AudioServices plays it
        // respecting the device's ringer state without interrupting stream audio.
        AudioServicesPlaySystemSound(Self.fallbackSystemSoundID)
    }

    // MARK: - Setup

    private func runSetup() async {
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
            // …unless the in-chat stream player already holds a playback
            // session: downgrading it to ambient would mute the stream with
            // the silent switch and stop background audio / PiP.
            // Checked and set on the main actor, in one step, so it can't
            // interleave with the stream player taking the session.
            let session = AVAudioSession.sharedInstance()
            if session.category != .playback {
                try session.setCategory(.ambient, mode: .default)
                try session.setActive(true)
            }
            // Reading and decoding the file doesn't need the main actor.
            let prepared = try await Task.detached(priority: .userInitiated) {
                let player = try AVAudioPlayer(contentsOf: url)
                player.prepareToPlay()
                return PreparedPlayer(player: player)
            }.value
            audioPlayer = prepared.player
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

#if os(iOS)
/// Carries the player built off the main actor back to it. `@unchecked`:
/// the setup task creates it, hands it over once and never touches it again.
private struct PreparedPlayer: @unchecked Sendable {
    let player: AVAudioPlayer
}
#endif
