import Testing
import Foundation
import SwiftData
import Core
@testable import Features

/// Cleanup of the per-account state Features persists, run when an account
/// is removed (`AccountStore.onAccountRemoved` → `AccountLocalData.remove`).
@MainActor
@Suite("AccountLocalData / TabPersistence.deleteAll")
struct AccountLocalDataTests {
    private func channel(_ name: String) -> ChannelDescriptor {
        ChannelDescriptor(
            channelId: name, channelLoginName: name,
            channelDisplayName: name, profileImageURL: nil
        )
    }

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: PersistedChatTab.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    @Test("deleteAll removes only the owning account's rows")
    func deleteAllIsAccountScoped() throws {
        let container = try makeContainer()
        let a = TabPersistence(modelContainer: container, accountUserId: "account-a")
        let b = TabPersistence(modelContainer: container, accountUserId: "account-b")
        try a.save(tabs: [ChatTab(channel: channel("a1")), ChatTab(channel: channel("a2"))])
        try b.save(tabs: [ChatTab(channel: channel("b1"))])

        try a.deleteAll()

        #expect(try a.fetchAll().isEmpty)
        #expect(try b.fetchAll().map { $0.channels.first?.channelLoginName } == ["b1"])
    }

    @Test("remove drops the account's tabs and drafts")
    func removeDropsTabsAndDrafts() throws {
        let container = try makeContainer()
        let userId = "localdata-\(UUID().uuidString)"
        let other = "localdata-other-\(UUID().uuidString)"
        let descriptor = channel("x")
        let tabs = TabPersistence(modelContainer: container, accountUserId: userId)
        let otherTabs = TabPersistence(modelContainer: container, accountUserId: other)
        try tabs.save(tabs: [ChatTab(channel: descriptor)])
        try otherTabs.save(tabs: [ChatTab(channel: descriptor)])
        // Synchronous from here to the reset, so no other @MainActor test
        // observes the switched draft scope (see DraftStorageTests).
        DraftStorage.setActiveAccount(userId)
        DraftStorage.save(forChannel: descriptor.id, text: "draft")
        DraftStorage.setActiveAccount(nil)
        if let recent = RecentSearchItem.channel(id: "1", login: "x", displayName: "x", profileImageURL: nil) {
            SearchHistoryStorage.record(recent, forAccount: userId)
            SearchHistoryStorage.record(recent, forAccount: other)
        }

        AccountLocalData.remove(forAccountUserId: userId, modelContainer: container)

        #expect(try tabs.fetchAll().isEmpty)
        #expect(try otherTabs.fetchAll().count == 1)
        #expect(UserDefaults.standard.object(forKey: DraftStorage.storageKey(forAccount: userId)) == nil)
        #expect(SearchHistoryStorage.load(forAccount: userId).isEmpty)
        #expect(SearchHistoryStorage.load(forAccount: other).count == 1)
        SearchHistoryStorage.clear(forAccount: other)
    }
}
