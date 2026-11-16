import Testing
import Foundation
import Observation
import os
import TwitchKit
import ChatModel
import Channels
@testable import Features

/// Tests for `ChatTranscriptModel`'s coalesced publish surface: mutations
/// accumulate until one flush, readers replay every batch since their own
/// version, snapshots are version-consistent, and per-message ingest no
/// longer churns observation.
///
/// Events are driven through the internal `apply(_:)` (the live subscriber
/// entry point) on an un-attached model — ingest needs no session. The tests
/// are synchronous on the main actor, so the scheduled flush task can't run
/// mid-test; `flushPendingChanges()` flushes deterministically.
/// Flag for `withObservationTracking`'s @Sendable onChange. File scope (not
/// nested in the @MainActor suite) so it stays nonisolated.
private final class ObservationFired: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)
    var value: Bool {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}

@Suite("ChatTranscriptModel coalesced publishing")
@MainActor
struct ChatTranscriptModelPublishTests {

    /// Mirrors TwitchKit's wire decoding for `ChatMessage` (no memberwise init).
    private func chatMessage(id: String, userId: String = "u-1", text: String = "hello") -> ChatMessage {
        let json = """
        {
            "message_id": "\(id)",
            "broadcaster_user_id": "chan-1",
            "broadcaster_user_login": "somechannel",
            "broadcaster_user_name": "SomeChannel",
            "chatter_user_id": "\(userId)",
            "chatter_user_login": "chatter",
            "chatter_user_name": "Chatter",
            "message": {
                "text": "\(text)",
                "fragments": [{ "type": "text", "text": "\(text)" }]
            },
            "color": "",
            "badges": [],
            "message_type": "text"
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try! decoder.decode(ChatMessage.self, from: Data(json.utf8))
    }

    private func receive(_ model: ChatTranscriptModel, _ id: String) {
        model.apply(.normalizedMessage(chatMessage(id: id), timestamp: Date(timeIntervalSince1970: 0)))
    }

    @Test("many messages inside one window publish as ONE version")
    func coalescesIntoOneVersion() {
        let model = ChatTranscriptModel()
        for i in 0..<10 { receive(model, "m\(i)") }
        #expect(model.changeVersion == 0)          // nothing published yet…
        #expect(model.lines.count == 10)           // …but the buffer is current
        model.flushPendingChanges()
        #expect(model.changeVersion == 1)
        guard case .changes(let changes, let through) = model.changes(since: 0) else {
            Issue.record("expected a replay"); return
        }
        #expect(through == 1)
        #expect(changes.count == 10)
    }

    @Test("a reader that missed several flushes replays every batch, not just the latest")
    func readerReplaysAllBatches() {
        let model = ChatTranscriptModel()
        receive(model, "a"); model.flushPendingChanges()
        receive(model, "b"); model.flushPendingChanges()
        receive(model, "c"); model.flushPendingChanges()
        #expect(model.changeVersion == 3)
        guard case .changes(let changes, through: 3) = model.changes(since: 0) else {
            Issue.record("expected a replay through v3"); return
        }
        let appended = changes.compactMap { change -> String? in
            if case .appended(let line) = change { return line.id } else { return nil }
        }
        #expect(appended == ["a", "b", "c"])
    }

    @Test("a snapshot's lines match its version exactly: replaying after it never duplicates")
    func snapshotIsVersionConsistent() {
        let model = ChatTranscriptModel()
        receive(model, "a"); model.flushPendingChanges()
        receive(model, "b")                     // pending, not yet flushed
        let snap = model.transcriptSnapshot()
        #expect(snap.lines.map(\.id) == ["a", "b"])
        receive(model, "c")
        model.flushPendingChanges()
        #expect(model.changes(since: snap.version) == .changes([.appended(model.lines[2])], through: snap.version + 1))
    }

    @Test("a reader older than the retained log is told to reset")
    func overrunWhenTooFarBehind() {
        let model = ChatTranscriptModel()
        for i in 0..<(ChatChangeLog.defaultCapacity + 5) {
            receive(model, "m\(i)")
            model.flushPendingChanges()
        }
        guard case .overrun = model.changes(since: 1) else {
            Issue.record("expected .overrun"); return
        }
    }

    @Test("isEmpty flips synchronously on the first visible line")
    func isEmptyFlipsImmediately() {
        let model = ChatTranscriptModel()
        #expect(model.isEmpty)
        receive(model, "a")
        #expect(!model.isEmpty)
    }

    @Test("ingesting a message invalidates nothing until the flush")
    func ingestDoesNotChurnObservation() {
        let model = ChatTranscriptModel()
        receive(model, "first")          // isEmpty has already flipped
        model.flushPendingChanges()

        let fired = ObservationFired()
        withObservationTracking {
            _ = model.changeVersion
            _ = model.isEmpty
        } onChange: {
            fired.value = true
        }
        receive(model, "second")
        receive(model, "third")
        #expect(!fired.value)            // buffer is observation-ignored
        model.flushPendingChanges()
        #expect(fired.value)             // one coalesced publish
    }

    @Test("a flush with nothing pending doesn't bump the version")
    func emptyFlushIsNoOp() {
        let model = ChatTranscriptModel()
        model.flushPendingChanges()
        #expect(model.changeVersion == 0)
        receive(model, "a")
        model.flushPendingChanges()
        model.flushPendingChanges()
        #expect(model.changeVersion == 1)
    }

    @Test("the scheduled flush publishes on its own shortly after a burst")
    func scheduledFlushFires() async throws {
        let model = ChatTranscriptModel()
        for i in 0..<5 { receive(model, "m\(i)") }
        for _ in 0..<200 where model.changeVersion == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.changeVersion == 1)
    }
}
