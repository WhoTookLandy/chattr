#if os(iOS)
import UIKit
import WebKit

@MainActor
final class WebStreamEngine: StreamEngine {
    let view: UIView
    let kind = StreamEngineKind.web
    private let webView: WKWebView
    private let coordinator: TwitchWebPlayer.Coordinator

    /// `reusing`: the web view of the web engine this one replaces
    /// (`releaseWebView()`), navigated to `login` instead of a new one
    /// being built. The startup sequence is the same either way: a new
    /// coordinator, `beginWebEngineLoad`, then the page's first report.
    init(login: String, controller: StreamPlayerController, reusing recycled: WKWebView? = nil) {
        coordinator = TwitchWebPlayer.Coordinator(controller: controller)
        // Loads paused when the user paused or a hold is out — the page
        // never autoplays against intent (`StreamPlayerController.noteDidPlay`).
        // Play/pause made while it loads are applied once it reports ready
        // (`StreamPlayerController.noteEngineReady`).
        let autoplay = controller.beginWebEngineLoad()
        if let recycled {
            TwitchWebPlayer.navigate(
                recycled,
                to: login,
                autoplay: autoplay,
                muted: controller.startsMuted,
                coordinator: coordinator
            )
            webView = recycled
        } else {
            webView = TwitchWebPlayer.makeWebView(
                login: login,
                autoplay: autoplay,
                muted: controller.startsMuted,
                coordinator: coordinator
            )
        }
        view = webView
        controller.webView = webView
    }

    func teardown() {
        coordinator.controller.webView = nil
        TwitchWebPlayer.teardown(webView)
    }

    /// Ends this page like `teardown`, but keeps the web view for the next
    /// channel's engine (`init(login:controller:reusing:)`). This engine is
    /// done after it.
    func releaseWebView() -> WKWebView {
        coordinator.controller.webView = nil
        TwitchWebPlayer.quiesce(webView)
        return webView
    }
}
#endif
