import Testing
import ChatModel
@testable import Features

/// The correctness contract for the model→view incremental-change channel.
///
/// Instead of re-publishing the whole 500-line array and having the view
/// re-diff it, `ChatBuffer` emits a typed `[ChatChange]` for every mutation.
/// The view applies those changes directly to its data source. That is only
/// safe if this invariant holds for EVERY operation:
///
///     ChatChange.apply(buffer.takeChanges(), to: oldVisible) == buffer.lines
///
/// i.e. the emitted changes, applied to the previous visible state, reproduce
/// the new visible state exactly. These tests pin that invariant across the
/// full operation surface (append, cap-trim, blocked lines, replace, remove,
/// the three mutate shapes, block-set change, reset) — so the UIKit applier in
/// `ChatListView` can be trusted without per-operation UI tests.
@Suite("ChatChange contract")
struct ChatChangeContractTests {

    private func line(_ id: String, author: String = "u", _ body: String = "hi") -> ChatLine {
        ChatLine(id: id, kind: .message, authorUserId: author, authorDisplayName: author, runs: [.text(body)])
    }

    /// Runs `op`, then asserts the emitted changes reproduce the new visible
    /// state when applied to the old one.
    private func assertContract(
        _ buf: inout ChatBuffer,
        _ op: (inout ChatBuffer) -> Void,
        _ comment: Comment? = nil
    ) {
        let before = buf.lines
        op(&buf)
        let changes = buf.takeChanges()
        #expect(ChatChange.apply(changes, to: before) == buf.lines, comment ?? "")
    }

    // MARK: - Pure applier

    @Test("apply: append / remove / reconfigure / reset compose in order")
    func pureApplier() {
        let base = [line("a"), line("b")]
        let out = ChatChange.apply([
            .appended(line("c")),
            .removed(id: "a"),
            .reconfigured(line("b", "edited")),
        ], to: base)
        #expect(out.map(\.id) == ["b", "c"])
        #expect(out.first?.runs == [.text("edited")])

        // reset replaces wholesale regardless of prior state.
        #expect(ChatChange.apply([.reset([line("z")])], to: base).map(\.id) == ["z"])

        // rekeyed swaps identity in place.
        #expect(ChatChange.apply([.rekeyed(from: "a", to: line("a2"))], to: base).map(\.id) == ["a2", "b"])
    }

    // MARK: - Append

    @Test("append below cap emits a single .appended")
    func appendBelowCap() {
        var buf = ChatBuffer(cap: 100)
        assertContract(&buf) { $0.append(line("a")) }
        assertContract(&buf) { $0.append(line("b")) }
        #expect(buf.lines.map(\.id) == ["a", "b"])
    }

    @Test("append at cap emits append + the trimmed front removal")
    func appendAtCapTrims() {
        var buf = ChatBuffer(cap: 2)
        buf.append(line("a")); buf.append(line("b")); _ = buf.takeChanges()
        assertContract(&buf) { $0.append(line("c")) }   // drops "a"
        #expect(buf.lines.map(\.id) == ["b", "c"])
    }

    @Test("append of a blocked author emits no visible change")
    func appendBlockedNoChange() {
        var buf = ChatBuffer(cap: 100)
        buf.blockedIds = ["villain"]; _ = buf.takeChanges()
        assertContract(&buf) { $0.append(line("v", author: "villain")) }
        #expect(buf.lines.isEmpty)
    }

    @Test("trimming a blocked oldest emits no visible removal")
    func trimBlockedOldest() {
        var buf = ChatBuffer(cap: 3)
        buf.blockedIds = ["villain"]
        buf.append(line("v", author: "villain"))
        buf.append(line("a")); buf.append(line("b"))
        _ = buf.takeChanges()
        assertContract(&buf) { $0.append(line("c")) }   // pushes blocked "v" out
        #expect(buf.lines.map(\.id) == ["a", "b", "c"])
    }

    // MARK: - Mutations

    @Test("replace of a visible line emits .reconfigured")
    func replaceVisible() {
        var buf = ChatBuffer(cap: 100)
        buf.append(line("a", "old")); _ = buf.takeChanges()
        assertContract(&buf) { _ = $0.replace(id: "a", with: line("a", "new")) }
        #expect(buf.lines.first?.runs == [.text("new")])
    }

    @Test("replace that changes the id emits .rekeyed (pending → server id)")
    func replaceRekeys() {
        var buf = ChatBuffer(cap: 100)
        buf.append(line("a")); buf.append(line("pending-1", "mine")); buf.append(line("b"))
        _ = buf.takeChanges()
        assertContract(&buf) { _ = $0.replace(id: "pending-1", with: line("msg-1", "mine")) }
        #expect(buf.lines.map(\.id) == ["a", "msg-1", "b"])
    }

    @Test("re-key emits .rekeyed, never a .reconfigured the view can't place")
    func rekeyEmission() {
        var buf = ChatBuffer(cap: 100)
        buf.append(line("pending-1")); _ = buf.takeChanges()
        let delivered = line("msg-1")   // built once: ChatLine == includes its timestamp
        _ = buf.replace(id: "pending-1", with: delivered)
        #expect(buf.takeChanges() == [.rekeyed(from: "pending-1", to: delivered)])
        // The side table follows the new id.
        #expect(buf.contains(id: "msg-1"))
        #expect(!buf.contains(id: "pending-1"))
    }

    @Test("mutate(id:) that changes the id emits .rekeyed")
    func mutateRekeys() {
        var buf = ChatBuffer(cap: 100)
        buf.append(line("pending-1")); buf.append(line("b")); _ = buf.takeChanges()
        assertContract(&buf) { $0.mutate(id: "pending-1") { _ in self.line("msg-1") } }
        #expect(buf.lines.map(\.id) == ["msg-1", "b"])
    }

    @Test("re-key of a blocked author's line emits nothing visible")
    func rekeyBlockedNoChange() {
        var buf = ChatBuffer(cap: 100)
        buf.blockedIds = ["villain"]
        buf.append(line("pending-1", author: "villain")); _ = buf.takeChanges()
        assertContract(&buf) { _ = $0.replace(id: "pending-1", with: line("msg-1", author: "villain")) }
        #expect(buf.lines.isEmpty)
    }

    @Test("replace of an absent id emits nothing")
    func replaceAbsent() {
        var buf = ChatBuffer(cap: 100)
        buf.append(line("a")); _ = buf.takeChanges()
        assertContract(&buf) { _ = $0.replace(id: "missing", with: line("missing")) }
    }

    @Test("remove of a visible line emits .removed")
    func removeVisible() {
        var buf = ChatBuffer(cap: 100)
        buf.append(line("a")); buf.append(line("b")); _ = buf.takeChanges()
        assertContract(&buf) { _ = $0.remove(id: "a") }
        #expect(buf.lines.map(\.id) == ["b"])
    }

    @Test("mutate(id:) of a visible line emits .reconfigured")
    func mutateOne() {
        var buf = ChatBuffer(cap: 100)
        buf.append(line("a")); _ = buf.takeChanges()
        assertContract(&buf) { $0.mutate(id: "a") { $0.markingDeleted() } }
        #expect(buf.lines.first?.kind == .deletedPlaceholder)
    }

    @Test("mutateAll emits a reconfigure per visible line (chat-clear)")
    func mutateAll() {
        var buf = ChatBuffer(cap: 100)
        buf.append(line("a")); buf.append(line("b")); _ = buf.takeChanges()
        assertContract(&buf) { $0.mutateAll { $0.markingDeleted() } }
        #expect(buf.lines.allSatisfy { $0.kind == .deletedPlaceholder })
    }

    @Test("mutateMatching emits reconfigures only for the matched visible lines")
    func mutateMatching() {
        var buf = ChatBuffer(cap: 100)
        buf.append(line("a", author: "alice"))
        buf.append(line("v", author: "villain"))
        _ = buf.takeChanges()
        assertContract(&buf) { $0.mutateMatching(authorUserId: "villain") { $0.markingDeleted() } }
        #expect(buf.line(id: "a")?.kind == .message)
        #expect(buf.line(id: "v")?.kind == .deletedPlaceholder)
    }

    // MARK: - Wholesale changes

    @Test("changing blockedIds emits a .reset of the new visible window")
    func blockSetChangeResets() {
        var buf = ChatBuffer(cap: 100)
        buf.append(line("a", author: "alice"))
        buf.append(line("v", author: "villain"))
        _ = buf.takeChanges()
        assertContract(&buf) { $0.blockedIds = ["villain"] }
        #expect(buf.lines.map(\.id) == ["a"])
    }

    @Test("reset emits a .reset to empty")
    func resetEmits() {
        var buf = ChatBuffer(cap: 100)
        buf.append(line("a")); _ = buf.takeChanges()
        assertContract(&buf) { $0.reset() }
        #expect(buf.lines.isEmpty)
    }

    // MARK: - Thread relevance (ThreadView's refresh gate)

    private func reply(_ id: String, root: String) -> ChatLine {
        ChatLine(
            id: id, kind: .message, authorUserId: "u", authorDisplayName: "u", runs: [.text("re")],
            replyParent: ChatLine.ReplyParent(
                parentMessageId: root, parentAuthorDisplayName: "u",
                parentBody: "root", threadRootMessageId: root
            )
        )
    }

    @Test("touchesThread: unrelated chatter is ignored, root/replies/members are not")
    func touchesThread() {
        let members: Set<String> = ["root", "r1"]
        func touches(_ change: ChatChange) -> Bool {
            change.touchesThread(rootedAt: "root", memberIds: members)
        }
        #expect(!touches(.appended(line("noise"))))
        #expect(!touches(.removed(id: "noise")))
        #expect(!touches(.reconfigured(line("noise"))))
        #expect(!touches(.rekeyed(from: "pending-9", to: line("msg-9"))))

        #expect(touches(.appended(reply("r2", root: "root"))))        // new reply
        #expect(touches(.appended(line("root"))))                     // root itself
        #expect(touches(.reconfigured(line("r1"))))                   // member edited (deleted)
        #expect(touches(.removed(id: "r1")))                          // member trimmed
        #expect(touches(.rekeyed(from: "pending-1", to: reply("msg-1", root: "root"))))  // my reply delivered
        #expect(touches(.rekeyed(from: "r1", to: line("r1b"))))       // member re-keyed
        #expect(touches(.reset([])))
    }

    // MARK: - Composed stream

    @Test("a long mixed stream stays consistent change-by-change")
    func longMixedStreamStaysConsistent() {
        var buf = ChatBuffer(cap: 5)
        buf.blockedIds = ["spammer"]
        var mirror = buf.lines      // the view's applied state, reconstructed only from changes
        _ = buf.takeChanges()

        func step(_ op: (inout ChatBuffer) -> Void) {
            op(&buf)
            mirror = ChatChange.apply(buf.takeChanges(), to: mirror)
            #expect(mirror == buf.lines)
        }

        for i in 0..<40 {
            switch i % 5 {
            case 0: step { $0.append(line("m\(i)")) }
            case 1: step { $0.append(line("s\(i)", author: "spammer")) }   // blocked
            case 2: step { _ = $0.replace(id: "m\(i - 2)", with: line("m\(i - 2)", "edit")) }
            case 3: step { $0.mutate(id: "m\(i - 3)") { $0.markingDeleted() } }
            default:
                // Optimistic send + its server-id upgrade.
                step { $0.append(line("pending-\(i)")) }
                step { _ = $0.replace(id: "pending-\(i)", with: line("msg-\(i)")) }
            }
        }
        #expect(mirror == buf.lines)
    }
}
