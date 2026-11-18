import Foundation
import TwitchKit
import Core
import os

private let logger = AppLogger.make("Accounts.BridgeTokenRefresh")

/// The HTTP half of a token refresh: POSTs a refresh_token to the chattr-auth
/// bridge (which holds the client_secret, so it never ships in the app) and
/// parses Twitch's response into an `OAuthToken`.
///
/// Deliberately side-effect free — it doesn't touch the Keychain, TwitchKit's
/// token store, or account state. `AccountStore` owns those decisions (where
/// the refresh_token comes from, persisting the result, forcing a sign-out
/// on rejection); this type only speaks the wire protocol, so it can be
/// tested against a stubbed `URLSession`.
struct BridgeTokenRefresh: Sendable {

    /// Twitch rejected the refresh_token itself (revoked or expired), and
    /// the response body says so. Terminal — this credential can never work
    /// again, so the caller signs the account out.
    struct Rejected: Error, Equatable {
        let status: Int
    }

    /// Whether a non-200 response says "this refresh_token is dead".
    ///
    /// The status alone never decides it. The bridge passes Twitch's
    /// response through, and a 400 / 401 / 403 is also what a rotated or
    /// misconfigured client secret, a bad deploy or a platform error page
    /// looks like — signing every user out over one of those can't be
    /// undone. So the body has to name the refresh token: Twitch's
    /// `{"status":400,"message":"Invalid refresh token"}`, or an OAuth-style
    /// `"error":"invalid_grant"`. Anything else, including a body that isn't
    /// JSON, is transient. The same fields are read one level down too, in
    /// case the bridge wraps Twitch's error (`{"error": {"message": …}}`).
    static func isRefreshTokenRejection(status: Int, body: Data) -> Bool {
        guard (400..<500).contains(status),
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return false }
        let keys = ["message", "error", "error_description"]
        var fields: [String] = []
        for key in keys {
            if let text = object[key] as? String {
                fields.append(text.lowercased())
            } else if let nested = object[key] as? [String: Any] {
                fields.append(contentsOf: keys.compactMap { (nested[$0] as? String)?.lowercased() })
            }
        }
        return fields.contains { $0.contains("invalid refresh token") || $0 == "invalid_grant" }
    }

    let endpoint: URL
    let session: URLSession

    init(endpoint: URL = Endpoints.ChattrAuth.refresh, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    /// Exchanges `refreshToken` for fresh tokens.
    ///
    /// - Throws: `Rejected` when the response says the refresh token is
    ///   invalid (see `isRefreshTokenRejection`);
    ///   `AppError.bridgeRefreshFailed(status:)` on any other non-200 (5xx,
    ///   408, 429, a 401 / 403 about the client or its secret, an
    ///   unreadable 400, … = bridge / Twitch having a bad day — transient,
    ///   the credentials are probably still good); transport and decoding
    ///   errors as-is.
    /// - Returns: the new token. When Twitch's response omits a
    ///   refresh_token (rotation is conditional on Twitch's own policy), the
    ///   one we *used* is carried forward — persisting `nil` would leave the
    ///   next refresh empty-handed.
    func refresh(using refreshToken: String, login: String) async throws -> OAuthToken {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(RequestBody(refresh_token: refreshToken))

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppError(message: "Bridge refresh: no HTTP response")
        }

        if http.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? "(no body)"
            // body is server-side debug text (no secrets) — public is fine.
            logger.error("Bridge refresh failed for @\(login, privacy: .public) (HTTP \(http.statusCode)): \(body, privacy: .public)")
            if Self.isRefreshTokenRejection(status: http.statusCode, body: data) {
                throw Rejected(status: http.statusCode)
            }
            throw AppError.bridgeRefreshFailed(status: http.statusCode)
        }

        // Twitch's response is snake_case. Use `.convertFromSnakeCase` so the
        // struct stays camelCase — matches `JSONDecoder.twitch()` inside
        // TwitchKit (which is internal to that library, hence the explicit
        // config here).
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let parsed = try decoder.decode(ResponseBody.self, from: data)
        logger.info("Bridge issued tokens for @\(login, privacy: .public) (expires_in=\(parsed.expiresIn ?? -1))")
        return OAuthToken(
            accessToken: parsed.accessToken,
            refreshToken: parsed.refreshToken ?? refreshToken,
            expiresIn: parsed.expiresIn,
            scope: parsed.scope,
            tokenType: parsed.tokenType
        )
    }
}

// MARK: - Wire format

private struct RequestBody: Encodable {
    let refresh_token: String
}

private struct ResponseBody: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int?
    let scope: [String]?
    let tokenType: String?
}
