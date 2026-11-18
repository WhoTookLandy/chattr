import Testing
import Foundation
import SwiftData
import Core
@testable import Features

/// Records `onOpen` / `onClose` / `onDiscard` callbacks in order.
/// `@MainActor` (hence `Sendable`) so the `@Sendable` callbacks can capture
/// and mutate it.
@MainActor
private final class DiscardEventRecorder {
    var events: [String] = []
    var opens: [String] { events.filter { $0.hasPrefix("open") } }
    var closes: [String] { events.filter { $0.hasPrefix("close") } }
    var discards: [String] { events.filter { $0.hasPrefix("discard") } }
}

/// `ChatTabsModel.onDiscard`: a tab that leaves without its `onOpen` having
/// run gets exactly one `onDiscard` and no `onClose`; a tab whose `onOpen`
/// ran gets `onClose` and never `onDiscard`.
@MainActor
@Suite("ChatTabsModel discard")
struct ChatTabsModelDiscardTests {
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

    private func makeModel(recorder: DiscardEventRecorder, wiresOpen: Bool = true) -> ChatTabsModel {
        let model = ChatTabsModel()
        if wiresOpen {
            model.onOpen = { [recorder] tab in
                recorder.events.append("open \(tab.channels[0].channelLoginName)")
            }
        }
        model.onClose = { [recorder] tab in
            recorder.events.append("close \(tab.channels[0].channelLoginName)")
        }
        model.onDiscard = { [recorder] tab in
            recorder.events.append("discard \(tab.channels[0].channelLoginName)")
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

    @Test("Closing a restored tab before its open starts discards it once")
    func closeBeforeOpenDiscards() async throws {
        let persistence = try makePersistence()
        let tabA = ChatTab(channel: channel("a"))
        try persistence.save(tabs: [tabA, ChatTab(channel: channel("b"))])
        let recorder = DiscardEventRecorder()
        let model = makeModel(recorder: recorder)
        model.persistence = persistence
        model.hydrateFromPersistence()
        model.close(tabId: tabA.id)
        await waitUntil { recorder.events.count == 2 }
        await drain()
        #expect(recorder.events.sorted() == ["discard a", "open b"])
    }

    @Test("A tab whose open ran is closed, never discarded")
    func openedTabIsNotDiscarded() async {
        let recorder = DiscardEventRecorder()
        let model = makeModel(recorder: recorder)
        let id = model.open(channel: channel("a"))
        await waitUntil { recorder.opens.count == 1 }
        model.close(tabId: id)
        await waitUntil { recorder.closes.count == 1 }
        await drain()
        #expect(recorder.events == ["open a", "close a"])
    }

    @Test("tearDown discards tabs whose open hadn't started, exactly once")
    func tearDownDiscardsPending() async throws {
        let persistence = try makePersistence()
        try persistence.save(tabs: [ChatTab(channel: channel("a")), ChatTab(channel: channel("b"))])
        let recorder = DiscardEventRecorder()
        let model = makeModel(recorder: recorder)
        model.persistence = persistence
        model.hydrateFromPersistence()
        let releases = model.tearDown()  // before any queued open has run
        await releases?.value
        #expect(recorder.events.sorted() == ["discard a", "discard b"])

        // Neither a second teardown nor a late close discards again.
        #expect(model.tearDown() == nil)
        model.close(tabIds: model.tabs.map(\.id))
        await drain()
        #expect(recorder.events.count == 2)
    }

    @Test("tearDown's task finishes after every release has run")
    func tearDownTaskCoversReleases() async {
        let recorder = DiscardEventRecorder()
        let model = makeModel(recorder: recorder)
        model.open(channel: channel("a"))
        model.open(channel: channel("b"))
        await waitUntil { recorder.opens.count == 2 }

        await model.tearDown()?.value
        #expect(recorder.closes.sorted() == ["close a", "close b"])
        #expect(recorder.discards.isEmpty)
    }

    @Test("With no onOpen wired, a closed tab is discarded")
    func closeWithoutOpenWiredDiscards() async {
        let recorder = DiscardEventRecorder()
        let model = makeModel(recorder: recorder, wiresOpen: false)
        let id = model.open(channel: channel("a"))
        model.close(tabId: id)
        await waitUntil { recorder.events.count == 1 }
        await drain()
        #expect(recorder.events == ["discard a"])
    }

    @Test("A mixed batch close releases opened tabs and discards the rest")
    func batchCloseMixes() async throws {
        let persistence = try makePersistence()
        let restored = ["a", "b", "c", "d"].map { ChatTab(channel: channel($0)) }
        try persistence.save(tabs: restored)
        let recorder = DiscardEventRecorder()
        let (gate, openGate) = AsyncStream<Void>.makeStream()
        let model = ChatTabsModel()
        model.onOpen = { [recorder] tab in
            let name = tab.channels[0].channelLoginName
            recorder.events.append("open \(name)")
            // "a" holds its slot, so "d" (queued behind it) can't start.
            if name == "a" {
                for await _ in gate { break }
            }
        }
        model.onClose = { [recorder] tab in
            recorder.events.append("close \(tab.channels[0].channelLoginName)")
        }
        model.onDiscard = { [recorder] tab in
            recorder.events.append("discard \(tab.channels[0].channelLoginName)")
        }
        model.persistence = persistence
        model.hydrateFromPersistence()
        await waitUntil { recorder.opens.count == 3 }

        model.close(tabIds: [restored[1].id, restored[3].id])
        openGate.yield(())
        openGate.finish()
        await waitUntil { recorder.closes.count + recorder.discards.count == 2 }
        await drain()
        #expect(recorder.closes == ["close b"])
        #expect(recorder.discards == ["discard d"])
        #expect(recorder.opens.sorted() == ["open a", "open b", "open c"])
    }
}
