import Testing
import SwiftData
import Foundation
import Core
@testable import Accounts

@Suite("AccountStore (SwiftData persistence)")
@MainActor
struct AccountStoreTests {

    /// In-memory ModelContainer for isolated tests.
    private static func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: Account.self, configurations: config)
    }

    @Test("allAccounts returns empty initially")
    func emptyInitially() async throws {
        let container = try Self.makeContainer()
        let store = AccountStore(modelContainer: container, clientId: "test-client")
        let all = try await store.allAccounts()
        #expect(all.isEmpty)
    }

    @Test("namespace produces stable identifier per userId")
    func namespaceStable() {
        #expect(AccountStore.namespace(for: "42") == "chattr.account.42")
        #expect(AccountStore.namespace(for: "71092938") == "chattr.account.71092938")
    }

    // MARK: - Per-platform behavior

    @Test("Twitch active-account key is the legacy unsuffixed key")
    func twitchKeyIsLegacy() {
        // Load-bearing for migration: existing devices stored their
        // selection under the bare key before platforms existed. If this
        // ever changes, those devices silently lose their selection.
        #expect(AccountStore.activeAccountKey(for: .twitch) == AccountStore.activeAccountUserIdKey)
        #expect(AccountStore.activeAccountKey(for: .twitch) == "chattr.activeAccountUserId")
    }

    @Test("Account defaults to twitch platform")
    func accountDefaultsToTwitch() {
        let account = Account(
            userId: "42",
            login: "landy",
            displayName: "Landy",
            profileImageURL: "",
            tokenNamespace: "chattr.account.42"
        )
        #expect(account.platform == .twitch)
        #expect(account.platformRaw == "twitch")
    }

    @Test("Account.platform falls back to twitch on unknown raw value")
    func unknownPlatformRawFallsBack() {
        let account = Account(
            userId: "42",
            login: "landy",
            displayName: "Landy",
            profileImageURL: "",
            tokenNamespace: "chattr.account.42"
        )
        // Simulates a row written by a future build whose platform this
        // build doesn't know about.
        account.platformRaw = "somefutureplatform"
        #expect(account.platform == .twitch)
    }

    @Test("allAccounts(on:) filters by platform")
    func allAccountsFiltersByPlatform() async throws {
        let container = try Self.makeContainer()
        let store = AccountStore(modelContainer: container, clientId: "test-client")
        let context = ModelContext(container)
        context.insert(Account(
            userId: "1",
            platform: .twitch,
            login: "a",
            displayName: "A",
            profileImageURL: "",
            tokenNamespace: "chattr.account.1"
        ))
        try context.save()

        let twitch = try await store.allAccounts(on: .twitch)
        #expect(twitch.count == 1)
        #expect(twitch.first?.userId == "1")
    }
}
