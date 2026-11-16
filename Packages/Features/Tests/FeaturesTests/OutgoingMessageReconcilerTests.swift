import Testing
import Foundation
import ChatModel
@testable import Features

/// The optimistic-send state machine, driven synchronously: a fake transcript
/// (`rows`, id → delivery state) stands in for the buffer, and a manual clock
/// stands in for time, so every race ordering between the Helix response,
/// the EventSub echo, and the stuck-send deadline is reproducible.
@Suite("OutgoingMessageReconciler")
struct OutgoingMessageReconcilerTests {

    /// Deadline clock the tests advance by hand.
    private final class ManualClock {
        var now = ContinuousClock().now
        func advance(by duration: Duration) { now = now.advanced(by: duration) }
    }

    /// Deterministic pending ids: pending-1, pending-2, …
    private final class IdSequence {
        private var next = 0
        func make() -> String {
            next += 1
            return "pending-\(next)"
        }
    }

    private let clock = ManualClock()
    private let ids = IdSequence()

    private func makeReconciler(timeout: Duration = .seconds(5)) -> OutgoingMessageReconciler {
        let clock = self.clock
        let ids = self.ids
        return OutgoingMessageReconciler(
            fallbackTimeout: timeout,
            now: { clock.now },
            makePendingId: { ids.make() }
        )
    }

    /// Starts a send the way the model does: track it, then show its
    /// optimistic row.
    private func begin(
        _ text: String,
        _ reconciler: inout OutgoingMessageReconciler,
        _ rows: inout [String: ChatLine.DeliveryState]
    ) -> String {
        let pendingId = reconciler.begin(text: text)
        rows[pendingId] = .sending
        return pendingId
    }

    // MARK: - Begin

    @Test("begin mints the row id from the factory and starts tracking the send")
    func beginTracks() {
        var reconciler = makeReconciler()
        let first = reconciler.begin(text: "hello")
        let second = reconciler.begin(text: "hello")
        #expect(first == "pending-1")
        #expect(second == "pending-2")
        #expect(reconciler.isTracking(first))
        #expect(reconciler.isTracking(second))
        #expect(reconciler.nextFallbackDeadline == nil, "nothing is armed before Helix accepts")
    }

    // MARK: - Path 2: echo beats the Helix response

    @Test("An own echo that beats Helix upgrades the pending row by text and settles the send")
    func echoBeforeHelixMatchesByText() {
        var reconciler = makeReconciler()
        var rows: [String: ChatLine.DeliveryState] = [:]
        let pendingId = begin("hello", &reconciler, &rows)

        let match = reconciler.matchEcho(messageId: "msg-1", text: "hello", isOwn: true) { rows[$0] }

        #expect(match == .upgrade(pendingId: pendingId))
        #expect(!reconciler.isTracking(pendingId))
    }

    @Test("Text matching trims the echo the way the send was trimmed")
    func echoTextIsTrimmed() {
        var reconciler = makeReconciler()
        var rows: [String: ChatLine.DeliveryState] = [:]
        let pendingId = begin("hello", &reconciler, &rows)

        let match = reconciler.matchEcho(messageId: "msg-1", text: " hello\n", isOwn: true) { rows[$0] }

        #expect(match == .upgrade(pendingId: pendingId))
    }

    @Test("Someone else's identical text never matches a pending send")
    func foreignTextDoesNotMatch() {
        var reconciler = makeReconciler()
        var rows: [String: ChatLine.DeliveryState] = [:]
        let pendingId = begin("gg", &reconciler, &rows)

        let match = reconciler.matchEcho(messageId: "msg-x", text: "gg", isOwn: false) { rows[$0] }

        #expect(match == .unmatched)
        #expect(reconciler.isTracking(pendingId))
    }

    @Test("Identical double-sends reconcile in FIFO order — echo N upgrades row N")
    func identicalSendsAreFIFO() {
        var reconciler = makeReconciler()
        var rows: [String: ChatLine.DeliveryState] = [:]
        let first = begin("lol", &reconciler, &rows)
        let second = begin("lol", &reconciler, &rows)

        let echo1 = reconciler.matchEcho(messageId: "msg-1", text: "lol", isOwn: true) { rows[$0] }
        rows[first] = nil
        rows["msg-1"] = .delivered
        let echo2 = reconciler.matchEcho(messageId: "msg-2", text: "lol", isOwn: true) { rows[$0] }

        #expect(echo1 == .upgrade(pendingId: first))
        #expect(echo2 == .upgrade(pendingId: second))
        #expect(!reconciler.isTracking(first))
        #expect(!reconciler.isTracking(second))
    }

    // MARK: - Path 0: Helix responds first

    @Test("After Helix accepts, the echo matches by message id and disarms the fallback")
    func echoAfterHelixMatchesById() {
        var reconciler = makeReconciler()
        var rows: [String: ChatLine.DeliveryState] = [:]
        let pendingId = begin("hello", &reconciler, &rows)

        let armed = reconciler.accepted(pendingId: pendingId, messageId: "msg-1") { rows[$0] }
        #expect(armed)
        #expect(reconciler.nextFallbackDeadline == clock.now.advanced(by: .seconds(5)))

        // Twitch may rewrite the text (e.g. collapse whitespace); the id
        // still matches.
        let match = reconciler.matchEcho(messageId: "msg-1", text: "hello  ", isOwn: true) { rows[$0] }

        #expect(match == .upgrade(pendingId: pendingId))
        #expect(!reconciler.isTracking(pendingId))
        #expect(reconciler.nextFallbackDeadline == nil)
    }

    @Test("Mixed race: B's Helix response lands first, then A's echo (by text), then B's (by id)")
    func mixedRaceDoesNotCrossWire() {
        var reconciler = makeReconciler()
        var rows: [String: ChatLine.DeliveryState] = [:]
        let a = begin("lol", &reconciler, &rows)
        let b = begin("lol", &reconciler, &rows)
        reconciler.accepted(pendingId: b, messageId: "msg-b") { rows[$0] }

        let echoA = reconciler.matchEcho(messageId: "msg-a", text: "lol", isOwn: true) { rows[$0] }
        rows[a] = nil
        rows["msg-a"] = .delivered
        let echoB = reconciler.matchEcho(messageId: "msg-b", text: "lol", isOwn: true) { rows[$0] }

        #expect(echoA == .upgrade(pendingId: a))
        #expect(echoB == .upgrade(pendingId: b))
    }

    @Test("Helix accepting after the echo already reconciled settles instead of arming a dead letter")
    func acceptAfterEchoSettles() {
        var reconciler = makeReconciler()
        var rows: [String: ChatLine.DeliveryState] = [:]
        let pendingId = begin("hello", &reconciler, &rows)
        _ = reconciler.matchEcho(messageId: "msg-1", text: "hello", isOwn: true) { rows[$0] }
        rows[pendingId] = nil
        rows["msg-1"] = .delivered

        let armed = reconciler.accepted(pendingId: pendingId, messageId: "msg-1") { rows[$0] }

        #expect(!armed)
        #expect(!reconciler.isTracking(pendingId))
        #expect(reconciler.nextFallbackDeadline == nil)
    }

    @Test("An id match whose row is gone settles the send and falls through to an append")
    func idMatchWithoutRowFallsThrough() {
        var reconciler = makeReconciler()
        var rows: [String: ChatLine.DeliveryState] = [:]
        let pendingId = begin("hello", &reconciler, &rows)
        reconciler.accepted(pendingId: pendingId, messageId: "msg-1") { rows[$0] }
        rows[pendingId] = nil   // removed under us

        let match = reconciler.matchEcho(messageId: "msg-1", text: "hello", isOwn: true) { rows[$0] }

        #expect(match == .unmatched)
        #expect(!reconciler.isTracking(pendingId))
    }

    // MARK: - Path 1: duplicates

    @Test("A message whose id is already a row is a duplicate")
    func duplicateById() {
        var reconciler = makeReconciler()
        let rows: [String: ChatLine.DeliveryState] = ["msg-1": .delivered]

        let match = reconciler.matchEcho(messageId: "msg-1", text: "hi", isOwn: false) { rows[$0] }

        #expect(match == .duplicate)
    }

    @Test("A foreign message with no pending sends is unmatched")
    func foreignMessageUnmatched() {
        var reconciler = makeReconciler()
        let rows: [String: ChatLine.DeliveryState] = [:]
        let match = reconciler.matchEcho(messageId: "m", text: "hi", isOwn: false) { rows[$0] }
        #expect(match == .unmatched)
    }

    // MARK: - Failure

    @Test("A failed send stops correlating: its echo no longer upgrades the failed row")
    func failedSendIsForgotten() {
        var reconciler = makeReconciler()
        var rows: [String: ChatLine.DeliveryState] = [:]
        let pendingId = begin("hello", &reconciler, &rows)

        reconciler.failed(pendingId: pendingId)
        rows[pendingId] = .failed(reason: "slow mode", retryText: "hello")

        #expect(!reconciler.isTracking(pendingId))
        let match = reconciler.matchEcho(messageId: "msg-1", text: "hello", isOwn: true) { rows[$0] }
        #expect(match == .unmatched)
    }

    // MARK: - Stuck-send fallback

    @Test("Nothing is due before the deadline; at it, the row settles locally under the Helix id")
    func fallbackSettlesAtDeadline() {
        var reconciler = makeReconciler()
        var rows: [String: ChatLine.DeliveryState] = [:]
        let pendingId = begin("hello", &reconciler, &rows)
        reconciler.accepted(pendingId: pendingId, messageId: "msg-1") { rows[$0] }

        clock.advance(by: .milliseconds(4_999))
        let early = reconciler.nextDueFallback { rows[$0] }
        #expect(early == nil)
        #expect(reconciler.isTracking(pendingId), "an early check must not disarm the send")

        clock.advance(by: .milliseconds(1))
        let outcome = reconciler.nextDueFallback { rows[$0] }

        #expect(outcome == .settleLocally(pendingId: pendingId, messageId: "msg-1"))
        #expect(reconciler.locallySettledIds == ["msg-1"])
        #expect(!reconciler.isTracking(pendingId))
        #expect(reconciler.nextFallbackDeadline == nil)
        let again = reconciler.nextDueFallback { rows[$0] }
        #expect(again == nil)
    }

    @Test("A late echo after a local settlement is a duplicate of the settled row")
    func lateEchoAfterFallbackIsDuplicate() {
        var reconciler = makeReconciler()
        var rows: [String: ChatLine.DeliveryState] = [:]
        let pendingId = begin("hello", &reconciler, &rows)
        reconciler.accepted(pendingId: pendingId, messageId: "msg-1") { rows[$0] }
        clock.advance(by: .seconds(5))
        _ = reconciler.nextDueFallback { rows[$0] }
        rows[pendingId] = nil
        rows["msg-1"] = .delivered

        let match = reconciler.matchEcho(messageId: "msg-1", text: "hello", isOwn: true) { rows[$0] }
        #expect(match == .duplicate)
    }

    @Test("If the Helix id is already on a row, the fallback drops the optimistic row instead of duplicating")
    func fallbackDropsWhenIdExists() {
        var reconciler = makeReconciler()
        var rows: [String: ChatLine.DeliveryState] = [:]
        let pendingId = begin("hello", &reconciler, &rows)
        reconciler.accepted(pendingId: pendingId, messageId: "msg-1") { rows[$0] }
        rows["msg-1"] = .delivered

        clock.advance(by: .seconds(5))
        let outcome = reconciler.nextDueFallback { rows[$0] }

        #expect(outcome == .dropOptimistic(pendingId: pendingId, messageId: "msg-1"))
        #expect(reconciler.locallySettledIds.isEmpty)
        #expect(!reconciler.isTracking(pendingId))
    }

    @Test("A due send whose row is no longer sending is just disarmed")
    func fallbackSkipsSettledRow() {
        var reconciler = makeReconciler()
        var rows: [String: ChatLine.DeliveryState] = [:]
        let pendingId = begin("hello", &reconciler, &rows)
        reconciler.accepted(pendingId: pendingId, messageId: "msg-1") { rows[$0] }
        rows[pendingId] = .failed(reason: "x", retryText: "hello")

        clock.advance(by: .seconds(5))
        let outcome = reconciler.nextDueFallback { rows[$0] }

        #expect(outcome == nil)
        #expect(reconciler.nextFallbackDeadline == nil)
    }

    @Test("Several due sends come out one at a time, most overdue first")
    func multipleDueInDeadlineOrder() {
        var reconciler = makeReconciler()
        var rows: [String: ChatLine.DeliveryState] = [:]
        let first = begin("one", &reconciler, &rows)
        reconciler.accepted(pendingId: first, messageId: "msg-1") { rows[$0] }
        clock.advance(by: .seconds(1))
        let second = begin("two", &reconciler, &rows)
        reconciler.accepted(pendingId: second, messageId: "msg-2") { rows[$0] }
        #expect(reconciler.nextFallbackDeadline == clock.now.advanced(by: .seconds(4)))

        clock.advance(by: .seconds(10))
        let a = reconciler.nextDueFallback { rows[$0] }
        rows[first] = nil
        rows["msg-1"] = .delivered
        let b = reconciler.nextDueFallback { rows[$0] }
        rows[second] = nil
        rows["msg-2"] = .delivered
        let c = reconciler.nextDueFallback { rows[$0] }

        #expect(a == .settleLocally(pendingId: first, messageId: "msg-1"))
        #expect(b == .settleLocally(pendingId: second, messageId: "msg-2"))
        #expect(c == nil)
    }

    @Test("cancelFallbacks disarms deadlines but keeps the id key, so a late echo still matches")
    func cancelKeepsCorrelation() {
        var reconciler = makeReconciler()
        var rows: [String: ChatLine.DeliveryState] = [:]
        let pendingId = begin("hello", &reconciler, &rows)
        reconciler.accepted(pendingId: pendingId, messageId: "msg-1") { rows[$0] }

        reconciler.cancelFallbacks()
        clock.advance(by: .seconds(30))

        let due = reconciler.nextDueFallback { rows[$0] }
        let match = reconciler.matchEcho(messageId: "msg-1", text: "different", isOwn: true) { rows[$0] }

        #expect(reconciler.nextFallbackDeadline == nil)
        #expect(due == nil)
        #expect(match == .upgrade(pendingId: pendingId))
    }

    // MARK: - Rebuild support

    @Test("An echo inside a rebuild snapshot settles its send by id, else by own text")
    func settlePendingAnsweredBy() {
        var reconciler = makeReconciler()
        var rows: [String: ChatLine.DeliveryState] = [:]
        let byId = begin("one", &reconciler, &rows)
        reconciler.accepted(pendingId: byId, messageId: "msg-1") { rows[$0] }
        let byText = begin("two", &reconciler, &rows)

        let answeredById = reconciler.settlePending(answeredBy: "msg-1", text: "ignored", isOwn: true)
        let foreign = reconciler.settlePending(answeredBy: "msg-x", text: "two", isOwn: false)
        let answeredByText = reconciler.settlePending(answeredBy: "msg-2", text: "two ", isOwn: true)

        #expect(answeredById == byId)
        #expect(foreign == nil)
        #expect(answeredByText == byText)
        #expect(!reconciler.isTracking(byId))
        #expect(!reconciler.isTracking(byText))
    }

    @Test("Local-only rows: anything not delivered, plus locally settled deliveries; pruning keeps present ids")
    func localOnlyRows() {
        var reconciler = makeReconciler()
        var rows: [String: ChatLine.DeliveryState] = [:]
        let pendingId = begin("hello", &reconciler, &rows)
        reconciler.accepted(pendingId: pendingId, messageId: "msg-1") { rows[$0] }
        clock.advance(by: .seconds(5))
        _ = reconciler.nextDueFallback { rows[$0] }

        func line(_ id: String, _ state: ChatLine.DeliveryState) -> ChatLine {
            ChatLine(id: id, authorDisplayName: "me", runs: [.text("x")], deliveryState: state)
        }
        #expect(reconciler.isLocalOnly(line("pending-9", .sending)))
        #expect(reconciler.isLocalOnly(line("pending-8", .failed(reason: "r", retryText: "t"))))
        #expect(reconciler.isLocalOnly(line("msg-1", .delivered)))
        #expect(!reconciler.isLocalOnly(line("msg-2", .delivered)))

        reconciler.pruneLocallySettled { $0 != "msg-1" }
        #expect(reconciler.locallySettledIds.isEmpty)

        reconciler.forgetLocallySettled()
        #expect(reconciler.locallySettledIds.isEmpty)
    }
}
