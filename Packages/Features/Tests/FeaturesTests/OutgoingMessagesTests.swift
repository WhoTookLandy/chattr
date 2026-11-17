import Testing
import Foundation
import ChatModel
@testable import Features

/// The main-actor glue around `OutgoingMessageReconciler`: the single
/// stuck-send wake task and the row edits it applies. Runs on real time with
/// a short fallback timeout (the state machine itself is covered without
/// sleeping by `OutgoingMessageReconcilerTests`).
///
/// The limit is a hang guard, and it counts time spent queued for the main
/// actor. The whole target runs in parallel on one simulator, and on CI that
/// wait has run to about 90 seconds before these tests get their turn.
@Suite("OutgoingMessages stuck-send wake", .timeLimit(.minutes(5)))
@MainActor
struct OutgoingMessagesTests {

    private func make(timeout: Duration = .milliseconds(20)) -> (store: TranscriptStore, outgoing: OutgoingMessages) {
        let store = TranscriptStore()
        let outgoing = OutgoingMessages(
            store: store,
            reconciler: OutgoingMessageReconciler(fallbackTimeout: timeout)
        )
        return (store, outgoing)
    }

    private func optimisticRow(_ id: String) -> ChatLine {
        ChatLine(id: id, authorDisplayName: "me", runs: [.text("hi")], deliveryState: .sending)
    }

    /// Spin the main actor until `condition` holds (or give up after ~1s).
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    @Test("An accepted send whose echo never comes settles as delivered under its Helix id")
    func settlesAfterDeadline() async throws {
        let (store, outgoing) = make()
        let pendingId = outgoing.begin(text: "hi") { optimisticRow($0) }
        outgoing.accepted(pendingId: pendingId, messageId: "msg-1")

        try await waitUntil { store.deliveryState(ofRow: "msg-1") == .delivered }

        let settled = try #require(store.line(id: "msg-1"))
        #expect(settled.deliveryState == .delivered)
        #expect(!store.contains(id: pendingId))
        #expect(outgoing.isLocalOnly(settled), "a rebuild must carry the locally settled row")
    }

    @Test("Staggered deadlines both settle — the wake re-arms for the next one")
    func staggeredDeadlinesBothSettle() async throws {
        let (store, outgoing) = make(timeout: .milliseconds(30))
        let first = outgoing.begin(text: "one") { optimisticRow($0) }
        outgoing.accepted(pendingId: first, messageId: "msg-1")
        try await Task.sleep(for: .milliseconds(15))
        let second = outgoing.begin(text: "two") { optimisticRow($0) }
        outgoing.accepted(pendingId: second, messageId: "msg-2")

        try await waitUntil {
            store.deliveryState(ofRow: "msg-1") == .delivered
                && store.deliveryState(ofRow: "msg-2") == .delivered
        }

        #expect(store.deliveryState(ofRow: "msg-1") == .delivered)
        #expect(store.deliveryState(ofRow: "msg-2") == .delivered)
    }

    @Test("cancelFallbacks (detach) leaves the row sending")
    func cancelPreventsSettling() async throws {
        let (store, outgoing) = make()
        let pendingId = outgoing.begin(text: "hi") { optimisticRow($0) }
        outgoing.accepted(pendingId: pendingId, messageId: "msg-1")

        outgoing.cancelFallbacks()
        try await Task.sleep(for: .milliseconds(100))

        #expect(store.deliveryState(ofRow: pendingId) == .sending)
        #expect(!store.contains(id: "msg-1"))
    }

    @Test("A failed send turns its row .failed in place and never settles later")
    func failedRowStays() async throws {
        let (store, outgoing) = make()
        let pendingId = outgoing.begin(text: "hi") { optimisticRow($0) }

        outgoing.failed(pendingId: pendingId, reason: "slow mode", retryText: "hi")
        try await Task.sleep(for: .milliseconds(60))

        #expect(store.deliveryState(ofRow: pendingId) == .failed(reason: "slow mode", retryText: "hi"))
    }
}
