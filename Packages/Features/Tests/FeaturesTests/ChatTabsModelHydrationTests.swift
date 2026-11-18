import Testing
import Foundation
import SwiftData
import Core
@testable import Features

/// Holds each `onOpen` until released, and counts how many are held at once.
@MainActor
private final class HydrationOpenGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var started: [String] = []
    private(set) var inFlight = 0
    private(set) var maxInFlight = 0
    private(set) var finished = 0

    var hasWaiter: Bool { !waiters.isEmpty }

    func enter(_ name: String) async {
        started.append(name)
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        await withCheckedContinuation { waiters.append($0) }
        inFlight -= 1
        finished += 1
    }

    func releaseOne() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume()
    }
}

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

    // MARK: - Open order

    @Test("Opens are ordered outward from the tab being shown")
    func outwardOrder() {
        #expect(ChatTabsModel.outwardOrder(count: 5, from: 2) == [2, 3, 1, 4, 0])
        #expect(ChatTabsModel.outwardOrder(count: 4, from: 0) == [0, 1, 2, 3])
        #expect(ChatTabsModel.outwardOrder(count: 4, from: 3) == [3, 2, 1, 0])
        #expect(ChatTabsModel.outwardOrder(count: 1, from: 0) == [0])
        #expect(ChatTabsModel.outwardOrder(count: 0, from: 0).isEmpty)
        // An out-of-range center is clamped rather than trapping.
        #expect(ChatTabsModel.outwardOrder(count: 3, from: 9) == [2, 1, 0])
    }

    /// Yields until `condition` holds (bounded, so a bug fails the following
    /// `#expect` instead of hanging).
    private func waitUntil(_ condition: () -> Bool) async {
        var remaining = 1_000
        while !condition(), remaining > 0 {
            await Task.yield()
            remaining -= 1
        }
    }

    @Test("Restored tabs open at most three at a time, starting with the tab being shown")
    func hydrationOpensAreBounded() async throws {
        let persistence = try makePersistence()
        let tabs = ["a", "b", "c", "d", "e", "f", "g"].map { ChatTab(channel: channel($0)) }
        try persistence.save(tabs: tabs)
        let gate = HydrationOpenGate()
        let model = ChatTabsModel()
        model.onOpen = { [gate] tab in
            await gate.enter(tab.channels[0].channelLoginName)
        }
        model.persistence = persistence
        model.hydrateFromPersistence(openingFirst: tabs[3].id)
        #expect(model.tabs.map(\.id) == tabs.map(\.id))

        // The shown tab and its two neighbours go first; nothing else starts
        // while they are in flight.
        await waitUntil { gate.started.count >= 3 }
        for _ in 0..<50 { await Task.yield() }
        #expect(Set(gate.started) == ["d", "e", "c"])
        #expect(gate.inFlight == 3)

        // Each finished open frees one slot for the next tab outward.
        for finished in 1...tabs.count {
            await waitUntil { gate.hasWaiter }
            gate.releaseOne()
            await waitUntil { gate.finished == finished }
        }
        #expect(Set(gate.started) == ["a", "b", "c", "d", "e", "f", "g"])
        #expect(gate.started.count == tabs.count)
        #expect(gate.maxInFlight == ChatTabsModel.hydrationOpenLimit)
    }

    @Test("A restored tab closed while it waits for a slot never opens")
    func closedWhileQueuedNeverOpens() async throws {
        let persistence = try makePersistence()
        let tabs = ["a", "b", "c", "d"].map { ChatTab(channel: channel("queued-\($0)-\(UUID().uuidString)")) }
        try persistence.save(tabs: tabs)
        let gate = HydrationOpenGate()
        let model = ChatTabsModel()
        model.onOpen = { [gate] tab in
            await gate.enter(tab.channels[0].channelLoginName)
        }
        model.persistence = persistence
        model.hydrateFromPersistence()
        await waitUntil { gate.started.count >= 3 }

        // The fourth tab is queued behind the first; close it, then let
        // everything through.
        let queued = tabs[3]
        model.close(tabId: queued.id)
        for finished in 1...3 {
            await waitUntil { gate.hasWaiter }
            gate.releaseOne()
            await waitUntil { gate.finished == finished }
        }
        for _ in 0..<50 { await Task.yield() }
        #expect(gate.started.count == 3)
        #expect(!gate.started.contains(queued.channels[0].channelLoginName))
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
