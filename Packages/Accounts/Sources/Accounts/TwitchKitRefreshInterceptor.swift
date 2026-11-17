import Foundation
import TwitchKit
import Core
import os

private let logger = AppLogger.make("Accounts.TwitchKitRefreshInterceptor")

/// chattr's answer to a token refresh that TwitchKit started itself.
enum TwitchKitRefreshAnswer: Sendable, Equatable {
    /// The bridge issued fresh tokens. TwitchKit stores them and retries.
    case refreshed(OAuthToken)
    /// The refresh token is dead (the bridge rejected it, or there is none).
    /// chattr has already force-signed the account out, so TwitchKit can
    /// clear its store too.
    case rejected
    /// The refresh couldn't finish this time (bridge 5xx, network, rate
    /// limit). The credential is probably still good, so nothing may be
    /// deleted.
    case unavailable
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
/// single-flight `TokenRefresher`:
///
/// - `.refreshed` → 200 with the new token. TwitchKit stores it and retries
///   the Helix call.
/// - `.unavailable` → 200 with the token already stored, so TwitchKit has
///   nothing to log out over. Its retry gets the same 401, and the caller
///   sees `HelixError.unauthorized`, which `withTokenRefresh` /
///   `HelixAuthRetry` retry once more through the bridge.
/// - `.rejected`, or no stored token to fall back on → 400. TwitchKit logs
///   out, which is now correct: chattr has already marked the account
///   `needsReauth`.
///
/// Nothing changes on the happy path. Helix requests go straight to `base`,
/// and the check is a host/path comparison.
struct TwitchKitRefreshInterceptor: HTTPClient {
    let base: any HTTPClient
    /// The same store the `TwitchClient` was built with. Read only for the
    /// `.unavailable` fallback.
    let tokenStore: any TwitchTokenStore
    let refresh: @Sendable () async -> TwitchKitRefreshAnswer

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url, Self.isTokenRefresh(request) else {
            return try await base.data(for: request)
        }

        switch await refresh() {
        case .refreshed(let token):
            logger.info("Answered TwitchKit's token refresh with bridge-issued tokens")
            return try Self.tokenResponse(token, url: url)
        case .rejected:
            logger.notice("Answered TwitchKit's token refresh with a rejection: the refresh token is dead")
            return try Self.rejection(url: url)
        case .unavailable:
            if let current = try? await tokenStore.loadToken() {
                logger.warning("Bridge refresh unavailable; handing TwitchKit its current token so it keeps the account")
                return try Self.tokenResponse(current, url: url)
            }
            logger.notice("Bridge refresh unavailable and no stored token; answering TwitchKit with a rejection")
            return try Self.rejection(url: url)
        }
    }

    /// Whether `request` is TwitchKit's refresh-token grant. Other token
    /// grants and every other endpoint pass through.
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

    /// A 400 in Twitch's OAuth error shape.
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
