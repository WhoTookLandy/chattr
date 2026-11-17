#if os(iOS)
import SwiftUI
import UIKit
import WebKit

/// In-app live playback for the stream header.
///
/// Uses Twitch's official web player (`player.twitch.tv`) inside a
/// `WKWebView` — the ToS-sanctioned way for third-party apps to play Twitch
/// video. The player page is loaded top-level (not in an iframe), so the
/// injected script below can reach its `<video>` element directly and drive
/// it from native controls.
///
/// Twitch's own overlay is suppressed by swallowing taps on the video
/// surface in the capture phase (`chattrBridge` below) and forwarding them
/// to native as `tap`, which toggles chattr's chrome instead. Taps on real
/// buttons inside the page (the mature-content "Start Watching" gate, the
/// "click to unmute" prompt) pass through untouched.
struct StreamPlayerView: UIViewRepresentable {
    let channelLogin: String
    let controller: StreamPlayerController

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let content = WKUserContentController()
        content.add(WeakScriptHandler(context.coordinator), name: Self.handlerName)
        content.addUserScript(WKUserScript(
            source: Self.bridgeScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        config.userContentController = content

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        // Clear until the page paints, so the stream poster underneath
        // shows instead of a black flash.
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.allowsLinkPreview = false
        webView.navigationDelegate = context.coordinator
        controller.webView = webView

        context.coordinator.loadedLogin = channelLogin
        webView.load(URLRequest(url: Self.playerURL(channelLogin)))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedLogin != channelLogin else { return }
        context.coordinator.loadedLogin = channelLogin
        controller.reset()
        webView.load(URLRequest(url: Self.playerURL(channelLogin)))
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        // Stop audio immediately — a torn-down page can otherwise keep
        // playing until the web process notices.
        webView.evaluateJavaScript("document.querySelectorAll('video').forEach(v=>v.pause())")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: handlerName)
        webView.stopLoading()
        coordinator.controller.webView = nil
    }

    // MARK: - Page

    static let handlerName = "chattr"

    /// `parent` is required by Twitch's player; it's only enforced against
    /// framing ancestors, so any stable domain works for a top-level load.
    static func playerURL(_ login: String) -> URL {
        var components = URLComponents(string: "https://player.twitch.tv/")!
        components.queryItems = [
            URLQueryItem(name: "channel", value: login),
            URLQueryItem(name: "parent", value: "chattr.app"),
            URLQueryItem(name: "autoplay", value: "true"),
            URLQueryItem(name: "muted", value: "false"),
            URLQueryItem(name: "playsinline", value: "true"),
        ]
        return components.url!
    }

    /// Bridge between the player page and native:
    ///   - swallows taps on the video surface → posts `{type:"tap"}`
    ///   - posts `{type:"state", …}` whenever the <video> changes
    ///   - exposes `window.chattrPlayer` for the native controls
    static let bridgeScript = """
    (function () {
      if (window.chattrPlayer) return;
      var post = function (m) { try { webkit.messageHandlers.chattr.postMessage(m); } catch (e) {} };
      var video = function () { return document.querySelector('video'); };
      var passThrough = function (t) {
        return t && t.closest && t.closest('button, a, input, select, [role="button"], [role="menu"], [role="dialog"]');
      };
      var swallow = function (e) {
        if (passThrough(e.target)) return;
        e.stopPropagation();
      };
      ['touchstart', 'touchend', 'pointerdown', 'pointerup', 'pointermove', 'mousemove', 'mousedown', 'mouseup'].forEach(function (n) {
        document.addEventListener(n, swallow, true);
      });
      // Swipe down on the video → hide it (native collapses the header).
      var startX = null, startY = null, swiped = false;
      document.addEventListener('touchstart', function (e) {
        var t = e.touches[0]; startX = t.clientX; startY = t.clientY; swiped = false;
      }, true);
      document.addEventListener('touchend', function (e) {
        if (startY === null) return;
        var t = e.changedTouches[0];
        var dy = t.clientY - startY, dx = Math.abs(t.clientX - startX);
        startY = null;
        if (dy > 50 && dx < dy) { swiped = true; post({ type: 'swipeDown' }); }
      }, true);
      document.addEventListener('click', function (e) {
        if (passThrough(e.target)) return;
        e.stopPropagation();
        e.preventDefault();
        if (swiped) { swiped = false; return; }
        post({ type: 'tap' });
      }, true);

      var lastState = '';
      var report = function () {
        var v = video();
        if (!v) return;
        var pip = !!(v.webkitSupportsPresentationMode && v.webkitSupportsPresentationMode('picture-in-picture'));
        var state = { type: 'state', paused: v.paused, muted: v.muted, pip: pip, playing: !v.paused && v.readyState > 2 };
        var key = JSON.stringify(state);
        if (key !== lastState) { lastState = key; post(state); }
      };
      ['play', 'playing', 'pause', 'volumechange', 'loadeddata', 'waiting'].forEach(function (n) {
        document.addEventListener(n, report, true);
      });
      setInterval(report, 1000);

      window.chattrPlayer = {
        togglePlay: function () { var v = video(); if (!v) return; if (v.paused) { v.play(); } else { v.pause(); } },
        toggleMute: function () { var v = video(); if (!v) return; v.muted = !v.muted; if (!v.muted && v.volume === 0) { v.volume = 1; } },
        fullscreen: function () { var v = video(); if (v && v.webkitEnterFullscreen) { v.webkitEnterFullscreen(); } },
        pip: function () {
          var v = video(); if (!v || !v.webkitSetPresentationMode) return;
          v.webkitSetPresentationMode(v.webkitPresentationMode === 'picture-in-picture' ? 'inline' : 'picture-in-picture');
        },
        pause: function () { var v = video(); if (v) { v.pause(); } }
      };
    })();
    """

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let controller: StreamPlayerController
        var loadedLogin: String?

        init(controller: StreamPlayerController) {
            self.controller = controller
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "tap":
                controller.onTap?()
            case "swipeDown":
                controller.onSwipeDown?()
            case "state":
                controller.isPaused = body["paused"] as? Bool ?? false
                controller.isMuted = body["muted"] as? Bool ?? false
                controller.canPictureInPicture = body["pip"] as? Bool ?? false
                if body["playing"] as? Bool == true { controller.hasStarted = true }
            default:
                break
            }
        }

        /// Keep the player page in place: anything that tries to navigate
        /// away (channel links, "watch on Twitch") opens outside the app.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            guard navigationAction.targetFrame?.isMainFrame ?? true,
                  navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url
            else { return .allow }
            _ = await UIApplication.shared.open(url)
            return .cancel
        }
    }
}

/// `WKUserContentController` retains its handlers; this breaks the
/// webView → content controller → coordinator → controller → webView cycle.
@MainActor
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?

    init(_ target: any WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

/// Restores the edge swipe-back gesture while the navigation bar is hidden
/// (UIKit's default pop-gesture delegate refuses to begin without a visible
/// bar). Installed once per navigation controller; only allows the pop when
/// there's something to pop, and makes horizontal scroll views (the chat
/// pager) wait for the edge swipe to fail so swiping from the very left edge
/// always means "back".
struct SwipeBackEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController {
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard let nav = navigationController,
                  let gesture = nav.interactivePopGestureRecognizer,
                  !(gesture.delegate is PopGestureDelegate)
            else { return }
            let delegate = PopGestureDelegate(navigationController: nav)
            // The gesture holds its delegate weakly; anchor it to the nav.
            objc_setAssociatedObject(nav, &PopGestureDelegate.associationKey, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            gesture.delegate = delegate
        }
    }

    final class PopGestureDelegate: NSObject, UIGestureRecognizerDelegate {
        nonisolated(unsafe) static var associationKey: UInt8 = 0
        weak var navigationController: UINavigationController?

        init(navigationController: UINavigationController) {
            self.navigationController = navigationController
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let nav = navigationController else { return false }
            return nav.viewControllers.count > 1 && nav.transitionCoordinator == nil
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            otherGestureRecognizer.view is UIScrollView
        }
    }
}
#endif
