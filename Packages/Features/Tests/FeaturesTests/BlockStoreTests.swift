import Testing
import Foundation
import Accounts
import SwiftData
@testable import Features

@MainActor
@Suite("BlockStore")
struct BlockStoreTests {
    private func makeStore(suite: String) -> BlockStore {
        let container = try! ModelContainer(
            for: Account.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let accountStore = AccountStore(modelContainer: container, clientId: "test")
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return BlockStore(accountUserId: "u1", accountStore: accountStore, defaults: defaults)
    }

    @Test("reconcile replaces the set and isBlocked reflects it")
    func reconcileReplaces() {
        let store = makeStore(suite: "block.test.reconcile")
        store.reconcile(with: [BlockedChatter(id: "x", login: "x", displayName: "X")])
        #expect(store.isBlocked("x"))
        #expect(!store.isBlocked("y"))
        store.reconcile(with: [BlockedChatter(id: "y", login: "y", displayName: "Y")])
        #expect(!store.isBlocked("x"))
        #expect(store.isBlocked("y"))
    }

    @Test("persisted set is reloaded by a fresh store on the same defaults")
    func persistenceRoundTrip() {
        let suite = "block.test.persist"
        let store = makeStore(suite: suite)
        store.reconcile(with: [BlockedChatter(id: "x", login: "x", displayName: "X")])
        let container = try! ModelContainer(
            for: Account.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let accountStore = AccountStore(modelContainer: container, clientId: "test")
        let reloaded = BlockStore(
            accountUserId: "u1",
            accountStore: accountStore,
            defaults: UserDefaults(suiteName: suite)!
        )
        #expect(reloaded.isBlocked("x"))
    }
}
