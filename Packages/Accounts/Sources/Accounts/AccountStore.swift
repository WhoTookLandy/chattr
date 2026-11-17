import Foundation
import SwiftData
import TwitchKit
import Core
import os

private let logger = AppLogger.make("Accounts.AccountStore")

/// Local registry of signed-in Twitch accounts. Single source of truth for "who is signed in".
///
/// A facade over focused collaborators — callers in Channels / Features only
/// ever see this type:
///   - `AccountRepository` — SwiftData `Account` rows (via `mainContext`).
///   - `ActiveAccountSelection` — the per-device active-account choice in
///     UserDefaults (observed by RootView's `@AppStorage`). AccountStore
///     keeps no second, in-memory copy of it.
///   - `TwitchClientCache` — per-account `TwitchClient`s, built lazily.
///   - `BridgeTokenRefresh` + `TokenRefresher` + `OAuthRefreshTokenCache` —
///     the bridge refresh call, its single-flight gate, and the chattr-side
///     Keychain mirror of refresh tokens (see `AccountStore+TokenRefresh`).
///
/// Isolation: `@MainActor` rather than `actor`. SwiftData's main `ModelContext` is
/// `@MainActor`-bound by design (it backs `@Query` and `@Environment(\.modelContext)`),
/// and `@Model` instances aren't `Sendable` — passing them across an `actor` boundary
/// triggers strict-concurrency violations. `@MainActor` keeps `Account` instances inside
/// the isolation domain they already live in. Operations are lightweight and HTTP calls
/// are `async`-and-awaited, so suspending on main doesn't block the thread.
@MainActor
public final class AccountStore {
    /// Shared "any channel open?" flag. The registry increments/decrements it;
    /// the persistent EventSub clients read it via their `isLive` closure so
    /// reconnect stays aggressive while a channel is open. (See SessionActivitySignal.)
    public let sessionActivity: SessionActivitySignal

    /// Public Twitch client id (not a secret) — what the OAuth sign-in flow
    /// and every `TwitchClient` are built with.
    public var clientId: String { clients.clientId }

    /// Called after `remove(account:)` has deleted an account's row, with
    /// that account's `userId`. The composition root wires this to drop
    /// state other layers keep per account (persisted chat tabs, drafts) —
    /// a callback rather than a direct call so Accounts never imports them.
    /// Not called by `forceSignOut`: an expired account stays listed (and
    /// keeps its tabs) until the user re-authorizes or removes it.
    public var onAccountRemoved: (@MainActor (_ userId: String) -> Void)?

    let repository: AccountRepository
    let clients: TwitchClientCache
    let selection: ActiveAccountSelection
    let bridgeRefresh: BridgeTokenRefresh

    /// Single-flight gate for bridge refreshes — see `TokenRefresher`.
    let tokenRefresher = TokenRefresher()

    public convenience init(modelContainer: ModelContainer, clientId: String) {
        self.init(
            modelContainer: modelContainer,
            clientId: clientId,
            defaults: .standard,
            bridgeRefresh: BridgeTokenRefresh()
        )
    }

    /// Designated init with the seams tests swap out. `twitchTransport` and
    /// `tokenStoreFactory` default to the real network and Keychain (see
    /// `TwitchClientCache`).
    init(
        modelContainer: ModelContainer,
        clientId: String,
        defaults: UserDefaults,
        bridgeRefresh: BridgeTokenRefresh,
        twitchTransport: any HTTPClient = URLSessionHTTPClient(),
        tokenStoreFactory: (@Sendable (_ namespace: String) -> any TwitchTokenStore)? = nil
    ) {
        let activity = SessionActivitySignal()
        self.sessionActivity = activity
        self.repository = AccountRepository(modelContainer: modelContainer)
        self.clients = TwitchClientCache(
            clientId: clientId,
            sessionActivity: activity,
            transport: twitchTransport,
            tokenStoreFactory: tokenStoreFactory
        )
        self.selection = ActiveAccountSelection(defaults: defaults)
        self.bridgeRefresh = bridgeRefresh
        // TwitchKit's own 401 refresh goes through the bridge, never Twitch
        // (see `TwitchKitRefreshInterceptor`). Weak: the cache is ours.
        clients.refreshHandler = { [weak self] userId in
            guard let self else { return .unavailable }
            return await self.answerTwitchKitRefresh(userId: userId)
        }
    }

    // MARK: - Accounts

    /// All known accounts across every platform, newest-first. The returned
    /// rows belong to `mainContext`, so they stay valid for callers.
    public func allAccounts() async throws -> [Account] {
        try repository.all()
    }

    /// Accounts for one platform, newest-first.
    public func allAccounts(on platform: ChatPlatform) async throws -> [Account] {
        try repository.all(on: platform)
    }

    // MARK: - Active account

    /// Records that RootView is now rendering `userId` on `platform`.
    ///
    /// Log-only: AccountStore keeps no in-memory "active account" slot —
    /// the UserDefaults selection (`activeAccountKey(for:)`, written by
    /// `selectAccount`) is the single source of truth. Retained because
    /// RootView calls it on every rendered-account change; the log line is
    /// still a useful boundary marker.
    public func setActive(userId: String, platform: ChatPlatform = .twitch) {
        // .notice: account-switch is a boundary crossing — visible without
        // raising the filter threshold during debugging.
        logger.notice("Active \(platform.rawValue, privacy: .public) account → \(userId, privacy: .public)")
    }

    /// UserDefaults key holding the userId of the device's active **Twitch**
    /// account. Read by RootView (`@AppStorage`) to pick which account's
    /// AppShell to show, and by the account switcher to mark the active row.
    /// The bare legacy key — see `ActiveAccountSelection.twitchKey`.
    public static let activeAccountUserIdKey = ActiveAccountSelection.twitchKey

    /// Per-platform UserDefaults key for the active-account selection.
    /// `.twitch` maps to the legacy unsuffixed key (see above).
    public static func activeAccountKey(for platform: ChatPlatform) -> String {
        ActiveAccountSelection.key(for: platform)
    }

    /// Make the account with `userId` active on `platform`. Writes the
    /// userId to UserDefaults, which RootView's `@AppStorage` observes via
    /// KVO and reacts to — re-rendering AppShell with the new account. No
    /// SwiftData write, so no migration and no per-device sync.
    public func selectAccount(userId: String, platform: ChatPlatform = .twitch) {
        selection.select(userId: userId, on: platform)
        logger.notice("Selected account \(userId, privacy: .public) on \(platform.rawValue, privacy: .public)")
    }

    /// Convenience that reads the platform off the account row itself —
    /// prefer this from UI code so call sites can't pair a userId with
    /// the wrong platform.
    public func selectAccount(_ account: Account) {
        selectAccount(userId: account.userId, platform: account.platform)
    }

    // MARK: - Clients

    /// Returns (constructing if needed) the TwitchClient for the given account.
    public func client(for account: Account) -> TwitchClient {
        clients.client(forUserId: account.userId)
    }

    /// String-only variant of `client(for:)` for call sites that hold a
    /// stable userId but don't want to capture the non-Sendable
    /// SwiftData `@Model` Account across actor / closure boundaries.
    /// Used by `ChannelSessionRegistry` so its `acquire` / `session`
    /// signatures don't force `Account` captures on stored closures.
    public func client(forUserId userId: String) -> TwitchClient {
        clients.client(forUserId: userId)
    }

    /// The canonical tokenNamespace string for a given Twitch userId.
    /// Stays stable across launches so Keychain entries persist.
    public static func namespace(for userId: String) -> String {
        TwitchClientCache.namespace(for: userId)
    }

    // MARK: - Add

    /// Persists a new account after a successful OAuth flow, makes it the
    /// active account, and returns the inserted row. `token` is set on the
    /// new client's auth before returning so the first Helix call works.
    public func add(token: OAuthToken, scopes: [TwitchScope]) async throws -> Account {
        // 1. Learn who the token belongs to via a probe client over an
        //    in-memory store — nothing hits the Keychain until we know the userId.
        let probe = clients.makeProbeClient()
        try await probe.auth.setToken(token)
        let user = try await probe.api.fetchUser()

        // 2. Build the persistent (Keychain-backed) client, seed it, cache it.
        let persistent = clients.makeClient(forUserId: user.id)
        try await persistent.auth.setToken(token)
        clients.install(persistent, forUserId: user.id)

        // 3. Cache the refresh_token chattr-side so it survives TwitchKit's
        //    defensive `logout()` if a future refresh fails (see
        //    OAuthRefreshTokenCache header for the full rationale).
        OAuthRefreshTokenCache.save(refreshToken: token.refreshToken, for: user.id)

        // 4. Persist the Account row.
        // Note: TwitchUser.profileImageUrl uses lowercase 'url' (Codable from snake_case).
        // Account.profileImageURL uses uppercase 'URL' (Swift convention on stored model property).
        let account = Account(
            userId: user.id,
            platform: .twitch,
            login: user.login,
            displayName: user.displayName,
            profileImageURL: user.profileImageUrl,
            tokenNamespace: Self.namespace(for: user.id)
        )
        try repository.insert(account)

        // 5. Make it active on this device. RootView's @AppStorage observes
        //    the key and re-renders into the new account.
        selection.select(userId: user.id, on: .twitch)

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

    /// Force a specific account into the needs-re-auth state. Use this from
    /// the auth layer when the refresh path discovers the user genuinely
    /// cannot continue (refresh_token missing, expired, or revoked).
    ///
    /// Why this exists (vs `remove(account:)`):
    ///   - Takes a `userId: String` so callers without an `Account` in hand
    ///     (e.g. the bridge's `refreshTokens(userId:login:)`) can use it.
    ///   - **Best-effort**: it never throws. The user is already in a broken
    ///     state; piling another error on top doesn't help. We log instead.
    ///   - Writes a UserDefaults flag (`lastSessionExpiredLoginKey`) so
    ///     `SignInView` can show a contextual banner on the next render —
    ///     but only when no healthy account remains to fall back to (with
    ///     a healthy account, RootView lands there instead of SignInView,
    ///     and a months-stale banner on some future sign-out would mislead).
    ///
    /// Side effect — the `Account` row is **marked `needsReauth`, not
    /// deleted**. The account stays visible in the switcher with a
    /// "session expired" badge and a one-tap re-authorize, instead of
    /// silently vanishing. RootView's `@Query` observes the change and
    /// re-renders: to the next healthy account, or to `SignInView` when
    /// none remains. (Deleting is reserved for user-initiated
    /// `remove(account:)`.)
    public func forceSignOut(userId: String, reason: SignOutReason) async {
        let account = try? repository.account(userId: userId)

        // Stash the reason for SignInView's banner. Only the `.sessionExpired`
        // case writes — user-initiated sign-out doesn't need to explain itself
        // — and only when this expiry leaves no healthy signed-in account
        // (i.e. the user will actually land on SignInView).
        if case .sessionExpired(let login) = reason {
            let healthyRemain = repository.hasHealthyAccount(excluding: userId)
            if !healthyRemain {
                selection.defaults.set(login, forKey: Self.lastSessionExpiredLoginKey)
            }
            // .notice: forced sign-out is a boundary event that drives UI
            // state transitions — important to see in default log filtering.
            logger.notice("forceSignOut(.sessionExpired) for @\(login, privacy: .public) (healthy fallback remains: \(healthyRemain))")
        }

        guard let account else {
            logger.info("forceSignOut: no Account row for userId \(userId) — likely already gone")
            // Still clear the in-memory client cache — it may have
            // outlived the row.
            OAuthRefreshTokenCache.delete(for: userId)
            clients.evict(userId: userId)
            return
        }

        // Best-effort cleanup. Each step logs on failure but doesn't throw.
        do {
            try await clients.client(forUserId: userId).auth.logout()
        } catch {
            // .warning, not .error: forceSignOut is intentionally best-
            // effort; a TwitchKit logout failure is expected if the
            // token was already invalid. Worth seeing but not "broken."
            logger.warning("forceSignOut: TwitchKit logout failed for @\(account.login, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        OAuthRefreshTokenCache.delete(for: userId)
        clients.evict(userId: userId)
        // Mark, don't delete — see the doc comment. Also clear the stored
        // selection if it pointed here, so RootView's fallback picks a
        // healthy account rather than re-resolving this one.
        account.needsReauth = true
        selection.clear(ifSelected: userId, on: account.platform)
        do {
            try repository.save()
        } catch {
            logger.error("forceSignOut: SwiftData save failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Remove

    /// Removes an account: clears its Keychain entries, drops cached client,
    /// deletes the SwiftData row, then notifies `onAccountRemoved`.
    ///
    /// The TwitchKit `logout()` is **best-effort** (same as `forceSignOut`):
    /// it fails exactly when the user most wants out — token already
    /// revoked, Keychain entry already wiped — and aborting there would
    /// leave an account that can't be removed. Only the SwiftData save throws
    /// (and then `onAccountRemoved` is not called).
    public func remove(account: Account) async throws {
        // Read the row's fields up front: once deleted, touching the @Model's
        // properties is undefined behavior.
        let userId = account.userId
        let login = account.login
        let platform = account.platform

        // TwitchAuth.logout() delegates to tokenProvider.logout() internally.
        do {
            try await clients.client(forUserId: userId).auth.logout()
        } catch {
            // .warning, not .error: removal proceeds regardless. A leftover
            // Keychain entry under this namespace is harmless — re-adding
            // the account overwrites it via setToken.
            logger.warning("remove: TwitchKit logout failed for @\(login, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        // Clear our refresh_token cache for this user too — TwitchKit's
        // logout only touches its own store; our fallback cache is separate
        // (intentionally — see OAuthRefreshTokenCache header).
        OAuthRefreshTokenCache.delete(for: userId)
        clients.evict(userId: userId)
        // If we removed the active account, clear the stored selection so
        // RootView's @AppStorage fallback (accounts.first by addedAt) picks
        // the next account — or SignInView if it was the last one.
        selection.clear(ifSelected: userId, on: platform)
        // mainContext — the context RootView's @Query observes — so the
        // delete propagates and RootView re-renders immediately.
        try repository.delete(account)
        logger.notice("Removed account @\(login, privacy: .public)")
        onAccountRemoved?(userId)
    }

    // MARK: - Refresh-token cache warm-up

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
