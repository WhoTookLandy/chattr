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
/// ## Trust model
///
/// Same hardware-backed Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`)
/// as TwitchKit's own store — same protection class, same per-device scope.
/// The cache holds *only* the refresh_token, never the access_token (access
/// tokens are short-lived and cheap to re-acquire; refresh tokens are the
/// long-lived credential worth protecting).
enum OAuthRefreshTokenCache {

    /// Keychain key for a userId. Keep this distinct from TwitchKit's
    /// `chattr.account.{userId}` namespace so the two stores never collide.
    private static func key(for userId: String) -> String {
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
            try Self.keychainSave(key: key(for: userId), data: data)
            logger.info("Cached refresh_token for \(userId, privacy: .public)")
        } catch {
            logger.error("Failed to cache refresh_token for \(userId, privacy: .public): \(error.localizedDescription)")
        }
    }

    /// Read the cached refresh token, or nil if none stored.
    static func load(for userId: String) -> String? {
        guard let data = Self.keychainLoad(key: key(for: userId)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Drop the cached refresh token (used when removing an account).
    static func delete(for userId: String) {
        Self.keychainDelete(key: key(for: userId))
        logger.info("Cleared cached refresh_token for \(userId, privacy: .public)")
    }

    // MARK: - Keychain primitives
    //
    // Mirror of TwitchKit's internal `KeychainStore` — TwitchKit doesn't
    // expose its Keychain helpers publicly so we re-implement the same
    // shape (`kSecClassGenericPassword` + `kSecAttrAccount` keyed) here.
    // Same accessibility (`AfterFirstUnlockThisDeviceOnly`) so both stores
    // have identical security semantics.

    private static func keychainSave(key: String, data: Data) throws {
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

    private static func keychainLoad(key: String) -> Data? {
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

    private static func keychainDelete(key: String) {
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
