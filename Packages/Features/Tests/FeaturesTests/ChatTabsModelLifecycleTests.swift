import Testing
import Foundation
import SwiftData
import Core
@testable import Features

/// Records `onOpen` / `onClose` callbacks in order. `@MainActor` (hence
/// `Sendable`) so the `@Sendable` callbacks can capture and mutate it.
@MainActor
private final class TabEventRecorder {
    var events: [String] = []
    var opens: [String] { events.filter { $0.hasPrefix("open") } }
    var closes: [String] { events.filter { $0.hasPrefix("close") } }
}

/// Open/close balance for `ChatTabsModel`: every `onOpen` that runs gets
/// exactly one `onClose` (via `close` or `tearDown`), never before the open
/// finishes, and a tab whose open never ran is never closed.
@MainActor
@Suite("ChatTabsModel open/close lifecycle")
struct ChatTabsModelLifecycleTests {
    private func channel(_ name: String) -> ChannelDescriptor {
        // Unique id so draft pruning in `close` can't collide with other
        // suites' UserDefaults entries.
        ChannelDescriptor(
            channelId: "\(name)-\(UUID().uuidString)", channelLoginName: name,
            channelDisplayName: name, profileImageURL: nil
        )
    }

    private func makePersistence() throws -> TabPersistence {
        let container = try ModelContainer(
            for: PersistedChatTab.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return TabPersistence(modelContainer: container, accountUserId: "account-a")
    }

    /// Wires recording callbacks that log `open <login>` / `close <login>`.
    private func makeModel(recorder: TabEventRecorder) -> ChatTabsModel {
        let model = ChatTabsModel()
        model.onOpen = { [recorder] tab in
            recorder.events.append("open \(tab.channels[0].channelLoginName)")
        }
        model.onClose = { [recorder] tab in
            recorder.events.append("close \(tab.channels[0].channelLoginName)")
        }
        return model
    }

    /// Lets queued main-actor tasks (opens, chained hydration, releases) run.
    private func drain() async {
        for _ in 0..<50 { await Task.yield() }
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

    @Test("tearDown releases every opened tab exactly once")
    func tearDownReleasesOnce() async {
        let recorder = TabEventRecorder()
        let model = makeModel(recorder: recorder)
        let a = channel("a")
        model.open(channel: a)
        model.open(channel: channel("b"))
        await waitUntil { recorder.opens.count == 2 }
        #expect(recorder.opens == ["open a", "open b"])

        model.tearDown()
        await waitUntil { recorder.closes.count == 2 }
        #expect(Set(recorder.closes) == ["close a", "close b"])

        // Neither a second teardown nor a late close releases again.
        model.tearDown()
        if let tabA = model.tabs.first(where: { $0.channels[0] == a }) {
            model.close(tabId: tabA.id)
        }
        await drain()
        #expect(recorder.closes.count == 2)
    }

    @Test("tearDown skips hydration opens that haven't started; re-hydrate re-acquires")
    func tearDownCancelsPendingHydration() async throws {
        let persistence = try makePersistence()
        try persistence.save(tabs: [ChatTab(channel: channel("a")), ChatTab(channel: channel("b"))])
        let recorder = TabEventRecorder()
        let model = makeModel(recorder: recorder)
        model.persistence = persistence
        model.hydrateFromPersistence()
        model.tearDown()  // before any queued open has run
        await drain()
        #expect(recorder.events.isEmpty)
        #expect(model.persistence == nil)

        // Reversible: AppShell re-wiring on re-appearance restores.
        model.persistence = persistence
        model.hydrateFromPersistence()
        await waitUntil { recorder.opens.count == 2 }
        // Restored tabs open side by side, so only the set is fixed.
        #expect(recorder.events.sorted() == ["open a", "open b"])
    }

    @Test("Closing a restored tab before its open starts skips both open and close")
    func closeBeforeHydratedOpen() async throws {
        let persistence = try makePersistence()
        let tabA = ChatTab(channel: channel("a"))
        try persistence.save(tabs: [tabA, ChatTab(channel: channel("b"))])
        let recorder = TabEventRecorder()
        let model = makeModel(recorder: recorder)
        model.persistence = persistence
        model.hydrateFromPersistence()
        model.close(tabId: tabA.id)
        await waitUntil { recorder.opens.count == 1 }
        await drain()
        #expect(recorder.events == ["open b"])
    }

    /// The hydration-close leak: closing a restored tab while its acquire is
    /// in flight must wait for the acquire, then release — never release
    /// first (which would leave the session running forever).
    @Test("Closing a restored tab mid-open releases only after the open finishes")
    func closeDuringHydratedOpen() async throws {
        let persistence = try makePersistence()
        let tabA = ChatTab(channel: channel("a"))
        try persistence.save(tabs: [tabA])
        let recorder = TabEventRecorder()
        let (gate, openGate) = AsyncStream<Void>.makeStream()
        let model = ChatTabsModel()
        model.onOpen = { [recorder] _ in
            recorder.events.append("open-start")
            for await _ in gate { break }
            recorder.events.append("open-end")
        }
        model.onClose = { [recorder] _ in
            recorder.events.append("close")
        }
        model.persistence = persistence
        model.hydrateFromPersistence()
        await waitUntil { recorder.events == ["open-start"] }

        model.close(tabId: tabA.id)
        await drain()
        #expect(recorder.events == ["open-start"])

        openGate.yield(())
        openGate.finish()
        await waitUntil { recorder.events.count == 3 }
        #expect(recorder.events == ["open-start", "open-end", "close"])
    }

    @Test("Batch close removes every tab, persists once, and releases each")
    func batchClose() async throws {
        let persistence = try makePersistence()
        let recorder = TabEventRecorder()
        let model = makeModel(recorder: recorder)
        model.persistence = persistence
        let a = model.open(channel: channel("a"))
        let b = model.open(channel: channel("b"))
        let c = model.open(channel: channel("c"))
        await waitUntil { recorder.opens.count == 3 }

        model.close(tabIds: [b, c])
        #expect(model.tabs.map(\.id) == [a])
        #expect(model.activeTabId == a)
        #expect(try persistence.fetchAll().map(\.id) == [a])
        await waitUntil { recorder.closes.count == 2 }
        #expect(Set(recorder.closes) == ["close b", "close c"])
    }

    @Test("Closing a channel's last tab prunes its draft; another open tab keeps it")
    func closePrunesDraftOfLastTab() {
        let shared = channel("shared")
        defer { DraftStorage.remove(forChannels: [shared.id]) }
        let model = ChatTabsModel()
        let first = ChatTab(channel: shared)
        let second = ChatTab(channel: shared)
        model.open(first)
        model.open(second)
        DraftStorage.save(forChannel: shared.id, text: "draft")

        model.close(tabId: first.id)
        #expect(DraftStorage.load(forChannel: shared.id) == "draft")

        model.close(tabId: second.id)
        #expect(DraftStorage.load(forChannel: shared.id) == "")
    }
}
