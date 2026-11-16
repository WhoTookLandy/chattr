import Testing
import ChatModel
@testable import Features

/// Tests for `ChatBuffer` — the sliding-window store that replaces
/// `ChatTranscriptModel`'s `allLines` array + per-message `BlockFilter.apply`
/// full-rescan + `Array.removeFirst` trim.
///
/// Two invariants matter most and are pinned hard here:
///   1. **`lines` always equals the block-filtered logical window.** No matter
///      the path taken to get there (incremental append, trim of a blocked vs
///      unblocked oldest, mid-buffer mutation, block-set change), the visible
///      projection must match a from-scratch filter of the unfiltered window.
///   2. **The cap is exact and the ring compaction is lossless.** Appending
///      far past the cap must keep exactly the most-recent `cap` lines in order
///      — the head-index ring's batch compaction must not drop or reorder.
@Suite("ChatBuffer")
struct ChatBufferTests {

    private func line(_ id: String, author: String = "u", _ body: String = "hi") -> ChatLine {
        ChatLine(id: id, kind: .message, authorUserId: author, authorDisplayName: author, runs: [.text(body)])
    }

    // MARK: - Append + visible projection

    @Test("Append with no blocks: lines mirrors every appended line in order")
    func appendNoBlocks() {
        var buf = ChatBuffer(cap: 100)
        buf.append(line("a")); buf.append(line("b")); buf.append(line("c"))
        #expect(buf.lines.map(\.id) == ["a", "b", "c"])
        #expect(buf.count == 3)
        #expect(buf.last?.id == "c")
    }

    @Test("Blocked author is excluded from lines but present in the unfiltered window")
    func blockedExcludedFromVisible() {
        var buf = ChatBuffer(cap: 100)
        buf.blockedIds = ["villain"]
        buf.append(line("a", author: "alice"))
        buf.append(line("v", author: "villain"))
        buf.append(line("b", author: "bob"))
        #expect(buf.lines.map(\.id) == ["a", "b"])
        #expect(buf.contains(id: "v"))          // still in the unfiltered store
        #expect(buf.line(id: "v")?.id == "v")
    }

    @Test("Setting blockedIds re-filters lines already in the buffer")
    func blockingReFiltersExisting() {
        var buf = ChatBuffer(cap: 100)
        buf.append(line("a", author: "alice"))
        buf.append(line("v", author: "villain"))
        #expect(buf.lines.map(\.id) == ["a", "v"])
        buf.blockedIds = ["villain"]
        #expect(buf.lines.map(\.id) == ["a"])
    }

    @Test("Unblocking restores previously-hidden lines in their original position")
    func unblockingRestores() {
        var buf = ChatBuffer(cap: 100)
        buf.blockedIds = ["villain"]
        buf.append(line("a", author: "alice"))
        buf.append(line("v", author: "villain"))
        buf.append(line("b", author: "bob"))
        #expect(buf.lines.map(\.id) == ["a", "b"])
        buf.blockedIds = []
        #expect(buf.lines.map(\.id) == ["a", "v", "b"])
    }

    // MARK: - Cap + ring compaction

    @Test("Appending past the cap drops the oldest and holds at cap")
    func capDropsOldest() {
        var buf = ChatBuffer(cap: 3)
        for i in 0..<5 { buf.append(line("m\(i)")) }
        #expect(buf.count == 3)
        #expect(buf.lines.map(\.id) == ["m2", "m3", "m4"])
    }

    @Test("Appending far past the cap keeps exactly the most-recent cap lines, in order")
    func ringCompactionIsLossless() {
        let cap = 50
        var buf = ChatBuffer(cap: cap)
        let total = cap * 7 + 13           // forces several batch compactions
        for i in 0..<total { buf.append(line("m\(i)")) }
        #expect(buf.count == cap)
        let expected = (total - cap..<total).map { "m\($0)" }
        #expect(buf.lines.map(\.id) == expected)
        #expect(buf.last?.id == "m\(total - 1)")
        #expect(buf.contains(id: "m\(total - 1)"))
        #expect(!buf.contains(id: "m\(total - cap - 1)"))   // just past the window
    }

    @Test("Trimming a blocked oldest line does not corrupt the visible projection")
    func trimBlockedOldestKeepsVisibleCorrect() {
        var buf = ChatBuffer(cap: 3)
        buf.blockedIds = ["villain"]
        // Oldest will be a blocked line; trimming it must NOT pop a visible row.
        buf.append(line("v0", author: "villain"))
        buf.append(line("a", author: "alice"))
        buf.append(line("b", author: "bob"))
        buf.append(line("c", author: "carol"))   // pushes v0 out (a blocked line)
        #expect(buf.count == 3)                    // a, b, c unfiltered
        #expect(buf.lines.map(\.id) == ["a", "b", "c"])
    }

    // MARK: - Mutation by id

    @Test("replace swaps a line's value in place and reflects in lines; returns false if absent")
    func replaceById() {
        var buf = ChatBuffer(cap: 100)
        buf.append(line("a", "old"))
        #expect(buf.replace(id: "a", with: line("a", "new")) == true)
        #expect(buf.line(id: "a")?.runs == [.text("new")])
        #expect(buf.lines.first?.runs == [.text("new")])
        #expect(buf.replace(id: "missing", with: line("missing")) == false)
    }

    @Test("remove drops a line from both the unfiltered store and lines")
    func removeById() {
        var buf = ChatBuffer(cap: 100)
        buf.append(line("a")); buf.append(line("b")); buf.append(line("c"))
        #expect(buf.remove(id: "b") == true)
        #expect(buf.lines.map(\.id) == ["a", "c"])
        #expect(!buf.contains(id: "b"))
        #expect(buf.remove(id: "b") == false)
    }

    @Test("remove re-points only the shifted tail and keeps the id table exact across later trims")
    func removeKeepsIndexExact() {
        var buf = ChatBuffer(cap: 4)
        for i in 0..<6 { buf.append(line("m\(i)")) }   // window m2…m5, ring head advanced
        #expect(buf.remove(id: "m3"))
        #expect(buf.lines.map(\.id) == ["m2", "m4", "m5"])
        for id in ["m2", "m4", "m5"] { #expect(buf.line(id: id)?.id == id) }
        #expect(!buf.contains(id: "m3"))

        // Edits after the shift still land on the right rows…
        buf.mutate(id: "m5") { $0.markingDeleted() }
        #expect(buf.lines.last?.kind == .deletedPlaceholder)
        // …and trims past the removal point stay consistent.
        buf.append(line("m6")); buf.append(line("m7"))
        #expect(buf.lines.map(\.id) == ["m4", "m5", "m6", "m7"])
        #expect(buf.line(id: "m4")?.id == "m4")
        #expect(buf.remove(id: "m7"))
        #expect(buf.lines.map(\.id) == ["m4", "m5", "m6"])
    }

    @Test("visible-row lookups stay correct when blocked lines break index alignment")
    func visibleLookupWithBlockedAuthors() {
        var buf = ChatBuffer(cap: 100)
        buf.blockedIds = ["villain"]
        buf.append(line("a")); buf.append(line("v", author: "villain"))
        buf.append(line("b")); buf.append(line("c"))
        buf.mutate(id: "c") { $0.markingDeleted() }
        #expect(buf.lines.map(\.kind) == [.message, .message, .deletedPlaceholder])
        #expect(buf.remove(id: "b"))
        #expect(buf.lines.map(\.id) == ["a", "c"])
        _ = buf.replace(id: "a", with: line("a", "edited"))
        #expect(buf.lines.first?.runs == [.text("edited")])
    }

    @Test("takeChanges drains once, then returns empty")
    func takeChangesDrains() {
        var buf = ChatBuffer(cap: 100)
        #expect(buf.takeChanges().isEmpty)
        buf.append(line("a"))
        #expect(buf.takeChanges() == [.appended(line("a"))])
        #expect(buf.takeChanges().isEmpty)
    }

    @Test("mutate transforms one line by id")
    func mutateOne() {
        var buf = ChatBuffer(cap: 100)
        buf.append(line("a")); buf.append(line("b"))
        buf.mutate(id: "b") { $0.markingDeleted() }
        #expect(buf.line(id: "b")?.kind == .deletedPlaceholder)
    }

    @Test("mutateAll transforms every line (chat-clear shape)")
    func mutateEveryLine() {
        var buf = ChatBuffer(cap: 100)
        buf.append(line("a")); buf.append(line("b"))
        buf.mutateAll { $0.markingDeleted() }
        #expect(buf.lines.allSatisfy { $0.kind == .deletedPlaceholder })
    }

    @Test("mutateMatching transforms only the target author's lines (timeout shape)")
    func mutateByAuthor() {
        var buf = ChatBuffer(cap: 100)
        buf.append(line("a", author: "alice"))
        buf.append(line("v", author: "villain"))
        buf.append(line("v2", author: "villain"))
        buf.mutateMatching(authorUserId: "villain") { $0.markingDeleted() }
        #expect(buf.line(id: "a")?.kind == .message)
        #expect(buf.line(id: "v")?.kind == .deletedPlaceholder)
        #expect(buf.line(id: "v2")?.kind == .deletedPlaceholder)
    }

    @Test("reset empties the buffer")
    func resetClears() {
        var buf = ChatBuffer(cap: 100)
        buf.append(line("a")); buf.append(line("b"))
        buf.reset()
        #expect(buf.count == 0)
        #expect(buf.lines.isEmpty)
        #expect(buf.last == nil)
    }
}
