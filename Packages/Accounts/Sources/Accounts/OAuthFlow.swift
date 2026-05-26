#if canImport(UIKit)
import AuthenticationServices
import Core
import Foundation
import TwitchKit
import os

private let logger = AppLogger.make("Accounts.OAuthFlow")

/// Runs the Twitch authorization-code OAuth flow inside an `ASWebAuthenticationSession`.
///
/// Architecture: the Vercel bridge at `chattr-auth.vercel.app/oauth/callback` exchanges
/// Twitch's authorization code for tokens using the (server-side) client_secret, then
/// 302-redirects to `chattr://oauth-complete?access_token=...&refresh_token=...`. The
/// session's `callbackURLScheme: "chattr"` privileged-intercepts that custom-scheme
/// redirect *inside* the auth sheet — iOS never shows the "Open in chattr?" prompt
/// because the system URL handler never sees the chattr:// URL.
///
/// This approach avoids three things that bit us during slice-1 development:
///   1. Shipping `client_secret` in the iOS binary (exchange happens server-side)
///   2. Universal Links + AASA + Apple Team ID exposure (no Universal Link needed)
///   3. The iOS 17.4+ `.https(host:path:)` callback API's `webcredentials:` requirement
///
/// See chattr-auth's README for the full sequence.
public enum OAuthFlow {

    /// Presents Twitch's authorization page and waits for the bridge's chattr:// callback
    /// carrying the already-exchanged OAuth tokens.
    ///
    /// - Parameters:
    ///   - authURL: Twitch authorization URL whose `redirect_uri` is the Vercel bridge.
    ///   - callbackScheme: Custom URL scheme the bridge redirects to (e.g., `"chattr"`).
    ///     Registered in Info.plist; the session intercepts navigation matching this scheme.
    ///   - presentationAnchor: The `ASPresentationAnchor` (typically a window) for the sheet.
    /// - Returns: A fully-populated `OAuthToken` ready to hand off to `AccountStore`.
    /// - Throws: `AppError` on cancellation, server errors, or malformed callback URLs.
    @MainActor
    public static func run(
        authURL: URL,
        callbackScheme: String,
        presentationAnchor: ASPresentationAnchor
    ) async throws -> OAuthToken {
        try await withCheckedThrowingContinuation { continuation in
            // Keep a strong reference for the session's lifetime —
            // `presentationContextProvider` is a `weak` property on
            // ASWebAuthenticationSession.
            let contextProvider = PresentationContextProvider(anchor: presentationAnchor)
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: callbackScheme
            ) { callbackURL, error in
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

                // Parse the chattr://oauth-complete?... URL. Either:
                //   - Success: access_token + refresh_token + expires_in + scope + token_type
                //   - Error:   error + error_description (bridged from Twitch)
                guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
                    continuation.resume(throwing: AppError(message: "Callback URL could not be parsed"))
                    return
                }
                let items = components.queryItems ?? []

                // Error-path: bridge propagated Twitch's error (user cancel, invalid scope, etc).
                if let err = items.first(where: { $0.name == "error" })?.value {
                    let desc = items.first(where: { $0.name == "error_description" })?.value
                    let decoded = desc?.removingPercentEncoding ?? desc ?? err
                    continuation.resume(throwing: AppError(message: decoded))
                    return
                }

                // Success-path: tokens in URL query.
                guard let accessToken = items.first(where: { $0.name == "access_token" })?.value,
                      !accessToken.isEmpty
                else {
                    continuation.resume(
                        throwing: AppError(message: "Callback URL missing access_token")
                    )
                    return
                }
                let refreshToken = items.first(where: { $0.name == "refresh_token" })?.value
                let expiresIn = items.first(where: { $0.name == "expires_in" })?.value.flatMap(Int.init)
                let tokenType = items.first(where: { $0.name == "token_type" })?.value
                let scopeString = items.first(where: { $0.name == "scope" })?.value
                let scope: [String]? = scopeString?
                    .split(separator: " ")
                    .map(String.init)
                    .nilIfEmpty

                let token = OAuthToken(
                    accessToken: accessToken,
                    refreshToken: refreshToken?.nilIfEmpty,
                    expiresIn: expiresIn,
                    scope: scope,
                    tokenType: tokenType?.nilIfEmpty
                )
                continuation.resume(returning: token)
            }
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

// MARK: - Helpers

private extension String {
    /// Returns `nil` if the string is empty; otherwise returns self. Useful for
    /// converting "" (a present-but-empty URL query param) into nil for `OAuthToken`
    /// fields that are optional and should be absent rather than empty-string.
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension Array {
    var nilIfEmpty: Self? { isEmpty ? nil : self }
}
#endif
