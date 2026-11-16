import Testing
import ChatModel
@testable import Features

/// `ChatListFeed` is the platform-independent half of `ChatListView`: it turns
/// the model's change log into data-source edits. These tests drive it against
/// a real `ChatBuffer` + `ChatChangeLog` (the same pair `ChatTranscriptModel`
/// publishes through) and replay every edit onto `ListMirror`, which enforces
/// the diffable-snapshot rules UIKit throws on AND tracks what each cell
/// would display — so a row whose new value never reaches its cell (the old
/// lossy-reset bug) fails as a stale cell, not just a wrong id order.
@Suite("ChatListFeed")
struct ChatListFeedTests {

    // MARK: - Harness

    /// Stand-in for `ChatTranscriptModel`'s change channel, with the same
    /// seal-on-read semantics as `changes(since:)` / `transcriptSnapshot()`.
    final class FakeTranscript {
        var buffer: ChatBuffer
        var log: ChatChangeLog

        init(cap: Int = 100, logCapacity: Int = 120) {
            buffer = ChatBuffer(cap: cap)
            log = ChatChangeLog(capacity: logCapacity)
        }

        /// One model flush: everything pending becomes one log batch.
        func flush() {
            let changes = buffer.takeChanges()
            if !changes.isEmpty { log.append(changes) }
        }

        func changes(since version: Int) -> ChatChangeLog.Delta {
            flush()
            return log.changes(since: version)
        }

        func snapshot() -> (version: Int, lines: [ChatLine]) {
            flush()
            return (log.headVersion, buffer.lines)
        }
    }

    /// Simulated diffable data source. `ids` is the item list; `shown` is what
    /// each cell displays — fresh cells read `linesByID`, kept cells keep
    /// their old value unless reconfigured (UIKit's behavior for on-screen
    /// cells).
    struct ListMirror {
        private(set) var ids: [String] = []
        private(set) var shown: [String: ChatLine] = [:]

        mutating func apply(_ edit: ChatListEdit, linesByID: [String: ChatLine]) {
            let before = Set(ids)
            var list = ids
            if let reset = edit.resetIds {
                #expect(Set(reset).count == reset.count, "reset carries a duplicate id")
                list = reset
            }
            for step in edit.steps {
                switch step {
                case .delete(let doomed):
                    for id in doomed { #expect(list.contains(id), "delete of absent \(id)") }
                    let set = Set(doomed)
                    list.removeAll { set.contains($0) }
                case .append(let added):
                    for id in added { #expect(!list.contains(id), "append of present \(id)") }
                    list += added
                case .replace(let from, let to):
                    #expect(!list.contains(to), "replace into present \(to)")
                    guard let i = list.firstIndex(of: from) else {
                        Issue.record("replace of absent \(from)")
                        continue
                    }
                    list[i] = to
                }
            }
            #expect(Set(list).count == list.count, "duplicate identifiers after edit")
            let after = Set(list)
            for id in edit.reconfigure {
                #expect(after.contains(id), "reconfigure of absent \(id)")
                #expect(before.contains(id), "reconfigure of an id inserted by the same edit: \(id)")
            }
            let reconfigured = Set(edit.reconfigure)
            var newShown: [String: ChatLine] = [:]
            for id in list {
                if !before.contains(id) || reconfigured.contains(id) {
                    newShown[id] = linesByID[id]
                } else {
                    newShown[id] = shown[id]
                }
            }
            ids = list
            shown = newShown
        }
    }

    /// Feed + transcript + mirror wired together.
    struct Rig {
        let transcript: FakeTranscript
        var feed: ChatListFeed
        var mirror = ListMirror()
        var pinned = true

        init(cap: Int = 100, logCapacity: Int = 120, maxDeferred: Int = ChatListFeed.defaultMaxDeferredChanges) {
            transcript = FakeTranscript(cap: cap, logCapacity: logCapacity)
            feed = ChatListFeed(maxDeferredChanges: maxDeferred)
        }

        /// One `ChatListViewController.refresh()`.
        @discardableResult
        mutating func update(reconfigureAll: Bool = false) -> ChatListEdit {
            let transcript = self.transcript
            let edit = feed.update(
                pinned: pinned,
                reconfigureAll: reconfigureAll,
                changes: { transcript.changes(since: $0) },
                snapshot: { transcript.snapshot() }
            )
            mirror.apply(edit, linesByID: feed.linesByID)
            return edit
        }

        /// The list shows exactly the model's visible lines, with current values.
        func expectInSync(sourceLocation: SourceLocation = #_sourceLocation) {
            let expected = transcript.buffer.lines
            #expect(mirror.ids == expected.map(\.id), sourceLocation: sourceLocation)
            for line in expected {
                #expect(mirror.shown[line.id] == line, "stale cell \(line.id)", sourceLocation: sourceLocation)
            }
            #expect(feed.liveIds == Set(mirror.ids), sourceLocation: sourceLocation)
        }
    }

    private func line(_ id: String, author: String = "u", _ body: String = "hi") -> ChatLine {
        ChatLine(id: id, kind: .message, authorUserId: author, authorDisplayName: author, runs: [.text(body)])
    }

    // MARK: - Pinned

    @Test("first update resets from the snapshot")
    func firstUpdateResets() {
        var rig = Rig()
        rig.transcript.buffer.append(line("a"))
        rig.transcript.buffer.append(line("b"))
        let edit = rig.update()
        #expect(edit.resetIds == ["a", "b"])
        #expect(edit.reconfigure.isEmpty)
        rig.expectInSync()
    }

    @Test("several flushes between updates replay without a reset, and in-place edits reach their rows")
    func coalescedFlushesReplay() {
        var rig = Rig()
        rig.transcript.buffer.append(line("a"))
        rig.transcript.buffer.append(line("b"))
        rig.update()

        // Three model flushes, one SwiftUI update (it coalesced them).
        rig.transcript.buffer.append(line("c")); rig.transcript.flush()
        rig.transcript.buffer.mutate(id: "a") { $0.markingDeleted() }; rig.transcript.flush()
        rig.transcript.buffer.append(line("d")); rig.transcript.flush()

        let edit = rig.update()
        #expect(edit.resetIds == nil)
        #expect(edit.steps == [.append(["c", "d"])])
        #expect(edit.reconfigure == ["a"])
        #expect(rig.mirror.shown["a"]?.kind == .deletedPlaceholder)
        rig.expectInSync()
    }

    @Test("a firehose window collapses to one delete + one append step")
    func firehoseBatchesSteps() {
        var rig = Rig(cap: 5)
        for i in 0..<5 { rig.transcript.buffer.append(line("m\(i)")) }
        rig.update()
        for i in 5..<25 { rig.transcript.buffer.append(line("m\(i)")) }
        let edit = rig.update()
        #expect(edit.steps.count == 2)
        #expect(edit.steps.first == .delete(["m0", "m1", "m2", "m3", "m4"]))
        #expect(edit.steps.last == .append(["m20", "m21", "m22", "m23", "m24"]))
        rig.expectInSync()
    }

    @Test("an optimistic row re-keyed to its server id is replaced in place with the delivered value")
    func rekeyReachesCell() {
        var rig = Rig()
        rig.transcript.buffer.append(line("a"))
        rig.transcript.buffer.append(line("pending-1", "sending"))
        rig.transcript.buffer.append(line("b"))
        rig.update()

        _ = rig.transcript.buffer.replace(id: "pending-1", with: line("msg-1", "delivered"))
        let edit = rig.update()
        #expect(edit.steps == [.replace(from: "pending-1", with: "msg-1")])
        #expect(rig.mirror.ids == ["a", "msg-1", "b"])
        rig.expectInSync()
    }

    @Test("append + re-key inside one window becomes a plain append of the final id")
    func rekeyOfPendingAppend() {
        var rig = Rig()
        rig.transcript.buffer.append(line("a"))
        rig.update()
        rig.transcript.buffer.append(line("pending-1"))
        _ = rig.transcript.buffer.replace(id: "pending-1", with: line("msg-1"))
        let edit = rig.update()
        #expect(edit.steps == [.append(["msg-1"])])
        rig.expectInSync()
    }

    @Test("a removed failed row followed by a retry send stays consistent")
    func removeThenAppend() {
        var rig = Rig()
        rig.transcript.buffer.append(line("a"))
        rig.transcript.buffer.append(line("pending-1"))
        rig.update()
        _ = rig.transcript.buffer.remove(id: "pending-1")
        rig.transcript.buffer.append(line("pending-2"))
        rig.update()
        rig.expectInSync()
    }

    @Test("log overrun resets AND reconfigures surviving rows whose value changed")
    func overrunResetReconfiguresChangedRows() {
        var rig = Rig(logCapacity: 3)
        for id in ["a", "b", "c"] { rig.transcript.buffer.append(line(id)) }
        rig.transcript.buffer.append(line("pending-1", "sending"))
        rig.update()

        // Five flushes against a 3-batch log: the feed's next batch is evicted.
        rig.transcript.buffer.mutate(id: "b") { $0.markingDeleted() }; rig.transcript.flush()
        _ = rig.transcript.buffer.replace(id: "pending-1", with: line("pending-1", "failed")); rig.transcript.flush()
        rig.transcript.buffer.append(line("d")); rig.transcript.flush()
        rig.transcript.buffer.append(line("e")); rig.transcript.flush()
        rig.transcript.buffer.append(line("f")); rig.transcript.flush()

        let edit = rig.update()
        #expect(edit.resetIds == ["a", "b", "c", "pending-1", "d", "e", "f"])
        #expect(Set(edit.reconfigure) == ["b", "pending-1"])
        rig.expectInSync()   // the stale-cell check is the regression guard
    }

    @Test("a block-list change resets; unchanged survivors are not reconfigured")
    func blockReset() {
        var rig = Rig()
        rig.transcript.buffer.append(line("a", author: "alice"))
        rig.transcript.buffer.append(line("v", author: "villain"))
        rig.transcript.buffer.append(line("b", author: "bob"))
        rig.update()
        rig.transcript.buffer.blockedIds = ["villain"]
        let edit = rig.update()
        #expect(edit.resetIds == ["a", "b"])
        #expect(edit.reconfigure.isEmpty)
        rig.expectInSync()
    }

    @Test("reconfigureAll refreshes every pre-existing row but never a row inserted by the same edit")
    func reconfigureAll() {
        var rig = Rig()
        rig.transcript.buffer.append(line("a"))
        rig.transcript.buffer.append(line("b"))
        rig.update()
        rig.transcript.buffer.append(line("c"))
        let edit = rig.update(reconfigureAll: true)
        #expect(Set(edit.reconfigure) == ["a", "b"])
        rig.expectInSync()
    }

    // MARK: - Unpinned (reading scrollback)

    @Test("unpinned: appends and trims are held back and counted; resume flushes them")
    func unpinnedHoldsStructuralChanges() {
        var rig = Rig(cap: 4)
        for i in 0..<4 { rig.transcript.buffer.append(line("m\(i)")) }
        rig.update()

        rig.pinned = false
        for i in 4..<7 { rig.transcript.buffer.append(line("m\(i)")) }   // trims m0…m2
        let held = rig.update()
        #expect(held.isEmpty)
        #expect(rig.feed.unreadCount == 3)
        #expect(rig.feed.hasDeferredChanges)
        // The reader still sees the rows the model already trimmed.
        #expect(rig.mirror.ids == ["m0", "m1", "m2", "m3"])

        rig.pinned = true
        let resumed = rig.update()
        #expect(resumed.resetIds == nil)
        #expect(rig.feed.unreadCount == 0)
        #expect(!rig.feed.hasDeferredChanges)
        rig.expectInSync()
    }

    @Test("unpinned: unread counts appends across every replayed batch")
    func unpinnedCountsAcrossBatches() {
        var rig = Rig()
        rig.transcript.buffer.append(line("a"))
        rig.update()
        rig.pinned = false
        for i in 0..<4 {
            rig.transcript.buffer.append(line("x\(i)"))
            rig.transcript.flush()   // four flushes…
        }
        rig.update()                 // …one update
        #expect(rig.feed.unreadCount == 4)
        rig.transcript.buffer.append(line("y")); rig.update()
        #expect(rig.feed.unreadCount == 5)
    }

    @Test("unpinned: in-place edits of on-screen rows apply immediately")
    func unpinnedAppliesInPlaceEdits() {
        var rig = Rig()
        rig.transcript.buffer.append(line("a"))
        rig.transcript.buffer.append(line("b"))
        rig.update()
        rig.pinned = false
        rig.transcript.buffer.append(line("c"))
        rig.transcript.buffer.mutate(id: "a") { $0.markingDeleted() }
        let edit = rig.update()
        #expect(edit.steps.isEmpty)
        #expect(edit.reconfigure == ["a"])
        #expect(rig.mirror.shown["a"]?.kind == .deletedPlaceholder)
        #expect(rig.mirror.ids == ["a", "b"])
        #expect(rig.feed.unreadCount == 1)

        rig.pinned = true
        rig.update()
        rig.expectInSync()
    }

    @Test("unpinned: moderation still strikes rows held on screen after the model trimmed them")
    func unpinnedModerationReachesTrimmedRows() {
        var rig = Rig(cap: 3)
        for id in ["a", "b", "c"] { rig.transcript.buffer.append(line(id)) }
        rig.update()
        rig.pinned = false
        for i in 0..<3 { rig.transcript.buffer.append(line("x\(i)")) }   // trims a, b, c — still on screen
        rig.transcript.buffer.mutate(id: "a") { $0.markingDeleted() }      // a mod deletes one of them
        let edit = rig.update()
        #expect(edit.steps.isEmpty)
        #expect(edit.reconfigure == ["a"])
        #expect(rig.mirror.ids == ["a", "b", "c"])
        #expect(rig.mirror.shown["a"]?.kind == .deletedPlaceholder)
        rig.pinned = true
        rig.update()
        rig.expectInSync()
    }

    @Test("unpinned: the user's own on-screen send is swapped to its delivered row immediately")
    func unpinnedRekeyAppliesNow() {
        var rig = Rig()
        rig.transcript.buffer.append(line("a"))
        rig.transcript.buffer.append(line("pending-1", "sending"))
        rig.update()
        rig.pinned = false
        rig.transcript.buffer.append(line("b"))   // held
        _ = rig.transcript.buffer.replace(id: "pending-1", with: line("msg-1", "delivered"))
        let edit = rig.update()
        #expect(edit.steps == [.replace(from: "pending-1", with: "msg-1")])
        #expect(rig.mirror.ids == ["a", "msg-1"])
        #expect(rig.feed.unreadCount == 1)
        rig.pinned = true
        rig.update()
        rig.expectInSync()
    }

    @Test("unpinned: an edit of a row with a held-back change queues behind it")
    func unpinnedEditQueuesBehindDeferred() {
        var rig = Rig()
        rig.transcript.buffer.append(line("a"))
        rig.update()
        rig.pinned = false
        rig.transcript.buffer.append(line("pending-1", "sending"))
        _ = rig.transcript.buffer.replace(id: "pending-1", with: line("msg-1", "delivered"))
        rig.transcript.buffer.mutate(id: "msg-1") { $0.markingDeleted() }
        #expect(rig.update().isEmpty)
        rig.pinned = true
        rig.update()
        rig.expectInSync()
        #expect(rig.mirror.shown["msg-1"]?.kind == .deletedPlaceholder)
    }

    @Test("unpinned: a reset (block change) applies immediately and supersedes the backlog")
    func unpinnedResetAppliesNow() {
        var rig = Rig()
        rig.transcript.buffer.append(line("a", author: "alice"))
        rig.transcript.buffer.append(line("v", author: "villain"))
        rig.update()
        rig.pinned = false
        rig.transcript.buffer.append(line("b", author: "bob"))   // held
        rig.transcript.buffer.blockedIds = ["villain"]
        let edit = rig.update()
        #expect(edit.resetIds == ["a", "b"])
        #expect(!rig.feed.hasDeferredChanges)
        rig.expectInSync()
        rig.pinned = true
        #expect(rig.update().isEmpty)
        rig.expectInSync()
    }

    @Test("unpinned: overflowing the backlog abandons it and resets on resume")
    func unpinnedOverflowResetsOnResume() {
        var rig = Rig(maxDeferred: 10)
        rig.transcript.buffer.append(line("a"))
        rig.update()
        rig.pinned = false
        for i in 0..<20 { rig.transcript.buffer.append(line("x\(i)")) }
        #expect(rig.update().isEmpty)
        #expect(rig.feed.unreadCount == 20)
        #expect(rig.feed.hasDeferredChanges)
        rig.pinned = true
        let resumed = rig.update()
        #expect(resumed.resetIds != nil)
        rig.expectInSync()
    }

    @Test("unpinned: a log overrun is absorbed and resets on resume")
    func unpinnedLogOverrun() {
        var rig = Rig(logCapacity: 2)
        rig.transcript.buffer.append(line("a"))
        rig.update()
        rig.pinned = false
        for i in 0..<5 {
            rig.transcript.buffer.append(line("x\(i)"))
            rig.transcript.flush()
        }
        #expect(rig.update().isEmpty)
        #expect(rig.feed.hasDeferredChanges)
        rig.pinned = true
        #expect(rig.update().resetIds != nil)
        rig.expectInSync()
    }

    // MARK: - Fuzz

    @Test("seeded random op streams keep every edit diffable-valid and converge when pinned")
    func fuzz() {
        for seed in UInt64(1)...UInt64(40) {
            var rng = SplitMix64(seed: seed)
            var rig = Rig(cap: 12, logCapacity: 6, maxDeferred: 25)
            var next = 0
            var pending: [String] = []

            for _ in 0..<300 {
                let buffer = rig.transcript
                switch rng.next(upTo: 12) {
                case 0, 1, 2:
                    buffer.buffer.append(line("m\(next)", author: rng.next(upTo: 6) == 0 ? "villain" : "u"))
                    next += 1
                case 3:
                    let id = "pending-\(next)"; next += 1
                    buffer.buffer.append(line(id, "sending"))
                    pending.append(id)
                case 4:
                    if let id = pending.popLast() {
                        _ = buffer.buffer.replace(id: id, with: line("msg-\(id)", "delivered"))
                    }
                case 5:
                    if let id = pending.last {
                        _ = buffer.buffer.replace(id: id, with: line(id, "failed"))
                    }
                case 6:
                    if next > 0 { buffer.buffer.mutate(id: "m\(rng.next(upTo: next))") { $0.markingDeleted() } }
                case 7:
                    if let id = pending.popLast() { _ = buffer.buffer.remove(id: id) }
                case 8:
                    if rng.next(upTo: 8) == 0 { buffer.buffer.blockedIds = rng.next(upTo: 2) == 0 ? ["villain"] : [] }
                case 9:
                    if rng.next(upTo: 10) == 0 { buffer.buffer.mutateAll { $0.markingDeleted() } }
                case 10:
                    buffer.flush()
                default:
                    rig.pinned = rng.next(upTo: 3) != 0
                    rig.update(reconfigureAll: rng.next(upTo: 10) == 0)
                    if rig.pinned { rig.expectInSync() }
                }
            }
            rig.pinned = true
            rig.update()
            rig.expectInSync()
        }
    }
}

/// Tiny deterministic PRNG so the fuzz is reproducible across runs/platforms.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func nextRaw() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func next(upTo bound: Int) -> Int { Int(nextRaw() % UInt64(bound)) }
}
