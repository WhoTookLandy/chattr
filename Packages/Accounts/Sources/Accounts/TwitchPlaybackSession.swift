import Foundation
import TwitchKit
import Core
import os

private let logger = AppLogger.make("Accounts.TwitchPlaybackSession")

/// A Twitch sign-in used only to start video, so the viewer's
/// subscriptions and Turbo skip ads in the native player.
///
/// ## Why a second sign-in
///
/// chattr's accounts hold tokens issued to chattr's own client ID. Twitch's
/// playback-token endpoint (GQL, used by `TwitchHLS` in Features) only
/// accepts tokens issued to Twitch's own clients, and asks for the client
/// ID the token belongs to. So this session is a device-code sign-in under
/// Twitch's TV app client ID: the viewer approves at twitch.tv/activate in
/// a real browser (passkeys, password managers and other devices all work)
/// and the token that comes back is one GQL takes.
///
/// It isn't an official third-party integration, like the endpoint it
/// feeds: Twitch can stop honouring it, in which case playback falls back
/// to logged out (with ads) rather than failing.
///
/// ## Storage
///
/// One session per device, independent of chattr's accounts (it needn't be
/// the same Twitch user). Kept in the Keychain under a key the orphaned
/// credential sweep doesn't claim (`OrphanedCredentials`).
public enum TwitchPlaybackSession {
    /// Twitch's TV app client, which supports the device-code grant and
    /// whose tokens the playback endpoint accepts.
    public static let clientId = "ue6666qo983tsx6so1t0vnawi233wa"
    /// Ad-free entitlements come from who the token is, not its scopes;
    /// the device flow just wants at least one.
    static let scopes = ["user:read:subscriptions"]
    static let keychainKey = "chattr.playback.session"

    static var keychain: any RefreshTokenKeychain { OAuthRefreshTokenCache.keychain }

    /// A grant for the twitch.tv/activate approval.
    public static func deviceCodeGrant() -> DeviceCodeGrant {
        DeviceCodeGrant(clientId: clientId, rawScopes: scopes)
    }

    /// The stored session, if any. A blocking Keychain read.
    public static func current() -> TwitchPlaybackCredential? {
        guard let data = try? keychain.load(key: keychainKey) else { return nil }
        return try? JSONDecoder().decode(TwitchPlaybackCredential.self, from: data)
    }

    /// Stores an approved device-code token, with its login for Settings.
    @discardableResult
    public static func signIn(with token: OAuthToken, session: URLSession = .shared) async throws -> TwitchPlaybackCredential {
        // Only for display: a failed lookup still signs in.
        let login = try? await validatedLogin(token.accessToken, session: session)
        let credential = TwitchPlaybackCredential(
            accessToken: token.accessToken,
            refreshToken: token.refreshToken,
            login: login,
            clientId: clientId
        )
        try store(credential)
        logger.notice("Playback session signed in")
        return credential
    }

    /// Forgets the session on this device. Doesn't revoke it on Twitch
    /// (Settings → Connections on twitch.tv does that).
    public static func signOut() {
        keychain.delete(key: keychainKey)
        logger.notice("Playback session signed out")
    }

    /// Twitch rejected `rejectedToken`: renew it with the refresh token.
    /// Returns the renewed session, the one another caller already renewed,
    /// or nil when there's nothing usable (the session is then dropped if
    /// Twitch refused the refresh itself). Concurrent callers share one
    /// refresh, since a refresh token only works once.
    public static func refresh(rejected rejectedToken: String, session: URLSession = .shared) async -> TwitchPlaybackCredential? {
        await refresher.refresh(rejected: rejectedToken, session: session)
    }

    private static let refresher = Refresher()

    private actor Refresher {
        private var inFlight: Task<TwitchPlaybackCredential?, Never>?

        func refresh(rejected: String, session: URLSession) async -> TwitchPlaybackCredential? {
            if let inFlight { return await inFlight.value }
            let task = Task { await TwitchPlaybackSession.performRefresh(rejected: rejected, session: session) }
            inFlight = task
            let result = await task.value
            inFlight = nil
            return result
        }
    }

    private static func performRefresh(rejected: String, session: URLSession) async -> TwitchPlaybackCredential? {
        guard let stored = current() else { return nil }
        // Already renewed since the caller read it.
        if stored.accessToken != rejected { return stored }
        guard let refreshToken = stored.refreshToken, !refreshToken.isEmpty else {
            signOut()
            return nil
        }
        var request = URLRequest(url: Endpoints.TwitchID.token)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = DeviceCodeGrant.formEncoded([
            "client_id": stored.clientId,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ])
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                if (400..<500).contains(status) {
                    // Revoked, or the refresh token is spent: only signing
                    // in again helps.
                    logger.error("Playback session refresh refused (HTTP \(status)); signing out")
                    signOut()
                }
                return nil
            }
            let body = try JSONDecoder().decode(RefreshResponse.self, from: data)
            let renewed = TwitchPlaybackCredential(
                accessToken: body.access_token,
                refreshToken: body.refresh_token ?? refreshToken,
                login: stored.login,
                clientId: stored.clientId
            )
            try store(renewed)
            logger.info("Playback session refreshed")
            return renewed
        } catch {
            logger.error("Playback session refresh failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func store(_ credential: TwitchPlaybackCredential) throws {
        try keychain.save(key: keychainKey, data: JSONEncoder().encode(credential))
    }

    private static func validatedLogin(_ accessToken: String, session: URLSession) async throws -> String? {
        var request = URLRequest(url: Endpoints.TwitchID.validate)
        request.setValue("OAuth \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try JSONDecoder().decode(ValidateResponse.self, from: data).login
    }

    private struct RefreshResponse: Decodable {
        let access_token: String
        let refresh_token: String?
    }

    private struct ValidateResponse: Decodable {
        let login: String?
    }
}

/// A signed-in `TwitchPlaybackSession`.
public struct TwitchPlaybackCredential: Codable, Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String?
    /// For Settings, so the viewer can tell which Twitch user it is.
    public let login: String?
    /// The client the token was issued to; sent alongside it.
    public let clientId: String

    public init(accessToken: String, refreshToken: String?, login: String?, clientId: String) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.login = login
        self.clientId = clientId
    }
}
