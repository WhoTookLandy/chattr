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
    /// - Throws: `CancellationError` on user/task cancellation, or `AppError` on
    ///   server errors or malformed callback URLs.
    @MainActor
    public static func run(
        authURL: URL,
        callbackScheme: String,
        presentationAnchor: ASPresentationAnchor
    ) async throws -> OAuthToken {
        try Task.checkCancellation()
        let holder = SessionHolder()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Keep strong references to both the session and its context
                // provider on `@MainActor` until completion (Apple requires
                // callers to strongly retain `ASWebAuthenticationSession`, and
                // `presentationContextProvider` is weak).
                let contextProvider = PresentationContextProvider(anchor: presentationAnchor)
                let session = ASWebAuthenticationSession(
                    url: authURL,
                    callbackURLScheme: callbackScheme
                ) { callbackURL, error in
                    // Hop back to `@MainActor` to release `session` /
                    // `contextProvider` (which holds `UIWindow`) on the main
                    // thread and guarantee the continuation resumes at most once.
                    Task { @MainActor in
                        guard holder.claimResume() else { return }
                        holder.clear()

                        if let error {
                            if let authError = error as? ASWebAuthenticationSessionError,
                               authError.code == .canceledLogin {
                                logger.info("OAuth session cancelled by user")
                                continuation.resume(throwing: CancellationError())
                                return
                            }
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

                        do {
                            continuation.resume(returning: try parseCallbackURL(callbackURL))
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
                session.presentationContextProvider = contextProvider
                session.prefersEphemeralWebBrowserSession = false
                holder.store(session: session, contextProvider: contextProvider)
                if Task.isCancelled {
                    if holder.claimResume() {
                        holder.clear()
                        continuation.resume(throwing: CancellationError())
                    }
                    return
                }
                if !session.start() {
                    if holder.claimResume() {
                        holder.clear()
                        continuation.resume(throwing: AppError(message: "Failed to start ASWebAuthenticationSession"))
                    }
                }
            }
        } onCancel: {
            holder.cancelOnMainActor()
        }
    }

    /// Parses the bridge's `chattr://oauth-complete?...` callback URL into an
    /// `OAuthToken`, or throws an `AppError` describing why it couldn't.
    ///
    /// Extracted from `run(...)`'s session handler so the branch tree —
    /// unparseable URL, bridged error, missing/empty access token, success
    /// with and without the optional fields — is unit-testable without
    /// standing up an `ASWebAuthenticationSession`.
    ///
    /// Either shape arrives:
    ///   - Success: `access_token` (+ optional `refresh_token`, `expires_in`,
    ///     `scope`, `token_type`)
    ///   - Error:   `error` (+ optional `error_description`, bridged from Twitch)
    static func parseCallbackURL(_ callbackURL: URL) throws -> OAuthToken {
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw AppError(message: "Callback URL could not be parsed")
        }
        let items = components.queryItems ?? []

        // Error-path: bridge propagated Twitch's error (user cancel, invalid scope, etc).
        // `URLComponents.queryItems` already percent-decodes values; don't
        // double-decode with `.removingPercentEncoding`.
        if let err = items.first(where: { $0.name == "error" })?.value {
            let desc = items.first(where: { $0.name == "error_description" })?.value
            throw AppError(message: desc ?? err)
        }

        // Success-path: tokens in URL query.
        guard let accessToken = items.first(where: { $0.name == "access_token" })?.value,
              !accessToken.isEmpty
        else {
            throw AppError(message: "Callback URL missing access_token")
        }
        let refreshToken = items.first(where: { $0.name == "refresh_token" })?.value
        let expiresIn = items.first(where: { $0.name == "expires_in" })?.value.flatMap(Int.init)
        let tokenType = items.first(where: { $0.name == "token_type" })?.value
        let scopeString = items.first(where: { $0.name == "scope" })?.value
        let scope: [String]? = scopeString?
            .split(separator: " ")
            .map(String.init)
            .nilIfEmpty

        return OAuthToken(
            accessToken: accessToken,
            refreshToken: refreshToken?.nilIfEmpty,
            expiresIn: expiresIn,
            scope: scope,
            tokenType: tokenType?.nilIfEmpty
        )
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

    /// Holds the active `ASWebAuthenticationSession` and its context provider
    /// on `@MainActor` so both stay retained until completion and can be
    /// cancelled safely from `withTaskCancellationHandler.onCancel`.
    @MainActor
    private final class SessionHolder {
        private var session: ASWebAuthenticationSession?
        private var contextProvider: PresentationContextProvider?
        private var hasResumed = false

        func store(session: ASWebAuthenticationSession, contextProvider: PresentationContextProvider) {
            self.session = session
            self.contextProvider = contextProvider
        }

        func claimResume() -> Bool {
            guard !hasResumed else { return false }
            hasResumed = true
            return true
        }

        func clear() {
            session = nil
            contextProvider = nil
        }

        nonisolated func cancelOnMainActor() {
            Task { @MainActor in
                self.session?.cancel()
            }
        }
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
