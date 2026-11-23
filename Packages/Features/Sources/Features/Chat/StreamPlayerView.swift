#if os(iOS)
import SwiftUI
import Core
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
enum TwitchWebPlayer {
    /// Builds the player web view for `login`. Owned by `WebStreamEngine`
    /// (and through it `PlaybackCenter`), so it survives leaving the chat.
    @MainActor
    static func makeWebView(login: String, autoplay: Bool, muted: Bool = false, coordinator: Coordinator) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController = WKUserContentController()

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
        attach(coordinator, to: webView)
        webView.load(URLRequest(url: playerURL(login, autoplay: autoplay, muted: muted)))
        return webView
    }

    /// Points a player web view a previous page has finished with
    /// (`quiesce`) at another channel, instead of building a new one: the
    /// `WKWebView` and its content process are the expensive part of a
    /// channel change. `coordinator` is the new page's; the old page's
    /// late messages don't reach it as its own (`Coordinator.pageID`).
    @MainActor
    static func navigate(
        _ webView: WKWebView,
        to login: String,
        autoplay: Bool,
        muted: Bool,
        coordinator: Coordinator
    ) {
        // The previous channel's last frame would sit over the new
        // channel's poster until the navigation commits. The coordinator
        // shows the view again then.
        webView.alpha = 0
        attach(coordinator, to: webView)
        webView.load(URLRequest(url: playerURL(login, autoplay: autoplay, muted: muted)))
    }

    /// Makes `coordinator` the one that hears from the pages `webView`
    /// loads from here on, each stamped with its `pageID`.
    @MainActor
    private static func attach(_ coordinator: Coordinator, to webView: WKWebView) {
        let content = webView.configuration.userContentController
        content.removeScriptMessageHandler(forName: handlerName)
        content.removeAllUserScripts()
        content.add(WeakScriptHandler(coordinator), name: handlerName)
        content.addUserScript(WKUserScript(
            source: "window.chattrPage = \(coordinator.pageID);",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        content.addUserScript(WKUserScript(
            source: bridgeScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        webView.navigationDelegate = coordinator
    }

    /// Ends the current page without giving up the web view: silences it
    /// and stops it reporting.
    @MainActor
    static func quiesce(_ webView: WKWebView) {
        // Stop audio and close any active PiP/fullscreen media presentations
        // immediately so a torn-down page can't keep playing or overlap a new
        // stream.
        webView.pauseAllMediaPlayback(completionHandler: nil)
        webView.closeAllMediaPresentations(completionHandler: nil)
        webView.evaluateJavaScript("document.querySelectorAll('video').forEach(v=>v.pause())")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: handlerName)
        webView.stopLoading()
    }

    @MainActor
    static func teardown(_ webView: WKWebView) {
        quiesce(webView)
        webView.navigationDelegate = nil
        webView.loadHTMLString("", baseURL: nil)
        webView.removeFromSuperview()
    }

    // MARK: - Page

    static let handlerName = "chattr"

    /// `parent` is required by Twitch's player; it's only enforced against
    /// framing ancestors, so any stable domain works for a top-level load.
    /// `autoplay` is the controller's `startsPlaying` when the page is
    /// built: a stream the user paused (or a hold keeps paused — a clip,
    /// the app in the background) loads paused, so the page never plays
    /// on its own against their intent. `muted` is the controller's
    /// `startsMuted` (Wi-Fi autoplay, or a rebuild of a muted stream).
    static func playerURL(_ login: String, autoplay: Bool, muted: Bool = false) -> URL {
        var components = URLComponents(url: Endpoints.TwitchPlayer.embed, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "channel", value: login),
            URLQueryItem(name: "parent", value: "chattr.app"),
            URLQueryItem(name: "autoplay", value: autoplay ? "true" : "false"),
            URLQueryItem(name: "muted", value: muted ? "true" : "false"),
            URLQueryItem(name: "playsinline", value: "true"),
        ]
        return components.url!
    }

    /// Bridge between the player page and native:
    ///   - swallows taps on the video surface → posts `{type:"tap"}`
    ///   - posts `{type:"state", …}` whenever the <video> changes
    ///   - exposes `window.chattrPlayer` for the native controls
    ///
    /// Every message carries the page's stamp (`window.chattrPage`, set by
    /// `attach`) so a reused web view's previous page can't be mistaken for
    /// the one loading.
    static let bridgeScript = """
    (function () {
      if (window.chattrPlayer) return;
      var post = function (m) {
        try {
          if (window.chattrPage !== undefined) { m.page = window.chattrPage; }
          webkit.messageHandlers.chattr.postMessage(m);
        } catch (e) {}
      };
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
      var pollId = null;
      var report = function () {
        var v = video();
        if (!v) return;
        if (pollId) { clearInterval(pollId); pollId = null; }
        var pip = !!(v.webkitSupportsPresentationMode && v.webkitSupportsPresentationMode('picture-in-picture'));
        var pipActive = v.webkitPresentationMode === 'picture-in-picture';
        var state = { type: 'state', paused: v.paused, muted: v.muted, pip: pip, pipActive: pipActive, playing: !v.paused && v.readyState > 2 };
        var key = JSON.stringify(state);
        if (key !== lastState) { lastState = key; post(state); }
      };
      ['play', 'playing', 'pause', 'volumechange', 'loadeddata', 'waiting', 'webkitpresentationmodechanged'].forEach(function (n) {
        document.addEventListener(n, report, true);
      });
      // Poll only until the <video> mounts and posts its initial state; after
      // that the capture-phase listeners drive every subsequent update.
      pollId = setInterval(report, 500);
      report();

      // PiP start / end. WebKit reports "inline" after both a return to the
      // app and a close, so tell them apart the way the system does it:
      // closing PiP with its x pauses the video, returning keeps it playing.
      var lastMode = 'inline';
      var lastPauseAt = 0;
      document.addEventListener('pause', function () { lastPauseAt = Date.now(); }, true);
      document.addEventListener('webkitpresentationmodechanged', function () {
        var v = video();
        if (!v) return;
        var mode = v.webkitPresentationMode;
        if (mode === 'picture-in-picture' && lastMode !== mode) { post({ type: 'pipStart' }); }
        if (lastMode === 'picture-in-picture' && mode !== 'picture-in-picture') {
          // The x can pause the video just before this event fires, so a
          // pause within the last moment counts as a close. A pause from
          // earlier (paused inside PiP) tells us nothing: "unknown" (null).
          var pausedJustNow = v.paused && (Date.now() - lastPauseAt) < 600;
          if (pausedJustNow) {
            post({ type: 'pipEnd', restored: false });
          } else if (v.paused) {
            post({ type: 'pipEnd', restored: null });
          } else {
            setTimeout(function () {
              var w = video();
              post({ type: 'pipEnd', restored: !!(w && !w.paused) });
            }, 250);
          }
        }
        lastMode = mode;
      }, true);

      window.chattrPlayer = {
        togglePlay: function () { var v = video(); if (!v) return; if (v.paused) { v.play(); } else { v.pause(); } },
        toggleMute: function () { var v = video(); if (!v) return; v.muted = !v.muted; if (!v.muted && v.volume === 0) { v.volume = 1; } },
        fullscreen: function () { var v = video(); if (v && v.webkitEnterFullscreen) { v.webkitEnterFullscreen(); } },
        pip: function () {
          var v = video(); if (!v || !v.webkitSetPresentationMode) return;
          v.webkitSetPresentationMode(v.webkitPresentationMode === 'picture-in-picture' ? 'inline' : 'picture-in-picture');
        },
        pause: function () { var v = video(); if (v) { v.pause(); } },
        // A background hold: leave a video that's in (or entering) PiP alone.
        pauseUnlessPictureInPicture: function () {
          var v = video(); if (v && v.webkitPresentationMode !== 'picture-in-picture') { v.pause(); }
        },
        play: function () { var v = video(); if (v) { v.play(); } }
      };
    })();
    """

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let controller: StreamPlayerController
        /// The page has posted its first state (one coordinator per page).
        private var didReportState = false

        /// Stamps this coordinator's page (`attach`). A web view reused
        /// for another channel can still deliver the previous page's
        /// messages — its last state report, the pause from `quiesce` —
        /// after the new coordinator is listening; taken as the new page's
        /// first report they would end its startup sequence
        /// (`noteEngineReady`) before it had loaded.
        let pageID: Int
        private static var lastPageID = 0

        init(controller: StreamPlayerController) {
            self.controller = controller
            Coordinator.lastPageID += 1
            pageID = Coordinator.lastPageID
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            // Unstamped messages pass: dropping them would leave the
            // player deaf if the stamp script ever failed to run.
            if let page = body["page"] as? Int, page != pageID { return }
            reveal(message.webView)
            switch type {
            case "tap":
                controller.onTap?()
            case "swipeDown":
                controller.onSwipeDown?()
            case "state":
                // `update` skips unchanged values: one changed field (say,
                // `paused`) would otherwise re-notify all four, re-running
                // every view that reads any of them.
                let paused = body["paused"] as? Bool ?? false
                // Held (a clip over the stream, or the app left without
                // PiP): the page's autoplay — the hold began after the page
                // was built with `autoplay=true` — mustn't start the stream
                // behind the clip or in the background.
                if controller.isHeld, !paused { controller.pauseForHold() }
                controller.update(\.isPaused, to: paused)
                controller.update(\.isMuted, to: body["muted"] as? Bool ?? false)
                controller.update(\.canPictureInPicture, to: body["pip"] as? Bool ?? false)
                if !didReportState {
                    didReportState = true
                    controller.noteEngineReady(paused: paused)
                }
                controller.noteWebState(paused: paused)
                // The page only autoplays when it was built meant to play
                // (`startsPlaying`), so any play is the user's intent —
                // except its startup autoplay after intent turned to paused
                // while it loaded, which `noteDidPlay` undoes instead.
                if body["playing"] as? Bool == true { controller.noteDidPlay() }
            case "pipStart":
                controller.pictureInPictureDidStart()
            case "pipEnd":
                // Same contract as the native delegate: a return to the app
                // restores (reopens the chat), a close just stops.
                switch body["restored"] as? Bool {
                case true?:
                    controller.pictureInPictureWillRestore()
                    controller.pictureInPictureDidStop()
                case false?:
                    controller.pictureInPictureDidStop()
                case nil:
                    // Known limitation of the web player: WebKit reports no
                    // return-vs-close event, only the presentation mode.
                    // If the video was paused inside PiP before it ended,
                    // neither is detectable, so neither reopen the chat
                    // nor stop playback. (The native player has a real
                    // restore callback and isn't affected.)
                    controller.pictureInPictureEndedAmbiguously()
                }
            default:
                break
            }
        }

        /// The new page has replaced the old one: show the web view again
        /// (`TwitchWebPlayer.navigate` hid it).
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            reveal(webView)
        }

        private func reveal(_ webView: WKWebView?) {
            guard let webView, webView.alpha != 1 else { return }
            webView.alpha = 1
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
/// bar).
///
/// Scoped to the chat screen: our delegate is swapped in when the chat
/// appears and the ORIGINAL delegate is put back when it disappears, so
/// Home and every other screen keep UIKit's stock behaviour. (The first
/// version left its delegate installed and made every scroll view wait on
/// the pop gesture, which froze touches after going back.)
struct SwipeBackEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController {
        private let popDelegate = PopGestureDelegate()
        private weak var originalDelegate: (any UIGestureRecognizerDelegate)?
        private weak var installedOn: UIGestureRecognizer?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard let nav = navigationController,
                  let gesture = nav.interactivePopGestureRecognizer,
                  gesture.delegate !== popDelegate
            else { return }
            originalDelegate = gesture.delegate
            popDelegate.navigationController = nav
            gesture.delegate = popDelegate
            installedOn = gesture
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            restore()
        }

        private func restore() {
            guard let gesture = installedOn, gesture.delegate === popDelegate else { return }
            gesture.delegate = originalDelegate
            installedOn = nil
        }
    }

    final class PopGestureDelegate: NSObject, UIGestureRecognizerDelegate {
        weak var navigationController: UINavigationController?

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let nav = navigationController else { return false }
            return nav.viewControllers.count > 1 && nav.transitionCoordinator == nil
        }
    }
}
#endif
