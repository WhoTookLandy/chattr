#if os(iOS)
import UIKit

/// One live player instance — web (`TwitchWebPlayer`) or native
/// (`NativePlayer`). Owned by `PlaybackSlot` (inside `PlaybackCenter`), never
/// by a view, so the stream keeps playing while its surface moves between the
/// chat header, landscape stage, mini player, or headless background audio.
@MainActor
protocol StreamEngine: AnyObject {
    var view: UIView { get }
    /// Which player this is. `PlaybackCenter` asks this, not the engine's
    /// type, so a stand-in engine can be either.
    var kind: StreamEngineKind { get }
    /// True when the player was playing (or paused less than ~2 s ago by an
    /// OS interruption / route change) and meant to play.
    var wasPlayingJustNow: Bool { get }
    /// Switches between audio-only and video in place for the same channel,
    /// keeping playback alive instead of tearing the engine down.
    func setAudioOnly(_ audioOnly: Bool, quality: PlayerQuality)
    /// Switches between standard HLS and Low Latency (LL-HLS proxy + tighter
    /// buffer) in place for the same channel.
    func setLowLatency(_ enabled: Bool)
    /// Toggles interactive video capabilities (gestures, hostView, PiP) when
    /// a slot is promoted from headless background audio to primary video or
    /// demoted from primary to pinned background audio.
    func setInteractive(_ interactive: Bool)
    /// Rebuilds the underlying player after `AVAudioSession.mediaServicesWereResetNotification`.
    func handleMediaServicesReset()
    func teardown()
}

extension StreamEngine {
    var wasPlayingJustNow: Bool { false }
    func setAudioOnly(_ audioOnly: Bool, quality: PlayerQuality) {}
    func setLowLatency(_ enabled: Bool) {}
    func setInteractive(_ interactive: Bool) {}
    func handleMediaServicesReset() {}
}

/// The two players a stream can be on.
enum StreamEngineKind: Sendable, Equatable {
    /// Twitch's web player in a `WKWebView`.
    case web
    /// `AVPlayer` on a playlist from `StreamPlaylistResolving`.
    case native
}
#endif
