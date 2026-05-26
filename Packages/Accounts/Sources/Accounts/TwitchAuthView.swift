#if canImport(UIKit)
import SwiftUI
import WebKit
import Core
import os

private let logger = AppLogger.make("Accounts.TwitchAuthView")

// MARK: - Sheet container

/// Sheet presented to host the embedded Twitch login WebView.
///
/// Why a custom WebKit sheet instead of `ASWebAuthenticationSession`:
/// Twitch's dev portal requires HTTPS redirect URIs (custom URL schemes are rejected
/// as of 2025+), and `ASWebAuthenticationSession`'s `callbackURLScheme` only intercepts
/// *custom* schemes — not arbitrary HTTPS hosts (Universal Links require an AASA file
/// hosted on a real domain, which `localhost` can't satisfy). So we manually intercept
/// the navigation to `https://localhost?code=...` inside a `WKWebView` via
/// `WKNavigationDelegate.decidePolicyFor`, before WebKit tries to actually load the URL.
struct TwitchAuthSheet: View {
    let authURL: URL
    let onCode: (String) -> Void
    let onError: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            TwitchAuthView(
                authURL: authURL,
                onAuthCode: onCode,
                onError: onError
            )
            .ignoresSafeArea(.container, edges: .bottom)
            .navigationTitle("Sign in to Twitch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
    }
}

// MARK: - WKWebView wrapper

/// `WKWebView` wrapped for SwiftUI. Loads the Twitch authorization URL; intercepts the
/// redirect to `https://localhost?code=...` to extract the auth code without ever actually
/// trying to connect to `localhost`.
struct TwitchAuthView: UIViewRepresentable {
    let authURL: URL
    let onAuthCode: (String) -> Void
    let onError: (String) -> Void

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Ephemeral data store — cookies do not persist across launches. Each sign-in
        // starts fresh; users always re-enter credentials. We accept this tradeoff in
        // exchange for not leaving Twitch session cookies in the app's sandbox.
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: authURL))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onAuthCode: onAuthCode, onError: onError)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onAuthCode: (String) -> Void
        let onError: (String) -> Void

        init(onAuthCode: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
            self.onAuthCode = onAuthCode
            self.onError = onError
        }

        /// Intercept navigation to `https://localhost` — extract the auth code (or error)
        /// from the query string, then cancel the navigation so WebKit doesn't try to
        /// actually load a page that no server is serving.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            guard
                let url = navigationAction.request.url,
                url.host() == "localhost"
            else {
                return .allow
            }

            logger.info("Intercepted Twitch redirect: \(url.absoluteString)")

            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            if let code = components?.queryItems?.first(where: { $0.name == "code" })?.value {
                onAuthCode(code)
            } else if let errorDesc = components?.queryItems?.first(where: { $0.name == "error_description" })?.value {
                onError(errorDesc.removingPercentEncoding ?? errorDesc)
            } else if let err = components?.queryItems?.first(where: { $0.name == "error" })?.value {
                onError(err)
            } else {
                onError("Authorization failed: no code or error in redirect")
            }

            return .cancel
        }
    }
}
#endif
