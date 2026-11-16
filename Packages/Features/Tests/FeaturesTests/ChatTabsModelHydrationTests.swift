import Testing
import Foundation
import SwiftData
import Core
@testable import Features

@MainActor
@Suite("ChatTabsModel.hydrateFromPersistence")
struct ChatTabsModelHydrationTests {
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

    private func makePersistence(account: String = "account-a") throws -> TabPersistence {
        TabPersistence(modelContainer: try makeContainer(), accountUserId: account)
    }

    /// The fix: a second `hydrateFromPersistence()` on the same model is a
    /// no-op. We prove it by mutating what's on disk between the two calls —
    /// the second hydrate must NOT pick up the change. Without the
    /// `hasHydrated` guard the second call would reset `tabs` to the new
    /// disk state (the churn that fed the detach race).
    @Test("Second hydrate on the same model is a no-op")
    func secondHydrateIsNoOp() throws {
        let persistence = try makePersistence()
        let tabA = ChatTab(channel: channel("a"))
        let tabB = ChatTab(channel: channel("b"))

        // Disk starts with just [a].
        try persistence.save(tabs: [tabA])

        let model = ChatTabsModel()
        model.persistence = persistence
        model.hydrateFromPersistence()
        #expect(model.tabs.count == 1)
        #expect(model.tabs.first?.channels.first?.channelLoginName == "a")

        // Disk now holds [a, b]; a re-fired hydrate must ignore it.
        try persistence.save(tabs: [tabA, tabB])
        model.hydrateFromPersistence()
        #expect(model.tabs.count == 1)
        #expect(model.tabs.first?.channels.first?.channelLoginName == "a")
    }

    /// Control: the guard is per-model-instance, so a fresh model (the real
    /// account-swap path — AppShell is `.id(userId)`) DOES hydrate the
    /// current disk state.
    @Test("A fresh model hydrates the current disk state")
    func freshModelHydrates() throws {
        let persistence = try makePersistence()
        let tabA = ChatTab(channel: channel("a"))
        let tabB = ChatTab(channel: channel("b"))
        try persistence.save(tabs: [tabA, tabB])

        let model = ChatTabsModel()
        model.persistence = persistence
        model.hydrateFromPersistence()
        #expect(model.tabs.count == 2)
    }

    // MARK: - Account scoping

    @Test("Each account restores only its own tabs")
    func tabsAreAccountScoped() throws {
        let container = try makeContainer()
        let persistenceA = TabPersistence(modelContainer: container, accountUserId: "account-a")
        let persistenceB = TabPersistence(modelContainer: container, accountUserId: "account-b")
        let tabA = ChatTab(channel: channel("a"))
        let tabB = ChatTab(channel: channel("b"))
        try persistenceA.save(tabs: [tabA])
        try persistenceB.save(tabs: [tabB])

        let modelB = ChatTabsModel()
        modelB.persistence = persistenceB
        modelB.hydrateFromPersistence()
        #expect(modelB.tabs.map(\.id) == [tabB.id])

        // B emptying its strip must not touch A's rows.
        try persistenceB.save(tabs: [])
        #expect(try persistenceA.fetchAll().map(\.id) == [tabA.id])
        #expect(try persistenceB.fetchAll().isEmpty)
    }

    @Test("Saving reorders and updates rows in place")
    func saveUpserts() throws {
        let persistence = try makePersistence()
        let tabA = ChatTab(channel: channel("a"))
        let tabB = ChatTab(channel: channel("b"))
        let tabC = ChatTab(channel: channel("c"))
        try persistence.save(tabs: [tabA, tabB, tabC])
        try persistence.save(tabs: [tabC, tabA])

        let rows = try persistence.fetchAll()
        #expect(rows.map(\.id) == [tabC.id, tabA.id])
        #expect(rows.map(\.order) == [0, 1])
    }

    /// Migration contract: rows from before `AppSchemaV2` have an empty
    /// `accountUserId`. The first account to hydrate adopts them; a later
    /// account doesn't see them.
    @Test("Legacy unowned rows are adopted by the first account that hydrates")
    func legacyRowsAdopted() throws {
        let container = try makeContainer()
        let legacyTab = ChatTab(channel: channel("legacy"))
        container.mainContext.insert(
            PersistedChatTab(from: legacyTab, order: 0, accountUserId: "")
        )
        try container.mainContext.save()

        let persistenceA = TabPersistence(modelContainer: container, accountUserId: "account-a")
        let modelA = ChatTabsModel()
        modelA.persistence = persistenceA
        modelA.hydrateFromPersistence()
        #expect(modelA.tabs.map(\.id) == [legacyTab.id])
        #expect(try persistenceA.fetchAll().map(\.accountUserId) == ["account-a"])

        let persistenceB = TabPersistence(modelContainer: container, accountUserId: "account-b")
        #expect(try persistenceB.fetchAll().isEmpty)
    }

    @Test("Rows with no channels are skipped at hydrate and pruned by the next save")
    func corruptRowsSkipped() throws {
        let container = try makeContainer()
        let persistence = TabPersistence(modelContainer: container, accountUserId: "account-a")
        let good = ChatTab(channel: channel("good"))
        try persistence.save(tabs: [good])
        container.mainContext.insert(
            PersistedChatTab(id: UUID(), order: 1, channels: [], accountUserId: "account-a")
        )
        try container.mainContext.save()

        let model = ChatTabsModel()
        model.persistence = persistence
        model.hydrateFromPersistence()
        #expect(model.tabs.map(\.id) == [good.id])

        // Any mutation re-saves the strip, dropping the corrupt row.
        let added = model.open(channel: channel("added"))
        #expect(try persistence.fetchAll().map(\.id) == [good.id, added])
    }
}
