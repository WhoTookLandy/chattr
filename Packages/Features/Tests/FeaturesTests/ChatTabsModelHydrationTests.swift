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

    private func makePersistence() throws -> TabPersistence {
        let container = try ModelContainer(
            for: PersistedChatTab.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return TabPersistence(modelContainer: container)
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
}
