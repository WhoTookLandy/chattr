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

    /// Answers a refresh that TwitchKit's `HelixClient` started after a 401
    /// on the client with `lifecycle` (relayed by
    /// `TwitchKitRefreshInterceptor`). It runs the same single-flight bridge
    /// refresh as every other caller, then sorts the outcome into what
    /// TwitchKit may do with the account's token:
    ///
    /// - the asking client is no longer the account's client (removed,
    ///   signed out, re-authorized), before or after the refresh →
    ///   `.discarded`: nothing may be persisted.
    /// - success → `.refreshed`: TwitchKit stores the token and retries.
    /// - `AppError.sessionExpired` → `.rejected`: the refresh token is dead
    ///   and `performRefresh` has already called `forceSignOut`, so the
    ///   account is `needsReauth` and its token is deleted.
    /// - anything else (bridge 5xx / 408 / 429, network) → `.unavailable`
    ///   with the token the asking client holds in memory: transient, so
    ///   that credential must survive.
    func answerTwitchKitRefresh(userId: String, lifecycle: TwitchClientLifecycle) async -> TwitchKitRefreshAnswer {
        let login = repository.login(forUserId: userId) ?? userId
        guard clients.activeClient(forUserId: userId, lifecycle: lifecycle) != nil else {
            logger.notice("Ignored TwitchKit's refresh for @\(login, privacy: .public): the client is no longer the account's client")
            return .discarded
        }
        do {
            let token = try await refreshTokens(userId: userId, login: login)
            guard clients.activeClient(forUserId: userId, lifecycle: lifecycle) != nil else {
                return .discarded
            }
            return .refreshed(token)
        } catch {
            if let appError = error as? AppError, case .sessionExpired = appError.kind {
                return .rejected
            }
            guard let client = clients.activeClient(forUserId: userId, lifecycle: lifecycle) else {
                return .discarded
            }
            logger.warning("TwitchKit-initiated refresh failed transiently for @\(login, privacy: .public): \(error.localizedDescription, privacy: .public)")
            // The provider's in-memory token: `refreshIfNeeded()` read it
            // just before asking, so this doesn't touch the Keychain. It can
            // only be missing if something logged the provider out meanwhile.
            let current: OAuthToken?
            do {
                current = try await client.auth.tokenProvider.token()
            } catch {
                logger.warning("No in-memory token to hand back for @\(login, privacy: .public): \(error.localizedDescription, privacy: .public)")
                current = nil
            }
            guard clients.activeClient(forUserId: userId, lifecycle: lifecycle) != nil else {
                return .discarded
            }
            return .unavailable(current: current)
        }
    }

    /// The actual refresh. Only ever called through `tokenRefresher` so at
    /// most one runs per userId at a time.
    ///
    /// The account can be removed, signed out or re-authorized while the
    /// bridge call is in flight. That retires the client this refresh
    /// started with, and from then on the result is stale: it is discarded
    /// (no `setToken`, no refresh-token cache write, no `forceSignOut`) and
    /// the refresh throws `CancellationError`.
    private func performRefresh(userId: String, login: String) async throws -> OAuthToken {
        // Same cached/constructed client every other path uses — including the
        // `isLive` closure, so a client first built here still reconnects
        // EventSub aggressively while a channel is open.
        let entry = clients.entry(forUserId: userId)
        let twitchClient = entry.client
        let refreshToken = try await currentRefreshToken(userId: userId, login: login, client: twitchClient)

        let newToken: OAuthToken
        do {
            newToken = try await bridgeRefresh.refresh(using: refreshToken, login: login)
        } catch is BridgeTokenRefresh.Rejected {
            // A rejection of a credential that is no longer the account's
            // says nothing about the current one: don't sign that out.
            try Self.checkStillCurrent(entry, login: login)
            // 4xx → Twitch rejected the refresh_token (revoked, expired, or
            // associated with a different client_id). Terminal — the refresh
            // credential we have can never work again, so mark the account
            // expired and show the session-expired banner on the next render.
            // (5xx / transport errors propagate untouched: transient, and the
            // user's credentials are probably still good.)
            await forceSignOut(userId: userId, reason: .sessionExpired(login: login))
            throw AppError.sessionExpired(login: login)
        }

        try Self.checkStillCurrent(entry, login: login)
        // The guarded token store also drops this save if the client is
        // retired while it's in flight.
        try await twitchClient.auth.setToken(newToken)
        try Self.checkStillCurrent(entry, login: login)
        // Mirror to chattr-side cache so the next failure has somewhere
        // to recover from even if TwitchKit clears its store again. No
        // suspension between the check above and this write.
        OAuthRefreshTokenCache.save(refreshToken: newToken.refreshToken, for: userId, in: refreshTokenKeychain)
        logger.info("Refreshed tokens for @\(login, privacy: .public)")
        return newToken
    }

    /// Throws `CancellationError` once `entry`'s client has stopped being
    /// the account's live client.
    private static func checkStillCurrent(_ entry: TwitchClientCache.Entry, login: String) throws {
        guard entry.lifecycle.isActive else {
            logger.notice("Discarded a bridge refresh for @\(login, privacy: .public): the account was removed, signed out or re-authorized while it ran")
            throw CancellationError()
        }
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
            if let cached = OAuthRefreshTokenCache.load(for: userId, in: refreshTokenKeychain) {
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
            guard let cached = OAuthRefreshTokenCache.load(for: userId, in: refreshTokenKeychain) else {
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
    /// TwitchKit's own 401 refresh already goes through the bridge (see
    /// `TwitchKitRefreshInterceptor`), so this is the second line of defence.
    /// Three error paths trigger a refresh-and-retry:
    ///
    ///   - `HelixError.unauthorized` — the 401 survived TwitchKit's refresh:
    ///     the bridge was briefly unavailable, or the token lacks a scope.
    ///     Refresh + retry once.
    ///
    ///   - `HelixError.oauth(_)` — TwitchKit's refresh was answered with a
    ///     rejection, so the account has already been force-signed-out. The
    ///     refresh below finds no refresh_token and rethrows
    ///     `AppError.sessionExpired`. (Before the interceptor this was
    ///     Twitch's "missing client secret".)
    ///
    ///   - `HelixError.notAuthenticated` — TwitchKit's `TwitchTokenProvider`
    ///     holds no token: it dropped its in-memory copy after a refresh it
    ///     couldn't complete (the guarded store kept the Keychain entry), or
    ///     a build before the interceptor let it wipe the store. Our
    ///     chattr-side `OAuthRefreshTokenCache` still holds the refresh_token,
    ///     and `refreshTokens(userId:login:)` recovers from it.
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
            // TwitchKit's internal refresh was answered with a rejection
            // (see TwitchKitRefreshInterceptor). The refresh below confirms
            // the session is gone and throws `.sessionExpired`.
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
