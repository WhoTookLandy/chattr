import Testing
import SwiftData
import Foundation
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

    @Test("activeAccount returns nil when no active set")
    func noActiveByDefault() async throws {
        let container = try Self.makeContainer()
        let store = AccountStore(modelContainer: container, clientId: "test-client")
        let active = try await store.activeAccount()
        #expect(active == nil)
    }

    @Test("namespace produces stable identifier per userId")
    func namespaceStable() {
        #expect(AccountStore.namespace(for: "42") == "chattr.account.42")
        #expect(AccountStore.namespace(for: "71092938") == "chattr.account.71092938")
    }
}
