import Foundation
import TwitchKit

/// What a chat page's stream header asks of the primary stage player
/// (`PlaybackCenter.primary`): play this page's stream, stop the primary
/// stream, or leave it alone. Never touches `pinnedAudio` slots.
///
/// Decided from the page's state alone, every input passed in, so the rules
/// can be tested without a view, a player or a status store.
struct StreamPlaybackPolicy: Equatable {
    /// What the player has loaded, as seen from this page.
    enum Playing: Equatable {
        case nothing
        case thisChannel
        case anotherChannel
        /// This page's channel is currently pinned in `PlaybackCenter.pinnedAudio`.
        case pinnedAudio
    }

    /// `PlaybackCenter.play`'s arguments for this page's stream.
    struct PlayRequest: Equatable {
        let stream: TwitchStream
        let native: Bool
        let audioOnly: Bool
        let quality: PlayerQuality
    }

    enum Decision: Equatable {
        case play(PlayRequest)
        case stop
        /// This page's stream is playing and the status reading taken at
        /// `readingAt` leaves it out: stop only if the player confirms it
        /// (`PlaybackCenter.offlineReadingConfirmed(at:)`).
        case stopIfOfflineConfirmed(readingAt: Date)
        case leaveAlone
    }

    /// This is the page centered in the pager.
    var isActivePage: Bool
    /// The shared "show video" preference (`StreamHeaderView.expandedKey`).
    var isExpanded: Bool
    /// What the status polls say right now; nil when they say offline, or nothing yet.
    var liveStream: TwitchStream?
    /// When this channel's status was fetched; nil until it has loaded.
    var statusFetchedAt: Date?
    var audioOnly: Bool
    /// Settings → Native Video Player.
    var prefersNativePlayer: Bool
    var quality: PlayerQuality
    /// `PlayerSettings.isNativePlaybackEnabled`, the native path's kill switch.
    var isNativePlaybackEnabled: Bool
    /// `StreamPlayerController.nativeFailed`.
    var nativeFailed: Bool
    var playing: Playing
    /// Whether an existing primary stream is currently loaded (relevant when
    /// `playing == .pinnedAudio` and another channel was primary).
    var hasOtherPrimaryPlaying: Bool = false
    /// Preserves system PiP when swiping onto a pinned channel while another
    /// channel's primary video is floating in PiP.
    var isPrimaryInPictureInPicture: Bool = false

    var decision: Decision {
        // Only the active page acts (pages leaving — swiped away or popped —
        // do nothing, so a popped chat's stream carries on into the mini player).
        guard isActivePage else { return .leaveAlone }

        // Swiping onto a channel already pinned in background audio must never
        // spawn a duplicate engine. Stop any non-PiP primary video so nothing
        // decodes invisibly off-screen or holds the screen awake; the pinned
        // channel stays audible in `pinnedAudio` with a 1-tap Show Video action.
        if playing == .pinnedAudio {
            if hasOtherPrimaryPlaying, !isPrimaryInPictureInPicture {
                return .stop
            }
            return .leaveAlone
        }

        if isExpanded, let liveStream {
            return .play(PlayRequest(
                stream: liveStream,
                native: prefersNativePlayer || audioOnly,
                audioOnly: audioOnly,
                quality: quality
            ))
        }
        // Waits for the status so a not-yet-loaded one doesn't kill the
        // stream the mini player handed back.
        guard let statusFetchedAt, playing != .nothing else { return .leaveAlone }
        // One poll that leaves this (playing) stream out doesn't stop it; a
        // second one does.
        if isExpanded, playing == .thisChannel {
            return .stopIfOfflineConfirmed(readingAt: statusFetchedAt)
        }
        // Video hidden here, or this channel is offline: stop primary only.
        return .stop
    }

    /// Whether listen-only is what this page actually gets.
    var isAudioOnlyInEffect: Bool {
        Self.audioOnlyInEffect(
            audioOnly: audioOnly,
            nativePlaybackEnabled: isNativePlaybackEnabled,
            nativeFailed: nativeFailed
        )
    }

    static func audioOnlyInEffect(
        audioOnly: Bool,
        nativePlaybackEnabled: @autoclosure () -> Bool,
        nativeFailed: @autoclosure () -> Bool
    ) -> Bool {
        audioOnly && nativePlaybackEnabled() && !nativeFailed()
    }
}
