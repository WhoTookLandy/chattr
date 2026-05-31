import Testing
import Foundation
import ChatModel
@testable import Features

@Suite("ChatListDiff.compute")
struct ChatListDiffTests {

    /// Minimal delivered message line with a given id + body.
    private func line(_ id: String, _ body: String = "hi") -> ChatLine {
        ChatLine(id: id, authorDisplayName: "u", runs: [.text(body)], timestamp: Date(timeIntervalSince1970: 0))
    }

    @Test("Appending one line reports it inserted, nothing removed/reconfigured")
    func append() {
        let old = [line("a"), line("b")]
        let new = [line("a"), line("b"), line("c")]
        let delta = ChatListDiff.compute(old: old, new: new)
        #expect(delta.inserted == ["c"])
        #expect(delta.removed.isEmpty)
        #expect(delta.reconfigured.isEmpty)
        #expect(delta.orderedIDs == ["a", "b", "c"])
    }

    @Test("Front-trim reports the dropped ids removed")
    func frontTrim() {
        let old = [line("a"), line("b"), line("c")]
        let new = [line("b"), line("c"), line("d")]
        let delta = ChatListDiff.compute(old: old, new: new)
        #expect(delta.removed == ["a"])
        #expect(delta.inserted == ["d"])
        #expect(delta.reconfigured.isEmpty)
        #expect(delta.orderedIDs == ["b", "c", "d"])
    }

    @Test("Same id with a changed value is reconfigured, not re-inserted")
    func inPlaceChange() {
        let old = [line("a", "sending")]
        // Same id, different body — e.g. optimistic→delivered upgrade.
        let new = [line("a", "delivered")]
        let delta = ChatListDiff.compute(old: old, new: new)
        #expect(delta.reconfigured == ["a"])
        #expect(delta.inserted.isEmpty)
        #expect(delta.removed.isEmpty)
    }

    @Test("Identical input produces an empty delta")
    func noChange() {
        let same = [line("a"), line("b")]
        let delta = ChatListDiff.compute(old: same, new: same)
        #expect(delta.inserted.isEmpty)
        #expect(delta.removed.isEmpty)
        #expect(delta.reconfigured.isEmpty)
        #expect(delta.orderedIDs == ["a", "b"])
    }

    @Test("chatCleared-style flip reconfigures every changed line")
    func clearAll() {
        let old = [line("a"), line("b"), line("c")]
        // Every line flips to a deleted placeholder (value changes, ids stay).
        let new = old.map { $0.withDeletedPlaceholder() }
        let delta = ChatListDiff.compute(old: old, new: new)
        #expect(delta.reconfigured == ["a", "b", "c"])
        #expect(delta.inserted.isEmpty)
        #expect(delta.removed.isEmpty)
    }

    @Test("Retry remove reports the failed id removed")
    func retryRemove() {
        let old = [line("a"), line("pending-x"), line("b")]
        let new = [line("a"), line("b")]
        let delta = ChatListDiff.compute(old: old, new: new)
        #expect(delta.removed == ["pending-x"])
        #expect(delta.inserted.isEmpty)
        #expect(delta.orderedIDs == ["a", "b"])
    }
}
