import Testing
import Foundation
import Core
@testable import Features

@Suite("Activity inbox")
@MainActor
struct ActivityStoreTests {

    private let channel = ChannelDescriptor(
        channelId: "1", channelLoginName: "soochu", channelDisplayName: "Soochu", profileImageURL: nil
    )

    private func entry(_ id: String, at seconds: TimeInterval, reason: ActivityStore.Entry.Reason = .mention) -> ActivityStore.Entry {
        ActivityStore.Entry(
            id: id, channel: channel, authorDisplayName: "tandeeze", authorColor: "",
            text: "@landy hi", timestamp: Date(timeIntervalSince1970: seconds), reason: reason
        )
    }

    @Test("records newest first and counts unread")
    func recordsNewestFirst() {
        let store = ActivityStore()
        store.record([entry("a", at: 1)])
        store.record([entry("b", at: 3), entry("c", at: 2)])
        #expect(store.entries.map(\.id) == ["b", "c", "a"])
        #expect(store.unreadCount == 3)
        store.markAllRead()
        #expect(store.unreadCount == 0)
    }

    @Test("drops duplicate message ids (two tabs on one channel)")
    func dedupes() {
        let store = ActivityStore()
        store.record([entry("a", at: 1)])
        store.record([entry("a", at: 1), entry("b", at: 2)])
        #expect(store.entries.map(\.id) == ["b", "a"])
        #expect(store.unreadCount == 2)
    }

    @Test("caps at capacity, oldest dropped")
    func caps() {
        let store = ActivityStore()
        let many = (0..<(ActivityStore.capacity + 5)).map { entry("m\($0)", at: TimeInterval($0)) }
        store.record(many)
        #expect(store.entries.count == ActivityStore.capacity)
        #expect(store.entries.first?.id == "m\(ActivityStore.capacity + 4)")
        #expect(!store.entries.contains { $0.id == "m0" })
    }

    @Test("clear empties everything and allows re-recording")
    func clear() {
        let store = ActivityStore()
        store.record([entry("a", at: 1)])
        store.clear()
        #expect(store.entries.isEmpty && store.unreadCount == 0)
        store.record([entry("a", at: 1)])
        #expect(store.entries.count == 1)
    }
}
