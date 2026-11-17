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
    static func save(refreshToken: String?, for userId: String) {
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

    /// Read the cached refresh token, or nil if none stored.
    static func load(for userId: String) -> String? {
        guard let data = keychain.load(key: key(for: userId)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Drop the cached refresh token (used when removing an account).
    static func delete(for userId: String) {
        keychain.delete(key: key(for: userId))
        logger.info("Cleared cached refresh_token for \(userId, privacy: .public)")
    }
}

/// Minimal key→data Keychain abstraction the cache talks to. Lets tests
/// substitute an in-memory store for the real `SecItem` primitives.
protocol RefreshTokenKeychain: Sendable {
    func save(key: String, data: Data) throws
    func load(key: String) -> Data?
    func delete(key: String)
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

    func load(key: String) -> Data? {
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
            return nil
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
}
