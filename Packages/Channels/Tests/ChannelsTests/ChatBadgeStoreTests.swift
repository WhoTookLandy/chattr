import Testing
import Foundation
import TwitchKit
@testable import Channels

/// `ChatBadgeStore.entries(for:)` — the per-row badge resolution behind every
/// chat row. The memo is keyed by a hash of the badge pairs with an exact
/// comparison inside the bucket, so these pin that hits return the right
/// entries (order preserved, unknown badges dropped) and that a republished
/// table invalidates them.
@Suite("ChatBadgeStore resolution")
@MainActor
struct ChatBadgeStoreTests {

    /// `ChatBadge` has no public memberwise init — decode the wire shape.
    private func badges(_ pairs: [(setId: String, id: String)]) throws -> [ChatBadge] {
        let items = pairs.map { #"{"set_id":"\#($0.setId)","id":"\#($0.id)","info":""}"# }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode([ChatBadge].self, from: Data("[\(items.joined(separator: ","))]".utf8))
    }

    private func entry(_ name: String) -> ChatBadgeEntry {
        ChatBadgeEntry(url: URL(string: "https://example.com/\(name).png")!, title: name)
    }

    private func seededStore() -> ChatBadgeStore {
        let store = ChatBadgeStore()
        store.publish(entries: [
            ChatBadgeKey(setId: "moderator", id: "1"): entry("mod"),
            ChatBadgeKey(setId: "subscriber", id: "12"): entry("sub12"),
        ])
        return store
    }

    @Test("Resolves in message order and drops unknown badges")
    func resolvesInOrder() throws {
        let store = seededStore()
        let resolved = store.entries(for: try badges([
            ("subscriber", "12"), ("unknown", "1"), ("moderator", "1"),
        ]))
        #expect(resolved.map(\.title) == ["sub12", "mod"])
    }

    @Test("Repeat lookups hit the memo and return the same entries")
    func repeatLookupsAgree() throws {
        let store = seededStore()
        let set = try badges([("moderator", "1"), ("subscriber", "12")])
        let first = store.entries(for: set)
        let second = store.entries(for: set)
        #expect(first == second)
        // Same pairs, different order, is a different set.
        let reversed = store.entries(for: try badges([("subscriber", "12"), ("moderator", "1")]))
        #expect(reversed.map(\.title) == ["sub12", "mod"])
    }

    @Test("Badge-less rows resolve to nothing")
    func emptyBadges() {
        #expect(seededStore().entries(for: []).isEmpty)
    }

    @Test("Republishing the table invalidates memoized resolutions")
    func publishInvalidates() throws {
        let store = seededStore()
        let set = try badges([("moderator", "1")])
        #expect(store.entries(for: set).map(\.title) == ["mod"])
        store.publish(entries: [ChatBadgeKey(setId: "moderator", id: "1"): entry("mod-v2")])
        #expect(store.entries(for: set).map(\.title) == ["mod-v2"])
    }
}
