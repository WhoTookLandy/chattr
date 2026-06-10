import Testing
import Foundation
import ChatModel
@testable import Features

/// Tests for `ChatListDiff.fastAppendDelta` — the allocation-light fast path
/// for the dominant live-chat shapes (pure append, and front-trim + append).
///
/// The general `compute(old:new:)` builds two `[String: ChatLine]` dictionaries
/// over the whole (up to 500-line) buffer on every inbound message. The vast
/// majority of updates are "append 1 at the tail, maybe drop a few off the
/// front" — for those, `fastAppendDelta` returns the same `Delta` by walking
/// indices, with no dictionary allocation. Any shape it can't prove is a clean
/// append (a mid-buffer value change, a reorder) returns `nil` so the caller
/// falls back to the full `compute`.
///
/// Correctness contract: when `fastAppendDelta` returns non-nil, the `Delta`
/// MUST be byte-for-byte equal to what `compute` produces. The final test pins
/// that equivalence directly.
@Suite("ChatListDiff.fastAppendDelta")
struct ChatListDiffFastPathTests {

    private func line(_ id: String, _ body: String = "hi") -> ChatLine {
        ChatLine(id: id, authorDisplayName: "u", runs: [.text(body)], timestamp: Date(timeIntervalSince1970: 0))
    }

    @Test("Pure append: old is a prefix of new")
    func pureAppend() {
        let old = [line("a"), line("b")]
        let new = [line("a"), line("b"), line("c")]
        let delta = ChatListDiff.fastAppendDelta(old: old, new: new)
        #expect(delta == ChatListDiff.Delta(
            inserted: ["c"], removed: [], reconfigured: [], orderedIDs: ["a", "b", "c"]
        ))
    }

    @Test("Front-trim + append: oldest dropped, newest appended, overlap unchanged")
    func frontTrimAppend() {
        let old = [line("a"), line("b"), line("c")]
        let new = [line("b"), line("c"), line("d")]
        let delta = ChatListDiff.fastAppendDelta(old: old, new: new)
        #expect(delta == ChatListDiff.Delta(
            inserted: ["d"], removed: ["a"], reconfigured: [], orderedIDs: ["b", "c", "d"]
        ))
    }

    @Test("Identical arrays produce an all-empty delta (no nil)")
    func identical() {
        let same = [line("a"), line("b")]
        let delta = ChatListDiff.fastAppendDelta(old: same, new: same)
        #expect(delta == ChatListDiff.Delta(
            inserted: [], removed: [], reconfigured: [], orderedIDs: ["a", "b"]
        ))
    }

    @Test("A changed value in the overlap is NOT a clean append → nil")
    func reconfiguredOverlapBailsOut() {
        let old = [line("a", "sending"), line("b")]
        let new = [line("a", "delivered"), line("b"), line("c")]
        #expect(ChatListDiff.fastAppendDelta(old: old, new: new) == nil)
    }

    @Test("A reordering is NOT a clean append → nil")
    func reorderBailsOut() {
        let old = [line("a"), line("b"), line("c")]
        let new = [line("a"), line("c"), line("b")]
        #expect(ChatListDiff.fastAppendDelta(old: old, new: new) == nil)
    }

    @Test("Empty old, non-empty new is a pure append (priming)")
    func fromEmpty() {
        let new = [line("a"), line("b")]
        let delta = ChatListDiff.fastAppendDelta(old: [], new: new)
        #expect(delta == ChatListDiff.Delta(
            inserted: ["a", "b"], removed: [], reconfigured: [], orderedIDs: ["a", "b"]
        ))
    }

    @Test("When non-nil, fastAppendDelta equals the general compute result")
    func equivalenceWithCompute() {
        // A realistic front-trim + multi-append at buffer scale.
        let old = (0..<500).map { line("m\($0)") }
        let new = Array(old.dropFirst(2)) + [line("m500"), line("m501")]
        let fast = ChatListDiff.fastAppendDelta(old: old, new: new)
        let full = ChatListDiff.compute(old: old, new: new)
        #expect(fast == full)
    }
}
