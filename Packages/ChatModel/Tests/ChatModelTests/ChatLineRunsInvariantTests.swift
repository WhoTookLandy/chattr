import Testing
import Foundation
@testable import ChatModel

// MARK: - Runs-immutability invariant
//
// `ChatRow` (Features) renders a message's inline content with
//
//     ForEach(line.runs.indices, id: \.self) { idx in runView(for: line.runs[idx]) }
//
// i.e. it identifies each run by its POSITION. Index-as-identity is normally
// a SwiftUI anti-pattern (a reorder/insert silently re-associates row state),
// and it's only safe here because of one invariant: for a given `line.id`,
// `runs` never changes shape. A row is hosted in a recycling cell keyed by
// `line.id`; when the buffer publishes a `.reconfigured(line)` for an
// existing id (a delivery-state flip, or a moderator deletion), the runs
// array must stay identical — same count, same order, same contents — so the
// positional identity can't mis-associate a stateful run subview
// (`AnimatedImageView` / `LazyImage` for an emote) with a different run.
//
// These tests pin that invariant at its source. If a future feature (message
// edits, late-arriving emote resolution that patches runs in place) ever
// breaks it, these fail LOUDLY — which is the cue to switch `ChatRow` to a
// content-derived run id before the change ships, rather than discovering it
// as an emote flashing the wrong image in production.

private func sampleRuns() -> [LineRun] {
    [
        .text("hello"),
        .mention(login: "landy", isMe: true),
        .text("gg"),
        .url("https://twitch.tv/landy"),
    ]
}

private func sampleLine(deliveryState: ChatLine.DeliveryState = .delivered) -> ChatLine {
    ChatLine(
        id: "msg-1",
        kind: .message,
        authorDisplayName: "Landy",
        runs: sampleRuns(),
        deliveryState: deliveryState
    )
}

@Suite("ChatLine runs-immutability invariant (ChatRow index-ForEach safety)")
struct ChatLineRunsInvariantTests {

    @Test("markingDeleted preserves runs exactly, keeps the id, flips the kind")
    func deletionPreservesRuns() {
        let original = sampleLine()
        let deleted = original.markingDeleted()

        #expect(deleted.id == original.id, "a reconfigure must keep the same id")
        #expect(deleted.runs == original.runs, "deletion must preserve runs verbatim")
        #expect(deleted.runs.count == original.runs.count)
        if case .deletedPlaceholder = deleted.kind {} else {
            Issue.record("expected .deletedPlaceholder, got \(deleted.kind)")
        }
    }

    @Test("Delivery-state transitions leave runs and id untouched")
    func deliveryStateTransitionsPreserveRuns() {
        let original = sampleLine(deliveryState: .sending)
        let originalRuns = original.runs

        // `deliveryState` is a `var`; `runs` is a `let`, so each flip below
        // produces the same row (same id) with an unchanged runs array.
        var line = original
        for next: ChatLine.DeliveryState in [
            .delivered,
            .failed(reason: "msg_rejected", retryText: "Retry"),
            .sending,
        ] {
            line.deliveryState = next
            #expect(line.id == original.id)
            #expect(line.runs == originalRuns, "delivery-state flip must not touch runs")
        }
    }

    @Test("Deleting an already-deleted line is a no-op on runs (idempotent)")
    func doubleDeletionIsStable() {
        let deletedOnce = sampleLine().markingDeleted()
        let deletedTwice = deletedOnce.markingDeleted()
        #expect(deletedTwice.runs == deletedOnce.runs)
        #expect(deletedTwice == deletedOnce, "markingDeleted is idempotent")
    }
}
