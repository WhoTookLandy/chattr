import Foundation
import TwitchKit

/// What a chat page's stream header asks of the app's one player
/// (`PlaybackCenter`): play this page's stream, stop what's playing, or
/// leave it alone. Decided from the page's state alone, every input passed
/// in, so the rules can be tested without a view, a player or a status
/// store.
///
/// `StreamHeaderView` gathers the inputs and carries the decision out. When
/// it decides again — its task ids, the settle after a swipe — stays with
/// the view.
struct StreamPlaybackPolicy: Equatable {
    /// What the player has loaded, as seen from this page.
    enum Playing: Equatable {
        case nothing
        case thisChannel
        case anotherChannel
    }

    /// `PlaybackCenter.play`'s arguments for this page's stream.
    struct PlayRequest: Equatable {
        /// The polled stream being asked for: its title goes to the player,
        /// and `PlaybackCenter.noteLive` remembers it.
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
    /// What the status polls say right now; nil when they say offline, or
    /// nothing yet.
    var liveStream: TwitchStream?
    /// When this channel's status was fetched; nil until it has loaded.
    var statusFetchedAt: Date?
    var audioOnly: Bool
    /// Settings → Native Video Player.
    var prefersNativePlayer: Bool
    var quality: PlayerQuality
    /// `PlayerSettings.isNativePlaybackEnabled`, the native path's kill
    /// switch.
    var isNativePlaybackEnabled: Bool
    /// `StreamPlayerController.nativeFailed`.
    var nativeFailed: Bool
    var playing: Playing

    var decision: Decision {
        // Only the active page acts (pages leaving — swiped away or popped —
        // do nothing, so a popped chat's stream carries on into the mini
        // player).
        guard isActivePage else { return .leaveAlone }
        if isExpanded, let liveStream {
            return .play(PlayRequest(
                stream: liveStream,
                // Audio-only needs the native engine (see
                // `isAudioOnlyInEffect`). Whether it gets one is
                // `PlaybackCenter.play`'s call: the kill switch and a
                // failed native engine are applied there.
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
        // Video hidden here, or this channel is offline: whatever was
        // playing (this stream, or another chat's) stops.
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

    /// Audio-only needs the native engine (Twitch's audio-only rendition);
    /// the web player can't play hidden — it needs a visible, full-size
    /// surface to autoplay and to show its "Start Watching" gate. So if the
    /// native engine fails, audio-only falls back to the normal video
    /// layout — and so it does when the native path is switched off
    /// (`PlayerSettings.isNativePlaybackEnabled`).
    ///
    /// The last two are read only as far as needed, like `&&`: a view
    /// calling this from `body` with the preference off reads neither the
    /// kill switch nor the player's (observed) `nativeFailed`.
    static func audioOnlyInEffect(
        audioOnly: Bool,
        nativePlaybackEnabled: @autoclosure () -> Bool,
        nativeFailed: @autoclosure () -> Bool
    ) -> Bool {
        audioOnly && nativePlaybackEnabled() && !nativeFailed()
    }
}
