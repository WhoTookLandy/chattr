import Foundation
import Security
import Core
import os

private let logger = AppLogger.make("Accounts.OAuthRefreshTokenCache")

/// Chattr-side Keychain cache for OAuth refresh tokens.
///
/// ## Why this exists
///
/// TwitchKit's `TwitchTokenProvider.refreshIfNeeded()` calls `logout()` on
/// refresh failure (see TwitchTokenProvider.swift:59-66 in v0.2.x), which
/// **deletes the entire token from its `TwitchTokenStore`** — including the
/// refresh_token we'd need to recover.
///
/// In chattr that path fires whenever the access token goes stale (~12hr+):
///
///   1. Helix call → 401
///   2. `HelixClient` auto-calls `tokenProvider.refreshIfNeeded()`
///   3. `refreshIfNeeded` POSTs to `/oauth2/token` without a `client_secret`
///      (we keep the secret server-side on the Vercel bridge)
///   4. Twitch rejects with `missing client secret` → `HelixError.oauth(...)`
///   5. The `catch` in `refreshIfNeeded` calls `try await logout()` →
///      **TwitchKit's Keychain entry is now empty**
///   6. Our `AccountStore.withTokenRefresh` catches `.oauth(...)` and calls
///      `refreshTokens(userId:login:)`, but `tokenProvider.token()` now throws
///      `.notAuthenticated` because step 5 wiped the store.
///
/// This cache is a second copy of the refresh_token in a Keychain entry
/// chattr owns, *independent* of TwitchKit's store. Our bridge refresh path
/// reads it as a fallback so step 6 still has a refresh_token to POST.
///
/// `TwitchKitRefreshInterceptor` now stops steps 3–5: TwitchKit's refresh
/// goes through the bridge and only a genuinely dead refresh token lets it
/// log out. The cache stays as a backstop, for stores already wiped by
/// earlier builds and for anything the interceptor doesn't cover.
///
/// ## Trust model
///
/// Same hardware-backed Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`)
/// as TwitchKit's own store — same protection class, same per-device scope.
/// The cache holds *only* the refresh_token, never the access_token (access
/// tokens are short-lived and cheap to re-acquire; refresh tokens are the
/// long-lived credential worth protecting).
///
/// ## Testability
///
/// The Keychain primitives sit behind `RefreshTokenKeychain`, swapped via the
/// `keychain` seam below. Production uses `SystemRefreshTokenKeychain`; tests
/// inject an in-memory fake so the namespacing + nil/empty guard logic is
/// covered without a host-app entitlement (a plain SwiftPM test bundle has no
/// Keychain access and SecItem returns `errSecMissingEntitlement`).
///
/// Each operation also takes an optional `keychain` argument. `AccountStore`
/// passes its own (`AccountStore.refreshTokenKeychain`), so a test can watch
/// one store without swapping the process-wide seam under parallel suites.
enum OAuthRefreshTokenCache {

    /// Backend used for all Keychain reads/writes. Defaults to the real
    /// system Keychain; tests replace it with an in-memory fake (and restore
    /// it after). Lock-backed rather than `nonisolated(unsafe)` so a swap
    /// racing a read is a compile-checked, well-defined handoff instead of a
    /// data race the compiler was told to ignore.
    static var keychain: any RefreshTokenKeychain {
        get { keychainStore.withLock { $0 } }
        set { keychainStore.withLock { $0 = newValue } }
    }

    private static let keychainStore = OSAllocatedUnfairLock<any RefreshTokenKeychain>(
        initialState: SystemRefreshTokenKeychain()
    )

    /// Keychain key for a userId. Keep this distinct from TwitchKit's
    /// `chattr.account.{userId}` namespace so the two stores never collide.
    static func key(for userId: String) -> String {
        "chattr.refresh.\(userId)"
    }

    /// Write the refresh token. No-op if `refreshToken` is nil — we'd rather
    /// keep the previous cached value than overwrite with nothing (Twitch
    /// sometimes only rotates refresh tokens conditionally; absence in a
    /// response means "carry on with the previous one," not "we revoked it").
    static func save(
        refreshToken: String?,
        for userId: String,
        in keychain: any RefreshTokenKeychain = OAuthRefreshTokenCache.keychain
    ) {
        guard let refreshToken, !refreshToken.isEmpty else {
            logger.info("OAuthRefreshTokenCache.save called with nil/empty for \(userId, privacy: .public); skipping")
            return
        }
        guard let data = refreshToken.data(using: .utf8) else { return }
        do {
            try keychain.save(key: key(for: userId), data: data)
            logger.info("Cached refresh_token for \(userId, privacy: .public)")
        } catch {
            logger.error("Failed to cache refresh_token for \(userId, privacy: .public): \(error.localizedDescription)")
        }
    }

    /// Read the cached refresh token, returning `nil` only when no item is
    /// stored and throwing on unexpected Keychain errors (e.g.
    /// `errSecInteractionNotAllowed`) so callers can distinguish "missing"
    /// from transient Keychain unavailability.
    static func loadThrowing(
        for userId: String,
        in keychain: any RefreshTokenKeychain = OAuthRefreshTokenCache.keychain
    ) throws -> String? {
        guard let data = try keychain.load(key: key(for: userId)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Best-effort read of the cached refresh token, returning `nil` if absent
    /// or unreadable. Prefer `loadThrowing` on auth-critical paths where a
    /// transient Keychain failure must not trigger `forceSignOut`.
    static func load(
        for userId: String,
        in keychain: any RefreshTokenKeychain = OAuthRefreshTokenCache.keychain
    ) -> String? {
        try? loadThrowing(for: userId, in: keychain)
    }

    /// Off-main async variant of `loadThrowing` so real Keychain XPC calls
    /// don't stall `@MainActor`. In-memory test fakes execute inline.
    static func loadThrowingAsync(
        for userId: String,
        in keychain: any RefreshTokenKeychain = OAuthRefreshTokenCache.keychain
    ) async throws -> String? {
        guard keychain is SystemRefreshTokenKeychain else {
            return try loadThrowing(for: userId, in: keychain)
        }
        return try await Task.detached(priority: .userInitiated) {
            try loadThrowing(for: userId, in: keychain)
        }.value
    }

    /// Drop the cached refresh token (used when removing an account).
    static func delete(
        for userId: String,
        in keychain: any RefreshTokenKeychain = OAuthRefreshTokenCache.keychain
    ) {
        keychain.delete(key: key(for: userId))
        logger.info("Cleared cached refresh_token for \(userId, privacy: .public)")
    }
}

/// Minimal key→data Keychain abstraction the cache talks to. Lets tests
/// substitute an in-memory store for the real `SecItem` primitives.
protocol RefreshTokenKeychain: Sendable {
    func save(key: String, data: Data) throws
    func load(key: String) throws -> Data?
    func delete(key: String)
    /// Every key the backend holds, or `nil` when it can't be listed (the
    /// default). Used only by the orphaned-credential sweep, which does
    /// nothing on `nil`.
    func allKeys() -> [String]?
}

extension RefreshTokenKeychain {
    func allKeys() -> [String]? { nil }
}

/// Production `RefreshTokenKeychain` backed by the system Keychain.
///
/// Mirror of TwitchKit's internal `KeychainStore` — TwitchKit doesn't expose
/// its Keychain helpers publicly so we re-implement the same shape
/// (`kSecClassGenericPassword` + `kSecAttrAccount` keyed) here. Same
/// accessibility (`AfterFirstUnlockThisDeviceOnly`) so both stores have
/// identical security semantics.
struct SystemRefreshTokenKeychain: RefreshTokenKeychain {

    func save(key: String, data: Data) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif

        // Try update first (common case after a refresh).
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }

        guard updateStatus == errSecItemNotFound else {
            throw NSError(domain: "OAuthRefreshTokenCache", code: Int(updateStatus),
                          userInfo: [NSLocalizedDescriptionKey: "Keychain update failed"])
        }

        // First-time write.
        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #if os(macOS)
        addQuery[kSecUseDataProtectionKeychain as String] = true
        #endif

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw NSError(domain: "OAuthRefreshTokenCache", code: Int(addStatus),
                          userInfo: [NSLocalizedDescriptionKey: "Keychain add failed"])
        }
    }

    func load(key: String) throws -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            logger.error("Keychain load returned OSStatus \(status) for \(key, privacy: .public)")
            throw NSError(
                domain: "OAuthRefreshTokenCache",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Keychain load failed (OSStatus \(status))"]
            )
        }
        return result as? Data
    }

    func delete(key: String) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            logger.warning("Keychain delete OSStatus \(status) for \(key, privacy: .public)")
        }
    }

    /// The account name of every generic-password item this app can see.
    /// That covers TwitchKit's token entries as well as the mirrors: both
    /// are generic passwords keyed only by `kSecAttrAccount`.
    func allKeys() -> [String]? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            logger.error("Keychain listing returned OSStatus \(status)")
            return nil
        }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }
}

/// Picks out the Keychain entries that hold an account's credentials: the
/// refresh-token mirror (`OAuthRefreshTokenCache.key(for:)`) and TwitchKit's
/// token entry for the account's namespace (`KeychainTokenStore`'s key,
/// `com.twitchkit.<clientId>.<namespace>.oauthToken`). Any other key is left
/// alone.
enum OrphanedCredentials {

    /// The userId a credential key belongs to, or `nil` for a key that
    /// isn't one of ours.
    static func userId(forKey key: String, clientId: String) -> String? {
        let mirrorPrefix = OAuthRefreshTokenCache.key(for: "")
        if key.hasPrefix(mirrorPrefix) {
            let userId = String(key.dropFirst(mirrorPrefix.count))
            return userId.isEmpty ? nil : userId
        }
        let tokenPrefix = "com.twitchkit.\(clientId).\(TwitchClientCache.namespace(for: ""))"
        let tokenSuffix = ".oauthToken"
        if key.hasPrefix(tokenPrefix), key.hasSuffix(tokenSuffix),
           key.count > tokenPrefix.count + tokenSuffix.count {
            return String(key.dropFirst(tokenPrefix.count).dropLast(tokenSuffix.count))
        }
        return nil
    }

    /// The credential keys in `keys` whose userId `isOrphan` accepts.
    static func keys(
        among keys: [String],
        clientId: String,
        isOrphan: (_ userId: String) -> Bool
    ) -> [String] {
        keys.filter { key in
            guard let owner = Self.userId(forKey: key, clientId: clientId) else { return false }
            return isOrphan(owner)
        }
    }
}
