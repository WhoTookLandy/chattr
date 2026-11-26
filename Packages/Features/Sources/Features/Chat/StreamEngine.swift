#if os(iOS)
import UIKit

/// One live player instance — web (`TwitchWebPlayer`) or native
/// (`NativePlayer`). Owned by `PlaybackCenter`, never by a view, so the
/// stream keeps playing while its surface moves between the chat header and
/// the mini player.
@MainActor
protocol StreamEngine: AnyObject {
    var view: UIView { get }
    /// Which player this is. `PlaybackCenter` asks this, not the engine's
    /// type, so a stand-in engine can be either.
    var kind: StreamEngineKind { get }
    /// Switches between audio-only and video in place for the same channel,
    /// keeping playback alive instead of tearing the engine down.
    func setAudioOnly(_ audioOnly: Bool, quality: PlayerQuality)
    func teardown()
}

extension StreamEngine {
    func setAudioOnly(_ audioOnly: Bool, quality: PlayerQuality) {}
}

/// The two players a stream can be on.
enum StreamEngineKind: Sendable {
    /// Twitch's web player in a `WKWebView`.
    case web
    /// `AVPlayer` on a playlist from `StreamPlaylistResolving`.
    case native
}
#endif
