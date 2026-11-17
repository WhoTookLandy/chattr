import Foundation
import TwitchKit
import Core
import os

private let logger = AppLogger.make("Accounts.TwitchKitRefreshInterceptor")

/// chattr's answer to a token refresh that TwitchKit started itself.
enum TwitchKitRefreshAnswer: Sendable, Equatable {
    /// The bridge issued fresh tokens. TwitchKit stores them and retries.
    case refreshed(OAuthToken)
    /// The bridge confirmed the refresh token is dead (it answered 400 /
    /// 401 / 403, e.g. `invalid_grant`), or there is no refresh token
    /// anywhere. chattr has already force-signed the account out, which
    /// deleted the token and retired the client.
    case rejected
    /// The refresh couldn't finish this time (bridge 5xx, network, rate
    /// limit). The credential is probably still good. `current` is the
    /// token the requesting client holds in memory, handed back so TwitchKit
    /// has nothing to fail over; `nil` only if even that is gone.
    case unavailable(current: OAuthToken?)
    /// The requesting client is no longer the account's client: the account
    /// was removed, signed out or re-authorized while the refresh ran. The
    /// result must not be persisted anywhere.
    case discarded
}

/// The `HTTPClient` every chattr-built `TwitchClient` uses. It answers
/// TwitchKit's own token refresh locally so that refresh never reaches
/// Twitch, and passes every other request to `base` unchanged.
///
/// ## Why
///
/// TwitchKit 0.3.4's `HelixClient` handles any Helix 401 by calling
/// `TwitchTokenProvider.refreshIfNeeded()`. That POSTs
/// `grant_type=refresh_token` to `https://id.twitch.tv/oauth2/token` through
/// the client's `HTTPClient`. chattr's Twitch app is a confidential client
/// and the client secret lives only on the chattr-auth bridge, so Twitch
/// always rejects that request. `refreshIfNeeded()` then calls `logout()`,
/// which deletes the account's token from the Keychain. Any 401 (an expired
/// token, a missing scope, a Twitch hiccup) could therefore wipe a signed-in
/// account.
///
/// TwitchKit has no refresh hook and no switch to turn auto-refresh off, but
/// it sends that request through the `HTTPClient` it was built with. This
/// type is that `HTTPClient`. It recognises the refresh request and answers
/// it from `refresh`, which goes through the bridge and `AccountStore`'s
/// single-flight `TokenRefresher`.
///
/// ## What TwitchKit does with each answer
///
/// `refreshIfNeeded()` saves a 200 and retries. On *anything else* (non-200,
/// undecodable body, thrown error) it calls `logout()`, which deletes
/// through the token store, and rethrows. No response avoids that
/// `logout()`, so the client's `LifecycleGuardedTokenStore` is what keeps it
/// harmless: it drops every delete chattr didn't start, and every save from
/// a client that is no longer `.active`.
///
/// - `.refreshed`, client still active → 200 with the new token. TwitchKit
///   stores it and retries the Helix call.
/// - `.unavailable(current:)`, client still active → 200 with the token the
///   client already holds. TwitchKit re-saves that same token; its retry
///   gets the same 401, and the caller sees `HelixError.unauthorized`, which
///   `withTokenRefresh` / `HelixAuthRetry` retry once more through the
///   bridge.
/// - `.rejected` → 400. TwitchKit throws `HelixError.oauth`, which
///   `withTokenRefresh` turns into `AppError.sessionExpired`. Its `logout()`
///   delete is dropped: `forceSignOut` already deleted the token.
/// - `.discarded`, `.unavailable(current: nil)`, or the client stopped
///   being active while the refresh ran → a thrown `URLError`. TwitchKit's
///   `logout()` only clears its in-memory copy (the store drops the
///   delete), and the caller sees `HelixError.networkError`. Nothing is
///   saved, nothing is deleted, and no wrapper starts another refresh.
///
/// Nothing changes on the happy path. Helix requests go straight to `base`,
/// and the check is a host/path comparison.
struct TwitchKitRefreshInterceptor: HTTPClient {
    let base: any HTTPClient
    /// The lifecycle of the client this interceptor belongs to. Checked
    /// after the refresh settles, so a client retired meanwhile never gets
    /// a token to save.
    let lifecycle: TwitchClientLifecycle
    let refresh: @Sendable () async -> TwitchKitRefreshAnswer

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url, Self.isTokenRefresh(request) else {
            return try await base.data(for: request)
        }

        let answer = await refresh()
        switch answer {
        case .rejected:
            logger.notice("Answered TwitchKit's token refresh with a rejection: the refresh token is dead")
            return try Self.rejection(url: url)
        case .unavailable(.none):
            logger.warning("Bridge refresh unavailable and the client holds no token; failing TwitchKit's refresh without signing out")
            throw URLError(.userAuthenticationRequired)
        case .refreshed(let token) where lifecycle.isActive:
            logger.info("Answered TwitchKit's token refresh with bridge-issued tokens")
            return try Self.tokenResponse(token, url: url)
        case .unavailable(.some(let current)) where lifecycle.isActive:
            logger.warning("Bridge refresh unavailable; handing TwitchKit its current token so it keeps the account")
            return try Self.tokenResponse(current, url: url)
        case .refreshed, .unavailable, .discarded:
            logger.notice("Discarded TwitchKit's token refresh: the client is no longer the account's client")
            throw URLError(.cancelled)
        }
    }

    /// Whether `request` is TwitchKit's refresh-token grant. Other token
    /// grants (authorization code, device code) and every other endpoint
    /// pass through.
    static func isTokenRefresh(_ request: URLRequest) -> Bool {
        guard request.httpMethod == "POST",
              let url = request.url,
              url.host() == "id.twitch.tv",
              url.path() == "/oauth2/token",
              let body = request.httpBody,
              let form = String(data: body, encoding: .utf8)
        else { return false }
        return form.split(separator: "&").contains("grant_type=refresh_token")
    }

    /// A 200 carrying `token` in the snake_case shape Twitch's token endpoint
    /// returns, which TwitchKit decodes with `.convertFromSnakeCase`.
    static func tokenResponse(_ token: OAuthToken, url: URL) throws -> (Data, URLResponse) {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return (try encoder.encode(token), try httpResponse(url: url, status: 200))
    }

    /// A 400 in Twitch's OAuth error shape. Only for `.rejected`.
    static func rejection(url: URL) throws -> (Data, URLResponse) {
        let body = Data(#"{"status":400,"message":"Invalid refresh token"}"#.utf8)
        return (body, try httpResponse(url: url, status: 400))
    }

    private static func httpResponse(url: URL, status: Int) throws -> HTTPURLResponse {
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ) else {
            throw URLError(.badServerResponse)
        }
        return response
    }
}
