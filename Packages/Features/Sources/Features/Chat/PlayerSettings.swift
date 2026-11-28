import Foundation

/// Video preferences (Settings → Video).
enum PlayerSettings {
    /// Play streams in AVPlayer instead of Twitch's web player. Off by
    /// default: it relies on Twitch's private web playback endpoint (see
    /// `TwitchHLS`), which isn't a supported third-party API and can break.
    static let nativePlayerKey = "chattr.player.native"
    /// Native player only — caps the HLS variant AVPlayer may pick.
    static let maxQualityKey = "chattr.player.maxQuality"
    /// Native player (video, audio-only, and pinned background audio) — uses
    /// a tighter live-edge offset and forward-buffer cap to reduce delay
    /// relative to chat, at the cost of a smaller stall margin.
    static let lowLatencyKey = "chattr.player.lowLatency"
    /// Listen-only mode: no video surface, just chat + stream audio. The
    /// native player switches to Twitch's audio-only rendition (saves data).
    static let audioOnlyKey = "chattr.player.audioOnly"
    /// Leaving a chat with video playing hands it to the system
    /// picture-in-picture window instead of the in-app mini player. Off by
    /// default; the mini player stays as the fallback when PiP can't start.
    static let systemPictureInPictureKey = "chattr.player.systemPiPOnLeave"
    /// Kill switch for the native path. Set, nothing resolves a playlist
    /// through `TwitchHLS`: every stream plays in Twitch's web player and
    /// audio-only (which needs the native engine) isn't offered. No
    /// Settings row writes it — it's for turning the unofficial endpoint
    /// off without shipping a build (a launch argument, managed
    /// configuration, or a remote flag written to this key).
    static let nativePlaybackDisabledKey = "chattr.player.nativeDisabled"

    /// The one read of the kill switch. `PlaybackCenter.play` decides the
    /// engine with it; the views use it only to stop offering audio-only.
    static var isNativePlaybackEnabled: Bool {
        !UserDefaults.standard.bool(forKey: nativePlaybackDisabledKey)
    }

    /// True when the user enabled Low Latency mode for native playback.
    static var isLowLatencyEnabled: Bool {
        UserDefaults.standard.bool(forKey: lowLatencyKey)
    }
}
