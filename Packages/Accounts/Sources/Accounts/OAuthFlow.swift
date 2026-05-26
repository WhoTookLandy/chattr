#if canImport(UIKit)
import AuthenticationServices
import Core
import Foundation
import os

private let logger = AppLogger.make("Accounts.OAuthFlow")

/// Runs the Twitch authorization-code OAuth flow inside an `ASWebAuthenticationSession`
/// using iOS 17.4+'s `.https(host:path:)` callback (Universal Link).
///
/// **Why `.https(host:path:)` and not `.customScheme(_:)`:**
/// Twitch's dev portal requires HTTPS redirect URIs. Custom URL schemes (`chattr://...`)
/// are rejected. To bridge "HTTPS at Twitch's end" with "intercept at our end," we own
/// a Vercel-hosted domain (`chattr-auth.vercel.app`) serving an Apple App Site
/// Association file. When Twitch redirects to
/// `https://chattr-auth.vercel.app/oauth/callback?code=...`, iOS recognizes the URL
/// as a Universal Link for chattr (per the AASA), intercepts the navigation, and hands
/// it to ASWebAuthenticationSession's completion handler. The user never sees the
/// "Open in chattr?" prompt — Universal Links are domain-validated and silent.
///
/// The caller is responsible for calling `TwitchOAuthClient.exchangeAuthorizationCode(_:)`
/// with the returned `code`.
public enum OAuthFlow {

    public struct Result: Sendable {
        public let code: String
        public let state: String?
    }

    /// Presents the Twitch authorization page and returns the auth code from the redirect.
    ///
    /// - Parameters:
    ///   - authURL: URL produced by `TwitchOAuthClient.authorizationCodeURL(scopes:)`.
    ///   - callbackHost: Host portion of the Universal Link redirect (e.g., `"chattr-auth.vercel.app"`).
    ///   - callbackPath: Path portion (e.g., `"/oauth/callback"`). Matches AASA's components rule.
    ///   - presentationAnchor: The `ASPresentationAnchor` (typically a window) for the auth sheet.
    /// - Returns: Authorization code + optional state.
    /// - Throws: `AppError` if the session fails, is cancelled, or returns no code.
    @MainActor
    public static func run(
        authURL: URL,
        callbackHost: String,
        callbackPath: String,
        presentationAnchor: ASPresentationAnchor
    ) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            // Keep a strong reference for the session's lifetime — `presentationContextProvider`
            // is a `weak` property on `ASWebAuthenticationSession`, so a freshly-constructed
            // provider would deallocate immediately after assignment without this capture.
            let contextProvider = PresentationContextProvider(anchor: presentationAnchor)
            let session = ASWebAuthenticationSession(
                url: authURL,
                callback: .https(host: callbackHost, path: callbackPath),
                completionHandler: { callbackURL, error in
                    _ = contextProvider // retain through callback
                    if let error {
                        logger.error("OAuth session failed: \(error.localizedDescription)")
                        continuation.resume(
                            throwing: AppError(
                                message: "Sign in cancelled or failed",
                                underlying: error
                            )
                        )
                        return
                    }
                    guard let callbackURL else {
                        continuation.resume(throwing: AppError(message: "Sign in returned no URL"))
                        return
                    }
                    guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
                        continuation.resume(throwing: AppError(message: "Redirect URL could not be parsed"))
                        return
                    }

                    // Twitch returns either ?code=... on success or ?error=...&error_description=... on failure.
                    if let code = components.queryItems?.first(where: { $0.name == "code" })?.value {
                        let state = components.queryItems?.first(where: { $0.name == "state" })?.value
                        continuation.resume(returning: Result(code: code, state: state))
                    } else if let errorDesc = components.queryItems?.first(where: { $0.name == "error_description" })?.value {
                        let decoded = errorDesc.removingPercentEncoding ?? errorDesc
                        continuation.resume(throwing: AppError(message: decoded))
                    } else if let err = components.queryItems?.first(where: { $0.name == "error" })?.value {
                        continuation.resume(throwing: AppError(message: "Twitch returned error: \(err)"))
                    } else {
                        continuation.resume(throwing: AppError(message: "Twitch redirect missing authorization code"))
                    }
                }
            )
            session.presentationContextProvider = contextProvider
            session.prefersEphemeralWebBrowserSession = false
            if !session.start() {
                continuation.resume(throwing: AppError(message: "Failed to start ASWebAuthenticationSession"))
            }
        }
    }

    /// Bridges `ASPresentationAnchor` into the
    /// `ASWebAuthenticationSessionPresentationContextProviding` delegate protocol.
    /// `@MainActor` because it's only instantiated and used from `@MainActor run(...)`.
    @MainActor
    private final class PresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
        let anchor: ASPresentationAnchor
        init(anchor: ASPresentationAnchor) { self.anchor = anchor }
        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { anchor }
    }
}
#endif
