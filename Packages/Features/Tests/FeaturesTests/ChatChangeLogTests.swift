import Testing
import ChatModel
@testable import Features

/// `ChatChangeLog` is what lets a view that missed publishes (SwiftUI
/// coalesces invalidations) replay every batch instead of resetting. These
/// pin its version arithmetic: contiguous versions, exact replay from any
/// retained version, and `.overrun` exactly when a needed batch is gone.
@Suite("ChatChangeLog")
struct ChatChangeLogTests {

    private func line(_ id: String) -> ChatLine {
        ChatLine(id: id, kind: .message, authorUserId: "u", authorDisplayName: "u", runs: [.text(id)])
    }

    private func batch(_ id: String) -> [ChatChange] { [.appended(line(id))] }

    @Test("empty log: current reader gets nothing, unknown reader must reset")
    func emptyLog() {
        let log = ChatChangeLog(capacity: 4)
        #expect(log.headVersion == 0)
        #expect(log.changes(since: 0) == .changes([], through: 0))
        #expect(log.changes(since: -1) == .overrun(head: 0))
    }

    @Test("empty batches don't bump the version")
    func emptyBatchIgnored() {
        var log = ChatChangeLog(capacity: 4)
        log.append([])
        #expect(log.headVersion == 0)
    }

    @Test("a reader one batch behind gets exactly that batch")
    func oneBehind() {
        var log = ChatChangeLog(capacity: 4)
        log.append(batch("a"))
        log.append(batch("b"))
        #expect(log.changes(since: 1) == .changes(batch("b"), through: 2))
    }

    @Test("a reader several batches behind gets all of them, flattened in order")
    func severalBehind() {
        var log = ChatChangeLog(capacity: 4)
        log.append(batch("a"))
        log.append([.appended(line("b")), .removed(id: "a")])
        log.append(batch("c"))
        #expect(log.changes(since: 0) == .changes(
            [.appended(line("a")), .appended(line("b")), .removed(id: "a"), .appended(line("c"))],
            through: 3
        ))
        #expect(log.changes(since: 3) == .changes([], through: 3))
    }

    @Test("eviction: the oldest retained version still replays, one older overruns")
    func eviction() {
        var log = ChatChangeLog(capacity: 2)
        for id in ["a", "b", "c", "d"] { log.append(batch(id)) }   // retains v3, v4
        #expect(log.headVersion == 4)
        #expect(log.changes(since: 2) == .changes(batch("c") + batch("d"), through: 4))
        #expect(log.changes(since: 1) == .overrun(head: 4))
        #expect(log.changes(since: 0) == .overrun(head: 4))
    }

    @Test("a version from the future overruns rather than replaying garbage")
    func futureVersion() {
        var log = ChatChangeLog(capacity: 4)
        log.append(batch("a"))
        #expect(log.changes(since: 7) == .overrun(head: 1))
    }

    @Test("two readers consume independently")
    func independentReaders() {
        var log = ChatChangeLog(capacity: 8)
        log.append(batch("a"))
        var listVersion = 0
        var threadVersion = 0
        if case .changes(_, let v) = log.changes(since: listVersion) { listVersion = v }
        log.append(batch("b"))
        #expect(log.changes(since: listVersion) == .changes(batch("b"), through: 2))
        #expect(log.changes(since: threadVersion) == .changes(batch("a") + batch("b"), through: 2))
        threadVersion = 2
        #expect(log.changes(since: threadVersion) == .changes([], through: 2))
    }
}
