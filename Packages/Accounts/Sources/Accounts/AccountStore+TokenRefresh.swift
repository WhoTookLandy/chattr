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
    /// same refresh_token to the bridge (where all but the first could be
    /// told it is invalid and force a sign-out).
    ///
    /// Not every call reaches the bridge: a token issued in the last few
    /// seconds is returned as is, and after a transient failure calls fail
    /// fast with that error while the refresher backs off. Both are scoped
    /// to the account's current client, so they end with a sign-out or
    /// re-authorization.
    @discardableResult
    public func refreshTokens(userId: String, login: String) async throws -> OAuthToken {
        let scope = clients.entry(forUserId: userId).lifecycle
        return try await tokenRefresher.refresh(userId: userId, scope: scope) {
            try await self.performRefresh(userId: userId, login: login)
        }
    }

    // MARK: Proactive refresh

    /// How long before expiry `refreshTokensIfExpiringSoon` refreshes.
    public static let proactiveRefreshLeeway: TimeInterval = 10 * 60

    /// Refreshes `account`'s tokens now if its access token expires within
    /// `proactiveRefreshLeeway` (or already has), so the requests that
    /// follow don't each pay a 401 first. Call before the launch fan-out and
    /// when the app returns to the foreground.
    ///
    /// Does nothing for an account that needs re-authorization or whose
    /// expiry isn't known (signed in before expiry was recorded; the first
    /// refresh records it). Never throws: a failure here is the same one the
    /// next request's own refresh would report, and a dead refresh token has
    /// already signed the account out.
    public func refreshTokensIfExpiringSoon(for account: Account) async {
        guard !account.needsReauth else { return }
        let userId = account.userId
        let login = account.login
        guard let expiry = tokenExpiry(forUserId: userId) else { return }
        let remaining = expiry.timeIntervalSince(tokenRefresher.now())
        guard remaining < Self.proactiveRefreshLeeway else { return }
        logger.info("Access token for @\(login, privacy: .public) expires in \(Int(remaining))s; refreshing ahead of use")
        do {
            try await refreshTokens(userId: userId, login: login)
        } catch {
            logger.warning("Proactive refresh failed for @\(login, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// UserDefaults key for the absolute expiry of `userId`'s access token
    /// (seconds since 1970). A timestamp, not a credential, so it lives
    /// beside the account selection rather than in the Keychain.
    static func tokenExpiryKey(for userId: String) -> String {
        "chattr.tokenExpiry.\(userId)"
    }

    /// When `userId`'s current access token expires, if known.
    func tokenExpiry(forUserId userId: String) -> Date? {
        let seconds = selection.defaults.double(forKey: Self.tokenExpiryKey(for: userId))
        return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
    }

    /// Records the expiry of a token issued just now. A token without
    /// `expires_in` clears the record: the old expiry isn't this token's.
    func recordTokenExpiry(of token: OAuthToken, forUserId userId: String) {
        guard let expiresIn = token.expiresIn, expiresIn > 0 else {
            clearTokenExpiry(forUserId: userId)
            return
        }
        let expiry = tokenRefresher.now().addingTimeInterval(TimeInterval(expiresIn))
        selection.defaults.set(expiry.timeIntervalSince1970, forKey: Self.tokenExpiryKey(for: userId))
    }

    func clearTokenExpiry(forUserId userId: String) {
        selection.defaults.removeObject(forKey: Self.tokenExpiryKey(for: userId))
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
    /// - anything else (a bridge error that doesn't name the refresh token,
    ///   network, a refresh that is backing off) → `.unavailable` with the
    ///   token the asking client holds in memory: transient, so that
    ///   credential must survive.
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
        let refreshToken = try await currentRefreshToken(userId: userId, login: login, entry: entry)

        let newToken: OAuthToken
        do {
            newToken = try await bridgeRefresh.refresh(using: refreshToken, login: login)
        } catch is BridgeTokenRefresh.Rejected {
            // A rejection of a credential that is no longer the account's
            // says nothing about the current one: don't sign that out.
            try Self.checkStillCurrent(entry, login: login)
            // Twitch said the refresh_token itself is invalid (revoked or
            // expired). Terminal — the refresh credential we have can never
            // work again, so mark the account expired and show the
            // session-expired banner on the next render. (Every other bridge
            // or transport error propagates untouched: transient, and the
            // user's credentials are probably still good.)
            await forceSignOut(userId: userId, reason: .sessionExpired(login: login), expecting: entry)
            throw AppError.sessionExpired(login: login)
        }

        try Self.checkStillCurrent(entry, login: login)
        // Ordered after every token issued before it, so a TwitchKit save of
        // an older one that arrives late is dropped (see
        // `AccountTokenGate.admitSave`).
        clients.tokenGate(forUserId: userId).recordIssued(newToken)
        // The guarded token store re-checks the lifecycle under the account's
        // token gate, so this save is dropped if the client was retired first.
        try await twitchClient.auth.setToken(newToken)
        try Self.checkStillCurrent(entry, login: login)
        // Mirror to chattr-side cache so the next failure has somewhere
        // to recover from even if TwitchKit clears its store again. No
        // suspension between the check above and this write.
        OAuthRefreshTokenCache.save(refreshToken: newToken.refreshToken, for: userId, in: refreshTokenKeychain)
        recordTokenExpiry(of: newToken, forUserId: userId)
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
    ///      Unless the account's token gate knows a newer bridge-issued token
    ///      (the provider was handed an older one late, and the re-seed
    ///      hasn't landed yet): then that token's refresh_token, which is
    ///      also what the chattr-side cache mirrors. The older one was
    ///      already spent, and POSTing it risks `invalid_grant`.
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
    private func currentRefreshToken(userId: String, login: String, entry: TwitchClientCache.Entry) async throws -> String {
        // `tokenProvider.token()` throws `HelixError.notAuthenticated` when
        // its store is empty. We catch that specific case rather than
        // letting it bubble — the cache is exactly the recovery path it
        // wants.
        do {
            let currentToken = try await entry.client.auth.tokenProvider.token()
            // Re-verify the client is still live before touching the shared
            // per-userId cache or calling the bridge: if the account was
            // re-authorized during the await above, reading the cache would
            // load and spend the NEW session's refresh token only to discard
            // the rotated result at the end of `performRefresh`.
            try Self.checkStillCurrent(entry, login: login)
            if let newer = clients.tokenGate(forUserId: userId).newerToken(than: currentToken),
               let token = newer.refreshToken, !token.isEmpty {
                logger.notice("TwitchKit holds a superseded token for @\(login, privacy: .public); refreshing with the newest refresh_token")
                return token
            }
            if let token = currentToken.refreshToken, !token.isEmpty {
                return token
            }
            if let cached = try await OAuthRefreshTokenCache.loadThrowingAsync(for: userId, in: refreshTokenKeychain) {
                try Self.checkStillCurrent(entry, login: login)
                // .warning: recoverable fallback path — we ARE working around
                // a problem (TwitchKit lost its refresh_token), but the
                // chattr cache saved us.
                logger.warning("TwitchKit token has no refresh_token; using chattr-side cache for @\(login, privacy: .public)")
                return cached
            }
            try Self.checkStillCurrent(entry, login: login)
            // Terminal: no refresh_token anywhere.
            await forceSignOut(userId: userId, reason: .sessionExpired(login: login), expecting: entry)
            throw AppError.sessionExpired(login: login)
        } catch HelixError.notAuthenticated {
            // Re-verify before falling back to the shared per-userId cache so
            // a retired client never reads and spends a newer session's token
            // (and never reports `.rejected` when it should be `.discarded`).
            try Self.checkStillCurrent(entry, login: login)
            // TwitchKit's store is empty (most likely because its own
            // refresh attempt failed and called logout()). Fall back to
            // our independent cache. A transient Keychain error throws out
            // instead of forcing a permanent sign-out.
            guard let cached = try await OAuthRefreshTokenCache.loadThrowingAsync(for: userId, in: refreshTokenKeychain) else {
                try Self.checkStillCurrent(entry, login: login)
                logger.error("TwitchKit store empty AND chattr cache empty for @\(login) — must re-sign-in")
                // Terminal: drive the auth-state transition (see above).
                await forceSignOut(userId: userId, reason: .sessionExpired(login: login), expecting: entry)
                throw AppError.sessionExpired(login: login)
            }
            try Self.checkStillCurrent(entry, login: login)
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
    ///     Refresh + retry once. When TwitchKit's refresh did succeed moments
    ///     ago, this one is answered with that same token (no second bridge
    ///     call), so a 401 that can't clear costs one refresh, not three.
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
    /// In all three cases, `refreshTokens(userId:login:)` gets a fresh
    /// OAuthToken (from the bridge, or the one it issued seconds ago) and the
    /// operation() retry uses its access token.
    ///
    /// Any throw from the refresh OR the second operation attempt bubbles to
    /// the caller (no infinite loops — only one retry).
    public func withTokenRefresh<T: Sendable>(
        for account: Account,
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        // Read now: the row can be deleted while the operation runs.
        let login = account.login
        return try await withTokenRefresh(userId: account.userId, login: { login }, operation)
    }

    /// `withTokenRefresh(for:)` for call sites that hold only a stable userId
    /// (e.g. `BlockStore`). The login — used for logs and the session-expired
    /// banner — is looked up from the Account row only once a refresh is
    /// needed, falling back to the userId if the row is gone.
    public func withTokenRefresh<T: Sendable>(
        forUserId userId: String,
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        try await withTokenRefresh(
            userId: userId,
            login: { self.repository.login(forUserId: userId) ?? userId },
            operation
        )
    }

    /// `resolveLogin` is only called on an error path, so the success path
    /// never pays for it.
    private func withTokenRefresh<T: Sendable>(
        userId: String,
        login resolveLogin: () -> String,
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        do {
            return try await operation()
        } catch HelixError.unauthorized {
            let login = resolveLogin()
            logger.info("Helix call returned unauthorized for @\(login); refreshing via bridge and retrying")
            try await refreshTokens(userId: userId, login: login)
            return try await operation()
        } catch HelixError.oauth(let oauthError) {
            // TwitchKit's internal refresh was answered with a rejection
            // (see TwitchKitRefreshInterceptor). The refresh below confirms
            // the session is gone and throws `.sessionExpired`.
            let login = resolveLogin()
            logger.info("TwitchKit auto-refresh failed for @\(login) (\(oauthError.message)); refreshing via bridge and retrying")
            try await refreshTokens(userId: userId, login: login)
            return try await operation()
        } catch HelixError.notAuthenticated {
            // TwitchKit's store is empty — most likely because a prior
            // refresh attempt failed and called logout() on its store.
            // Our chattr-side cache should still hold the refresh_token;
            // refreshTokens(userId:login:) will read from there.
            let login = resolveLogin()
            logger.info("TwitchKit store empty for @\(login); attempting recovery via chattr-side cache")
            try await refreshTokens(userId: userId, login: login)
            return try await operation()
        }
    }
}
