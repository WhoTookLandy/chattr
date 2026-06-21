import Testing
import Foundation
@testable import Accounts

/// In-memory `RefreshTokenKeychain` so the cache's namespacing + guard logic
/// is testable without the system Keychain. A plain SwiftPM test bundle has no
/// Keychain entitlement on the simulator (`SecItem` → `errSecMissingEntitlement`,
/// OSStatus -34018), so the real backend can't be exercised here — the seam is.
final class InMemoryRefreshTokenKeychain: RefreshTokenKeychain, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]

    func save(key: String, data: Data) throws { lock.withLock { storage[key] = data } }
    func load(key: String) -> Data? { lock.withLock { storage[key] } }
    func delete(key: String) { lock.withLock { _ = storage.removeValue(forKey: key) } }

    /// Test-only: did anything get written under this exact key?
    func contains(key: String) -> Bool { lock.withLock { storage[key] != nil } }
}

/// Coverage for the chattr-side refresh-token cache — the recovery store that
/// keeps a user signed in when TwitchKit's own store gets wiped by a failed
/// auto-refresh (see `OAuthRefreshTokenCache` header).
@Suite("OAuthRefreshTokenCache (logic over injected backend)", .serialized)
struct OAuthRefreshTokenCacheTests {

    /// Installs a fresh in-memory backend, runs `body`, then restores the real
    /// system backend. `.serialized` ensures no overlap on the shared seam.
    private func withFakeKeychain(_ body: (InMemoryRefreshTokenKeychain) -> Void) {
        let fake = InMemoryRefreshTokenKeychain()
        let previous = OAuthRefreshTokenCache.keychain
        OAuthRefreshTokenCache.keychain = fake
        defer { OAuthRefreshTokenCache.keychain = previous }
        body(fake)
    }

    @Test("save then load returns the same token")
    func saveLoad() {
        withFakeKeychain { _ in
            OAuthRefreshTokenCache.save(refreshToken: "rt-123", for: "42")
            #expect(OAuthRefreshTokenCache.load(for: "42") == "rt-123")
        }
    }

    @Test("entries are namespaced chattr.refresh.<userId>, distinct from TwitchKit's")
    func namespacing() {
        withFakeKeychain { fake in
            OAuthRefreshTokenCache.save(refreshToken: "rt", for: "42")
            #expect(fake.contains(key: "chattr.refresh.42"))
            // Must never collide with TwitchKit's chattr.account.<id> store.
            #expect(!fake.contains(key: "chattr.account.42"))
        }
    }

    @Test("load for an unknown user returns nil")
    func loadUnknown() {
        withFakeKeychain { _ in
            #expect(OAuthRefreshTokenCache.load(for: "nobody") == nil)
        }
    }

    @Test("save overwrites the previous value")
    func overwrite() {
        withFakeKeychain { _ in
            OAuthRefreshTokenCache.save(refreshToken: "first", for: "42")
            OAuthRefreshTokenCache.save(refreshToken: "second", for: "42")
            #expect(OAuthRefreshTokenCache.load(for: "42") == "second")
        }
    }

    @Test("save(nil) does not overwrite an existing value")
    func saveNilKeepsPrevious() {
        // Twitch omits refresh_token when it doesn't rotate it; absence means
        // "keep the old one," never "revoke it" — so nil must be a no-op.
        withFakeKeychain { _ in
            OAuthRefreshTokenCache.save(refreshToken: "keep", for: "42")
            OAuthRefreshTokenCache.save(refreshToken: nil, for: "42")
            #expect(OAuthRefreshTokenCache.load(for: "42") == "keep")
        }
    }

    @Test("save(\"\") is a no-op")
    func saveEmptyIsNoop() {
        withFakeKeychain { _ in
            OAuthRefreshTokenCache.save(refreshToken: "", for: "42")
            #expect(OAuthRefreshTokenCache.load(for: "42") == nil)
        }
    }

    @Test("delete removes the cached token")
    func deleteRemoves() {
        withFakeKeychain { _ in
            OAuthRefreshTokenCache.save(refreshToken: "rt", for: "42")
            OAuthRefreshTokenCache.delete(for: "42")
            #expect(OAuthRefreshTokenCache.load(for: "42") == nil)
        }
    }
}
