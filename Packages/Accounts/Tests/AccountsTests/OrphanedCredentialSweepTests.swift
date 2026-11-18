import Testing
import Foundation
import SwiftData
import os
@testable import Accounts

/// A backend that can't be listed: it keeps the protocol's default
/// `allKeys()`, which answers `nil`.
private final class UnlistableKeychain: RefreshTokenKeychain {
    private let storage = OSAllocatedUnfairLock<[String: Data]>(initialState: [:])

    func save(key: String, data: Data) throws { storage.withLock { $0[key] = data } }
    func load(key: String) -> Data? { storage.withLock { $0[key] } }
    func delete(key: String) { storage.withLock { _ = $0.removeValue(forKey: key) } }
}

@Suite("Orphaned credential sweep")
@MainActor
struct OrphanedCredentialSweepTests {

    private static let clientId = "sweep-client"

    private static func mirrorKey(_ userId: String) -> String {
        OAuthRefreshTokenCache.key(for: userId)
    }

    /// The key TwitchKit's `KeychainTokenStore` uses for an account.
    private static func tokenKey(_ userId: String) -> String {
        "com.twitchkit.\(clientId).\(AccountStore.namespace(for: userId)).oauthToken"
    }

    private struct Harness {
        let store: AccountStore
        let container: ModelContainer
        let defaults: UserDefaults
        let suite: String
    }

    private static func makeHarness(keychain: any RefreshTokenKeychain) throws -> Harness {
        let container = try ModelContainer(
            for: Account.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let suite = "chattr.tests.sweep.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = AccountStore(
            modelContainer: container,
            clientId: clientId,
            defaults: defaults,
            bridgeRefresh: BridgeTokenRefresh(),
            refreshTokenKeychain: keychain
        )
        return Harness(store: store, container: container, defaults: defaults, suite: suite)
    }

    private static func insertAccount(_ userId: String, needsReauth: Bool = false, into container: ModelContainer) throws {
        let account = Account(
            userId: userId,
            login: "login\(userId)",
            displayName: "Name\(userId)",
            profileImageURL: "",
            tokenNamespace: AccountStore.namespace(for: userId)
        )
        account.needsReauth = needsReauth
        container.mainContext.insert(account)
        try container.mainContext.save()
    }

    @Test("Credential keys map back to their userId; anything else is not ours")
    func keyParsing() {
        let clientId = Self.clientId
        #expect(OrphanedCredentials.userId(forKey: "chattr.refresh.42", clientId: clientId) == "42")
        #expect(OrphanedCredentials.userId(forKey: Self.tokenKey("42"), clientId: clientId) == "42")
        // Another app's client id, TwitchKit's un-namespaced entry, an empty
        // userId and unrelated items are all left alone.
        #expect(OrphanedCredentials.userId(forKey: Self.tokenKey("42"), clientId: "other-client") == nil)
        #expect(OrphanedCredentials.userId(forKey: "com.twitchkit.\(clientId).default.oauthToken", clientId: clientId) == nil)
        #expect(OrphanedCredentials.userId(forKey: "chattr.refresh.", clientId: clientId) == nil)
        #expect(OrphanedCredentials.userId(forKey: "com.twitchkit.\(clientId).chattr.account..oauthToken", clientId: clientId) == nil)
        #expect(OrphanedCredentials.userId(forKey: "some.other.item", clientId: clientId) == nil)
    }

    @Test("The sweep deletes entries with no account row and nothing else")
    func sweepDeletesOnlyOrphans() async throws {
        let keychain = InMemoryRefreshTokenKeychain()
        let h = try Self.makeHarness(keychain: keychain)
        defer { h.defaults.removePersistentDomain(forName: h.suite) }
        try Self.insertAccount("1", into: h.container)
        try Self.insertAccount("2", needsReauth: true, into: h.container)
        let kept = [
            Self.mirrorKey("1"), Self.tokenKey("1"),
            Self.mirrorKey("2"), Self.tokenKey("2"),
            "some.other.item",
        ]
        let orphaned = [Self.mirrorKey("3"), Self.tokenKey("3"), Self.mirrorKey("4")]
        for key in kept + orphaned {
            try keychain.save(key: key, data: Data("x".utf8))
        }

        await h.store.sweepOrphanedCredentials()

        for key in kept {
            #expect(keychain.contains(key: key), "\(key) should have been kept")
        }
        for key in orphaned {
            #expect(!keychain.contains(key: key), "\(key) should have been deleted")
        }
    }

    @Test("An account seen this launch keeps its entries even without a row yet")
    func accountSeenThisLaunchIsKept() async throws {
        let keychain = InMemoryRefreshTokenKeychain()
        let h = try Self.makeHarness(keychain: keychain)
        defer { h.defaults.removePersistentDomain(forName: h.suite) }
        // A sign-in in progress has built the account's client (and token
        // gate) but not inserted its row.
        _ = h.store.client(forUserId: "5")
        try keychain.save(key: Self.mirrorKey("5"), data: Data("x".utf8))
        try keychain.save(key: Self.tokenKey("5"), data: Data("x".utf8))

        await h.store.sweepOrphanedCredentials()

        #expect(keychain.contains(key: Self.mirrorKey("5")))
        #expect(keychain.contains(key: Self.tokenKey("5")))
    }

    @Test("A backend that can't be listed is left untouched")
    func unlistableBackendIsLeftAlone() async throws {
        let keychain = UnlistableKeychain()
        let h = try Self.makeHarness(keychain: keychain)
        defer { h.defaults.removePersistentDomain(forName: h.suite) }
        try keychain.save(key: Self.mirrorKey("3"), data: Data("x".utf8))

        await h.store.sweepOrphanedCredentials()

        #expect(keychain.load(key: Self.mirrorKey("3")) != nil)
    }
}
