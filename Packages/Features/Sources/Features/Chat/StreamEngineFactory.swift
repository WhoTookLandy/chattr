#if os(iOS)
import WebKit

/// What `PlaybackCenter` asks its engine factory for.
enum StreamEngineRequest {
    case native(
        login: String,
        audioOnly: Bool,
        quality: PlayerQuality,
        allowsPictureInPicture: Bool = true
    )
    /// `reusing`: the web view of the web engine this one replaces
    /// (`WebStreamEngine.releaseWebView()`), if there was one.
    case web(login: String, reusing: WKWebView?)
}

/// Builds the engine for a request, on the controller it reports to.
/// `PlaybackCenter` is handed one (`PlaybackCenter.init`) so its tests can
/// stand in an engine that builds no `WKWebView` or `AVPlayer`.
typealias StreamEngineFactory = @MainActor (StreamEngineRequest, StreamPlayerController) -> any StreamEngine
#endif
