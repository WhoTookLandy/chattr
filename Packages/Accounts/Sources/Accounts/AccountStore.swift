import Foundation
import SwiftData
import TwitchKit
import Core
import os

private let logger = AppLogger.make("Accounts.AccountStore")

/// Local registry of signed-in Twitch accounts. Single source of truth for "who is signed in"
/// and which account is currently active.
///
/// Persistence: SwiftData (`Account` rows).
/// Per-account `TwitchClient` instances are constructed lazily and cached in-memory.
///
/// Isolation: `@MainActor` rather than `actor`. SwiftData's main `ModelContext` is
/// `@MainActor`-bound by design (it backs `@Query` and `@Environment(\.modelContext)`),
/// and `@Model` instances aren't `Sendable` — passing them across an `actor` boundary
/// triggers strict-concurrency violations. `@MainActor` keeps `Account` instances inside
/// the isolation domain they already live in. Operations are lightweight and HTTP calls
/// are `async`-and-awaited, so suspending on main doesn't block the thread.
@MainActor
public final class AccountStore {
    private let modelContainer: ModelContainer
    private let clientId: String

    /// Cached per-account TwitchClient instances. Keyed by `userId`.
    private var clients: [String: TwitchClient] = [:]

    /// Currently active account's userId. Drives which client/identity drives the UI.
    private var activeUserId: String?

    public init(modelContainer: ModelContainer, clientId: String) {
        self.modelContainer = modelContainer
        self.clientId = clientId
    }

    // MARK: - Public API

    /// All known accounts, newest-first.
    public func allAccounts() async throws -> [Account] {
        let context = ModelContext(modelContainer)
        var descriptor = FetchDescriptor<Account>()
        descriptor.sortBy = [SortDescriptor(\.addedAt, order: .reverse)]
        return try context.fetch(descriptor)
    }

    /// The currently active account, if any.
    public func activeAccount() async throws -> Account? {
        guard let activeUserId else { return nil }
        let context = ModelContext(modelContainer)
        var descriptor = FetchDescriptor<Account>(predicate: #Predicate { $0.userId == activeUserId })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// Set which account is active.
    public func setActive(userId: String) {
        self.activeUserId = userId
        // .notice: account-switch is a boundary crossing — visible without
        // raising the filter threshold during debugging.
        logger.notice("Active account → \(userId, privacy: .public)")
    }

    /// Returns (constructing if needed) the TwitchClient for the given account.
    public func client(for account: Account) -> TwitchClient {
        client(forUserId: account.userId)
    }

    /// String-only variant of `client(for:)` for call sites that hold a
    /// stable userId but don't want to capture the non-Sendable
    /// SwiftData `@Model` Account across actor / closure boundaries.
    /// Used by `ChannelSessionRegistry` so its `acquire` / `session`
    /// signatures don't force `Account` captures on stored closures —
    /// see AppShell's `onOpen` for the call site that needed this.
    ///
    /// The `tokenNamespace` is reconstructed from `userId` via
    /// `Self.namespace(for:)`. Stable across launches by construction,
    /// so the TwitchClient's Keychain-backed token store finds the same
    /// entries either way.
    public func client(forUserId userId: String) -> TwitchClient {
        if let existing = clients[userId] {
            return existing
        }
        let client = TwitchClient(
            clientId: clientId,
            tokenNamespace: Self.namespace(for: userId)
        )
        clients[userId] = client
        return client
    }

    /// Persists a new account after a successful OAuth flow. Returns the inserted Account.
    /// `token` is set on the new client's auth before returning so the first Helix call works.
    public func add(token: OAuthToken, scopes: [TwitchScope]) async throws -> Account {
        // 1. Use a temporary TwitchClient with an in-memory store to call /users and learn who we are.
        //    This avoids polluting Keychain with tokens until we know the userId.
        let probe = TwitchClient(
            clientId: clientId,
            tokenStore: InMemoryTokenStore()
        )
        try await probe.auth.setToken(token)
        let user = try await probe.api.fetchUser()

        // 2. Construct the canonical tokenNamespace from userId.
        let namespace = Self.namespace(for: user.id)

        // 3. Build the persistent client (Keychain-backed) and seed it with the token.
        let persistent = TwitchClient(
            clientId: clientId,
            tokenNamespace: namespace
        )
        try await persistent.auth.setToken(token)
        clients[user.id] = persistent

        // 3b. Cache the refresh_token chattr-side so it survives TwitchKit's
        //     defensive `logout()` if a future refresh fails (see
        //     OAuthRefreshTokenCache header for the full rationale).
        OAuthRefreshTokenCache.save(refreshToken: token.refreshToken, for: user.id)

        // 4. Persist the Account row.
        // Note: TwitchUser.profileImageUrl uses lowercase 'url' (Codable from snake_case).
        // Account.profileImageURL uses uppercase 'URL' (Swift convention on stored model property).
        let account = Account(
            userId: user.id,
            login: user.login,
            displayName: user.displayName,
            profileImageURL: user.profileImageUrl,
            tokenNamespace: namespace
        )
        let context = ModelContext(modelContainer)
        context.insert(account)
        try context.save()
        activeUserId = user.id

        // .notice: account added is a user-initiated boundary crossing.
        logger.notice("Added account @\(user.login, privacy: .public) (\(user.id, privacy: .public))")
        return account
    }

    // MARK: - Forced sign-out (session expired / token revoked)

    /// Why an account is being forced out — drives downstream UI (`SignInView`
    /// reads this to decide whether to show a "session expired" banner).
    public enum SignOutReason: Sendable {
        /// The refresh token is gone or rejected; user must re-authenticate.
        case sessionExpired(login: String)
        /// The user tapped "sign out" themselves — no banner needed.
        case userInitiated
    }

    /// Defaults key for "show session-expired banner on next SignInView render."
    /// Read + cleared by `SignInView.onAppear`. UserDefaults (rather than
    /// `@SceneStorage`) so it survives true cold-start — a session can expire
    /// in the background and the user may not relaunch until much later.
    public static let lastSessionExpiredLoginKey = "chattr.lastSessionExpiredLogin"

    /// Force the app into the unauthenticated state for a specific account.
    /// Use this from the auth layer when the refresh path discovers the user
    /// genuinely cannot continue (refresh_token missing, expired, or revoked).
    ///
    /// Why this exists (vs `remove(account:)`):
    ///   - Takes a `userId: String` so callers without an `Account` in hand
    ///     (e.g. the bridge's `refreshTokens(userId:login:)`) can use it.
    ///   - **Best-effort**: it never throws. The user is already in a broken
    ///     state; piling another error on top doesn't help. We log instead.
    ///   - Writes a UserDefaults flag (`lastSessionExpiredLoginKey`) so
    ///     `SignInView` can show a contextual banner on the next render
    ///     instead of dropping the user to a blank sign-in screen.
    ///
    /// Side effect — drops the `Account` row from SwiftData. RootView's
    /// `@Query` observes this and naturally re-renders `SignInView`.
    public func forceSignOut(userId: String, reason: SignOutReason) async {
        // Stash the reason for SignInView's banner. Only the `.sessionExpired`
        // case writes — user-initiated sign-out doesn't need to explain itself.
        if case .sessionExpired(let login) = reason {
            UserDefaults.standard.set(login, forKey: Self.lastSessionExpiredLoginKey)
            // .notice: forced sign-out is a boundary event that drives UI
            // state transitions — important to see in default log filtering.
            logger.notice("forceSignOut(.sessionExpired) for @\(login, privacy: .public)")
        }

        // Find and delete the Account row. Use mainContext to keep RootView's
        // `@Query` in sync (same reasoning as `remove(account:)` — separate
        // contexts can fail to propagate delete events).
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<Account>(predicate: #Predicate { $0.userId == userId })
        if let account = try? context.fetch(descriptor).first {
            // Best-effort cleanup. Each step logs on failure but doesn't throw.
            do {
                try await client(for: account).auth.logout()
            } catch {
                // .warning, not .error: forceSignOut is intentionally best-
                // effort; a TwitchKit logout failure is expected if the
                // token was already invalid. Worth seeing but not "broken."
                logger.warning("forceSignOut: TwitchKit logout failed for @\(account.login, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            OAuthRefreshTokenCache.delete(for: userId)
            clients[userId] = nil
            if activeUserId == userId {
                activeUserId = nil
            }
            context.delete(account)
            do {
                try context.save()
            } catch {
                logger.error("forceSignOut: SwiftData save failed: \(error.localizedDescription)")
            }
        } else {
            logger.info("forceSignOut: no Account row for userId \(userId) — likely already gone")
            // Still clear the in-memory client cache and active-account
            // tracking — they may have outlived the row.
            OAuthRefreshTokenCache.delete(for: userId)
            clients[userId] = nil
            if activeUserId == userId {
                activeUserId = nil
            }
        }
    }

    /// Removes an account: clears its Keychain entries, drops cached client, deletes SwiftData row.
    ///
    /// Important: we delete via `modelContainer.mainContext` — the same context RootView's
    /// `@Query` observes. Earlier we created a fresh `ModelContext(modelContainer)` here,
    /// which can fail to propagate delete events to other contexts watching the store.
    /// Using mainContext ensures `@Query` immediately sees the empty accounts array and
    /// re-renders to SignInView.
    public func remove(account: Account) async throws {
        let client = client(for: account)
        // TwitchAuth.logout() delegates to tokenProvider.logout() internally.
        try await client.auth.logout()
        // Clear our refresh_token cache for this user too — TwitchKit's
        // logout only touches its own store; our fallback cache is separate
        // (intentionally — see OAuthRefreshTokenCache header).
        OAuthRefreshTokenCache.delete(for: account.userId)
        clients[account.userId] = nil
        if activeUserId == account.userId {
            activeUserId = nil
        }
        let context = modelContainer.mainContext
        context.delete(account)
        try context.save()
        logger.notice("Removed account @\(account.login, privacy: .public)")
    }

    // MARK: - Helpers

    /// The canonical tokenNamespace string for a given Twitch userId.
    /// Stays stable across launches so Keychain entries persist.
    public static func namespace(for userId: String) -> String {
        "chattr.account.\(userId)"
    }

    /// One-shot backfill: if `OAuthRefreshTokenCache` is empty for this
    /// account but TwitchKit's store still has a refresh_token, mirror it
    /// into our cache so a future refresh failure has somewhere to recover
    /// from.
    ///
    /// Safe to call on every launch — it's a no-op once the cache is
    /// populated (we only write when the cache is empty).
    ///
    /// Why this exists: users who upgrade to this build already have valid
    /// tokens in TwitchKit's store but nothing in our new cache. Without
    /// this warm-up, the first refresh failure post-upgrade would still
    /// strand them at "Session expired — please sign in again." Mirroring
    /// at launch protects them for the cost of one Keychain read + write.
    public func warmRefreshTokenCacheIfNeeded(for account: Account) async {
        if OAuthRefreshTokenCache.load(for: account.userId) != nil {
            return  // Already populated; nothing to do.
        }
        let client = client(for: account)
        do {
            let token = try await client.auth.tokenProvider.token()
            guard let refreshToken = token.refreshToken, !refreshToken.isEmpty else {
                logger.info("warmRefreshTokenCache: TwitchKit token has no refresh_token for @\(account.login)")
                return
            }
            OAuthRefreshTokenCache.save(refreshToken: refreshToken, for: account.userId)
            logger.info("warmRefreshTokenCache: mirrored refresh_token for @\(account.login)")
        } catch {
            // TwitchKit's store is empty (or unreadable). We can't backfill
            // — the user is already in the broken state and needs to
            // re-sign-in. Don't surface as an error; the next Helix call
            // will throw `.notAuthenticated` which is the right signal.
            logger.info("warmRefreshTokenCache: TwitchKit store empty for @\(account.login) — backfill skipped")
        }
    }
}

// MARK: - Token Refresh

extension AccountStore {

    /// URL of chattr-auth's refresh endpoint. Centralized in `Core.Endpoints`
    /// alongside the corresponding `callback` URL that `SignInView` uses;
    /// both live on the same Vercel bridge that holds the client_secret.
    private static var refreshURL: URL {
        Endpoints.ChattrAuth.refresh
    }

    /// Refreshes the OAuth tokens for the given account via the Vercel bridge.
    ///
    /// Reads the current refresh_token from this account's TwitchAuth (which reads
    /// from Keychain via TokenStore), POSTs it to the bridge, parses the new tokens,
    /// and saves them. Throws `AppError` on any failure — caller decides whether to
    /// surface as "needs re-auth" UI vs a transient error banner.
    ///
    /// Side effects: persists the new OAuthToken via `TwitchAuth.setToken(_:)`, which
    /// also updates the in-memory cachedAccessToken / cachedRefreshToken.
    @discardableResult
    public func refreshTokens(for account: Account) async throws -> OAuthToken {
        try await refreshTokens(userId: account.userId, login: account.login)
    }

    /// Variant that accepts plain strings so `@Sendable` closures (e.g. in
    /// `ChannelSessionRegistry`) can capture stable IDs instead of the non-Sendable
    /// `Account` model object.
    @discardableResult
    public func refreshTokens(userId: String, login: String) async throws -> OAuthToken {
        // Build a throw-away TwitchClient using the canonical namespace for this userId.
        // `clients` is keyed by userId so this returns the already-cached client if one exists.
        let namespace = Self.namespace(for: userId)
        let twitchClient: TwitchClient
        if let existing = clients[userId] {
            twitchClient = existing
        } else {
            twitchClient = TwitchClient(clientId: clientId, tokenNamespace: namespace)
            clients[userId] = twitchClient
        }

        // Pull the refresh_token. Two sources, in priority order:
        //   1. TwitchKit's own store via `tokenProvider.token()` — the
        //      happy path.
        //   2. Our chattr-side `OAuthRefreshTokenCache` — fallback for the
        //      case where TwitchKit's auto-refresh failed and wiped the
        //      store as defensive cleanup. Without this fallback, the
        //      first refresh failure (e.g. "missing client secret") makes
        //      every subsequent recovery attempt throw `.notAuthenticated`
        //      and the user is stuck re-signing-in.
        //
        // `tokenProvider.token()` throws `HelixError.notAuthenticated` when
        // its store is empty. We catch that specific case rather than
        // letting it bubble — the cache is exactly the recovery path it
        // wants.
        let refreshToken: String
        do {
            let currentToken = try await twitchClient.auth.tokenProvider.token()
            if let t = currentToken.refreshToken, !t.isEmpty {
                refreshToken = t
            } else if let cached = OAuthRefreshTokenCache.load(for: userId) {
                // .warning: recoverable fallback path — we ARE working around
            // a problem (TwitchKit lost its refresh_token), but the chattr
            // cache saved us.
            logger.warning("TwitchKit token has no refresh_token; using chattr-side cache for @\(login, privacy: .public)")
                refreshToken = cached
            } else {
                // Terminal: no refresh_token anywhere. Drive the
                // unauthenticated state transition so RootView re-renders
                // SignInView with a "session expired" banner instead of
                // leaving the user staring at a broken signed-in screen.
                await forceSignOut(userId: userId, reason: .sessionExpired(login: login))
                throw AppError.sessionExpired(login: login)
            }
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
            refreshToken = cached
        }

        var request = URLRequest(url: Self.refreshURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct RequestBody: Encodable { let refresh_token: String }
        request.httpBody = try JSONEncoder().encode(RequestBody(refresh_token: refreshToken))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppError(message: "Bridge refresh: no HTTP response")
        }

        if http.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? "(no body)"
            // body is server-side debug text (no secrets) — public is fine.
            logger.error("Bridge refresh failed for @\(login, privacy: .public) (HTTP \(http.statusCode)): \(body, privacy: .public)")
            // 4xx → Twitch rejected the refresh_token (revoked, expired, or
            //       associated with a different client_id). Terminal — the
            //       refresh credential we have can never work again, so
            //       drop the Account row and show the session-expired
            //       banner on the next render.
            // 5xx → Bridge / Twitch is having a bad day. Transient. Throw
            //       so the caller can decide whether to retry or show a
            //       "couldn't reach server" toast, but DON'T sign the user
            //       out — their credentials are probably still good.
            if (400..<500).contains(http.statusCode) {
                await forceSignOut(userId: userId, reason: .sessionExpired(login: login))
                throw AppError.sessionExpired(login: login)
            }
            throw AppError.bridgeRefreshFailed(status: http.statusCode)
        }

        // Twitch's response is snake_case. Use `.convertFromSnakeCase` so the struct
        // stays camelCase — matches `JSONDecoder.twitch()` inside TwitchKit (which is
        // internal to that library, hence the explicit config here).
        struct TwitchRefreshResponse: Decodable {
            let accessToken: String
            let refreshToken: String?
            let expiresIn: Int?
            let scope: [String]?
            let tokenType: String?
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let parsed = try decoder.decode(TwitchRefreshResponse.self, from: data)
        // Twitch's `/oauth2/token` refresh sometimes returns a new
        // refresh_token, sometimes not (rotation is conditional on Twitch's
        // own policy). When the response omits it, carry forward the one
        // we *used* — otherwise persisting `refreshToken: nil` would leave
        // the next refresh empty-handed.
        let nextRefreshToken = parsed.refreshToken ?? refreshToken
        let newToken = OAuthToken(
            accessToken: parsed.accessToken,
            refreshToken: nextRefreshToken,
            expiresIn: parsed.expiresIn,
            scope: parsed.scope,
            tokenType: parsed.tokenType
        )
        try await twitchClient.auth.setToken(newToken)
        // Mirror to chattr-side cache so the next failure has somewhere
        // to recover from even if TwitchKit clears its store again.
        OAuthRefreshTokenCache.save(refreshToken: nextRefreshToken, for: userId)
        logger.info("Refreshed tokens for @\(login, privacy: .public) (expires_in=\(parsed.expiresIn ?? -1))")
        return newToken
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
    ///     still holds the refresh_token — `refreshTokens(for:)` will read
    ///     it from there and recover transparently.
    ///
    /// In all three cases, `refreshTokens(for:)` POSTs to the bridge with the
    /// refresh_token and persists the new OAuthToken. Subsequent operation()
    /// retry uses the fresh access token.
    ///
    /// Any throw from the refresh OR the second operation attempt bubbles to
    /// the caller (no infinite loops — only one retry).
    public func withTokenRefresh<T: Sendable>(
        for account: Account,
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        do {
            return try await operation()
        } catch HelixError.unauthorized {
            logger.info("Helix call returned unauthorized for @\(account.login); refreshing via bridge and retrying")
            try await refreshTokens(for: account)
            return try await operation()
        } catch HelixError.oauth(let oauthError) {
            // TwitchKit's internal auto-refresh fired and failed — likely
            // "missing client secret" because we don't ship one. Bridge it.
            logger.info("TwitchKit auto-refresh failed for @\(account.login) (\(oauthError.message)); refreshing via bridge and retrying")
            try await refreshTokens(for: account)
            return try await operation()
        } catch HelixError.notAuthenticated {
            // TwitchKit's store is empty — most likely because a prior
            // refresh attempt failed and called logout() on its store.
            // Our chattr-side cache should still hold the refresh_token;
            // refreshTokens(for:) will read from there.
            logger.info("TwitchKit store empty for @\(account.login); attempting recovery via chattr-side cache")
            try await refreshTokens(for: account)
            return try await operation()
        }
    }
}
