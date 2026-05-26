import AuthenticationServices
import Core
import Foundation
import TwitchKit
import os

private let logger = AppLogger.make("Accounts.OAuthFlow")

/// Runs the Twitch authorization-code OAuth flow inside an `ASWebAuthenticationSession`.
///
/// Usage:
/// ```
/// let token = try await OAuthFlow.run(
///     authURL: client.auth.authorizationCodeURL(scopes: [.userReadChat, .userWriteChat, .userReadFollows, .userReadEmail]),
///     callbackScheme: "https",
///     callbackHost: "localhost",
///     presentationContext: anchor
/// )
/// ```
///
/// The caller is responsible for then calling `client.auth.authenticate(withAuthorizationCode:)`
/// with the `code` value returned from the URL.
public enum OAuthFlow {

    public struct Result: Sendable {
        public let code: String
        public let state: String?
    }

    /// Presents the Twitch authorization page and waits for the redirect.
    ///
    /// - Parameters:
    ///   - authURL: URL produced by `TwitchAuth.authorizationCodeURL(scopes:state:)`.
    ///   - callbackScheme: Scheme portion of the redirect URI (e.g. `"https"`).
    ///   - callbackHost: Host portion (e.g. `"localhost"`).
    ///   - presentationAnchor: The `ASPresentationAnchor` (typically a window) the session presents from.
    /// - Returns: Authorization code + optional state.
    @MainActor
    public static func run(
        authURL: URL,
        callbackScheme: String,
        callbackHost: String,
        presentationAnchor: ASPresentationAnchor
    ) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            // Keep a strong reference to the context provider for the session's lifetime.
            // `presentationContextProvider` is a weak property, so we store it here.
            let contextProvider = PresentationContextProvider(anchor: presentationAnchor)
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: callbackScheme
            ) { callbackURL, error in
                _ = contextProvider // retain through callback
                if let error {
                    logger.error("OAuth session failed: \(error.localizedDescription)")
                    continuation.resume(throwing: AppError(message: "Sign in cancelled or failed", underlying: error))
                    return
                }
                guard let callbackURL else {
                    continuation.resume(throwing: AppError(message: "Sign in returned no URL"))
                    return
                }
                guard
                    let comps = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                    comps.host == callbackHost
                else {
                    continuation.resume(throwing: AppError(message: "Redirect host did not match expected '\(callbackHost)'"))
                    return
                }
                let code = comps.queryItems?.first(where: { $0.name == "code" })?.value
                let state = comps.queryItems?.first(where: { $0.name == "state" })?.value
                guard let code else {
                    continuation.resume(throwing: AppError(message: "Twitch redirect missing authorization code"))
                    return
                }
                continuation.resume(returning: Result(code: code, state: state))
            }
            session.presentationContextProvider = contextProvider
            session.prefersEphemeralWebBrowserSession = false
            if !session.start() {
                continuation.resume(throwing: AppError(message: "Failed to start ASWebAuthenticationSession"))
            }
        }
    }

    /// Bridges `ASPresentationAnchor` from a Swift Concurrency caller into the
    /// `ASWebAuthenticationSessionPresentationContextProviding` delegate dance.
    @MainActor
    private final class PresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
        let anchor: ASPresentationAnchor
        init(anchor: ASPresentationAnchor) { self.anchor = anchor }
        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { anchor }
    }
}
