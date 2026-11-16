import Foundation
import TwitchKit
import Core
import os

private let logger = AppLogger.make("Accounts.AccountStore")

// MARK: - Token Refresh

extension AccountStore {

    /// Refreshes the OAuth tokens for an account via the Vercel bridge.
    ///
    /// Reads the current refresh_token from this account's TwitchAuth (which reads
    /// from Keychain via TokenStore), POSTs it to the bridge, parses the new tokens,
    /// and saves them. Throws `AppError` on any failure — caller decides whether to
    /// surface as "needs re-auth" UI vs a transient error banner.
    ///
    /// Side effects: persists the new OAuthToken via `TwitchAuth.setToken(_:)`, which
    /// also updates the in-memory cachedAccessToken / cachedRefreshToken.
    ///
    /// Takes plain strings so `@Sendable` closures (e.g. in
    /// `ChannelSessionRegistry`) can capture stable IDs instead of the
    /// non-Sendable `Account` model object.
    ///
    /// **Single-flight per userId** (via `TokenRefresher`): callers that
    /// arrive while a refresh for the same account is already running await
    /// that one and get the same token or error, instead of each POSTing the
    /// same refresh_token to the bridge (where all but the first could get a
    /// 4xx and force a sign-out).
    @discardableResult
    public func refreshTokens(userId: String, login: String) async throws -> OAuthToken {
        try await tokenRefresher.refresh(userId: userId) {
            try await self.performRefresh(userId: userId, login: login)
        }
    }

    /// The actual refresh. Only ever called through `tokenRefresher` so at
    /// most one runs per userId at a time.
    private func performRefresh(userId: String, login: String) async throws -> OAuthToken {
        // Same cached/constructed client every other path uses — including the
        // `isLive` closure, so a client first built here still reconnects
        // EventSub aggressively while a channel is open.
        let twitchClient = client(forUserId: userId)
        let refreshToken = try await currentRefreshToken(userId: userId, login: login, client: twitchClient)

        let newToken: OAuthToken
        do {
            newToken = try await bridgeRefresh.refresh(using: refreshToken, login: login)
        } catch is BridgeTokenRefresh.Rejected {
            // 4xx → Twitch rejected the refresh_token (revoked, expired, or
            // associated with a different client_id). Terminal — the refresh
            // credential we have can never work again, so mark the account
            // expired and show the session-expired banner on the next render.
            // (5xx / transport errors propagate untouched: transient, and the
            // user's credentials are probably still good.)
            await forceSignOut(userId: userId, reason: .sessionExpired(login: login))
            throw AppError.sessionExpired(login: login)
        }

        try await twitchClient.auth.setToken(newToken)
        // Mirror to chattr-side cache so the next failure has somewhere
        // to recover from even if TwitchKit clears its store again.
        OAuthRefreshTokenCache.save(refreshToken: newToken.refreshToken, for: userId)
        logger.info("Refreshed tokens for @\(login, privacy: .public)")
        return newToken
    }

    /// The refresh_token to POST. Two sources, in priority order:
    ///   1. TwitchKit's own store via `tokenProvider.token()` — the happy path.
    ///   2. Our chattr-side `OAuthRefreshTokenCache` — fallback for the case
    ///      where TwitchKit's auto-refresh failed and wiped the store as
    ///      defensive cleanup. Without this fallback, the first refresh
    ///      failure (e.g. "missing client secret") makes every subsequent
    ///      recovery attempt throw `.notAuthenticated` and the user is stuck
    ///      re-signing-in.
    ///
    /// When neither has one, the account can't recover: it is force-signed-
    /// out (so RootView re-renders SignInView with a "session expired"
    /// banner instead of leaving the user on a broken signed-in screen) and
    /// `AppError.sessionExpired` is thrown.
    private func currentRefreshToken(userId: String, login: String, client: TwitchClient) async throws -> String {
        // `tokenProvider.token()` throws `HelixError.notAuthenticated` when
        // its store is empty. We catch that specific case rather than
        // letting it bubble — the cache is exactly the recovery path it
        // wants.
        do {
            let currentToken = try await client.auth.tokenProvider.token()
            if let token = currentToken.refreshToken, !token.isEmpty {
                return token
            }
            if let cached = OAuthRefreshTokenCache.load(for: userId) {
                // .warning: recoverable fallback path — we ARE working around
                // a problem (TwitchKit lost its refresh_token), but the
                // chattr cache saved us.
                logger.warning("TwitchKit token has no refresh_token; using chattr-side cache for @\(login, privacy: .public)")
                return cached
            }
            // Terminal: no refresh_token anywhere.
            await forceSignOut(userId: userId, reason: .sessionExpired(login: login))
            throw AppError.sessionExpired(login: login)
        } catch HelixError.notAuthenticated {
            // TwitchKit's store is empty (most likely because its own
            // refresh attempt failed and called logout()). Fall back to
            // our independent cache.
            guard let cached = OAuthRefreshTokenCache.load(for: userId) else {
                logger.error("TwitchKit store empty AND chattr cache empty for @\(login) — must re-sign-in")
                // Terminal: drive the auth-state transition (see above).
                await forceSignOut(userId: userId, reason: .sessionExpired(login: login))
                throw AppError.sessionExpired(login: login)
            }
            // .warning: TwitchKit lost its store; we're saved by chattr's
            // independent refresh cache. Recovery path — important to see.
            logger.warning("TwitchKit store empty for @\(login, privacy: .public); recovering via chattr-side refresh cache")
            return cached
        }
    }

    /// Wraps an async throwing operation with one retry-after-refresh-on-auth-failure.
    ///
    /// Three error paths trigger a refresh-and-retry:
    ///
    ///   - `HelixError.unauthorized` — Helix call returned 401 directly. The
    ///     access token has expired or been revoked. Refresh + retry once.
    ///
    ///   - `HelixError.oauth(_)` — TwitchKit's *internal* auth-refresh layer
    ///     intercepted the 401 and tried to call `POST /oauth2/token` itself,
    ///     but failed because our `TwitchOAuthClient` is constructed without a
    ///     `client_secret` (the secret lives only on the Vercel bridge to keep
    ///     it out of the iOS binary). Twitch returns "missing client secret"
    ///     and TwitchKit wraps that as the `.oauth` case. Same intent as
    ///     `.unauthorized` — route through our Vercel-bridged refresh and retry.
    ///
    ///   - `HelixError.notAuthenticated` — TwitchKit's `TwitchTokenProvider`
    ///     reports an empty store. This happens *after* a prior auto-refresh
    ///     failure, because `TwitchTokenProvider.refreshIfNeeded()` calls
    ///     `logout()` in its catch (wiping its own Keychain entry). The
    ///     access token IS gone, but our chattr-side `OAuthRefreshTokenCache`
    ///     still holds the refresh_token — `refreshTokens(userId:login:)` will read
    ///     it from there and recover transparently.
    ///
    /// In all three cases, `refreshTokens(userId:login:)` POSTs to the bridge with the
    /// refresh_token and persists the new OAuthToken. Subsequent operation()
    /// retry uses the fresh access token.
    ///
    /// Any throw from the refresh OR the second operation attempt bubbles to
    /// the caller (no infinite loops — only one retry).
    public func withTokenRefresh<T: Sendable>(
        for account: Account,
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        try await withTokenRefresh(userId: account.userId, login: account.login, operation)
    }

    /// `withTokenRefresh(for:)` for call sites that hold only a stable userId
    /// (e.g. `BlockStore`). The login — used for logs and the session-expired
    /// banner — is looked up from the Account row, falling back to the userId
    /// if the row is gone.
    public func withTokenRefresh<T: Sendable>(
        forUserId userId: String,
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        try await withTokenRefresh(userId: userId, login: repository.login(forUserId: userId) ?? userId, operation)
    }

    private func withTokenRefresh<T: Sendable>(
        userId: String,
        login: String,
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        do {
            return try await operation()
        } catch HelixError.unauthorized {
            logger.info("Helix call returned unauthorized for @\(login); refreshing via bridge and retrying")
            try await refreshTokens(userId: userId, login: login)
            return try await operation()
        } catch HelixError.oauth(let oauthError) {
            // TwitchKit's internal auto-refresh fired and failed — likely
            // "missing client secret" because we don't ship one. Bridge it.
            logger.info("TwitchKit auto-refresh failed for @\(login) (\(oauthError.message)); refreshing via bridge and retrying")
            try await refreshTokens(userId: userId, login: login)
            return try await operation()
        } catch HelixError.notAuthenticated {
            // TwitchKit's store is empty — most likely because a prior
            // refresh attempt failed and called logout() on its store.
            // Our chattr-side cache should still hold the refresh_token;
            // refreshTokens(userId:login:) will read from there.
            logger.info("TwitchKit store empty for @\(login); attempting recovery via chattr-side cache")
            try await refreshTokens(userId: userId, login: login)
            return try await operation()
        }
    }
}
