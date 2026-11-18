import Testing
import Foundation
import TwitchKit
@testable import Channels

/// The join-history wait as a state machine, with no session, task or
/// continuation: every transition `ChannelSession` drives it through, and
/// what each one tells the session to do.
@Suite("JoinBackfillWait")
struct JoinBackfillWaitTests {

    private func record(_ id: String) -> BackfillMessage {
        let line = "@id=\(id);room-id=1;user-id=2 :nick!nick@nick.tmi.twitch.tv PRIVMSG #ch :hi"
        return BackfillMessage(message: IRCMessageParser.parse(line, channelLogin: "ch")!, sentAt: nil)
    }

    let deadline: ContinuousClock.Instant = ContinuousClock.now + Duration.seconds(3)

    /// A readable name for the phase (its payload isn't `Equatable`).
    private func name(_ phase: JoinBackfillWait.Phase) -> String {
        switch phase {
        case .idle: return "idle"
        case .fetching: return "fetching"
        case .arrived(let history): return "arrived(\(history.count))"
        case .abandoned: return "abandoned"
        case .done: return "done"
        }
    }

    /// The outcome as text: `commit:` plus the committed ids, or the case.
    private func name(_ outcome: JoinBackfillWait.Outcome) -> String {
        switch outcome {
        case .commit(let history): return "commit:" + history.map(\.message.messageId).joined(separator: ",")
        case .openWithoutHistory: return "openWithoutHistory"
        case .alreadySettled: return "alreadySettled"
        }
    }

    /// A wait whose fetch has begun.
    private func fetching() -> JoinBackfillWait {
        var wait = JoinBackfillWait()
        _ = wait.begin(deadline: deadline)
        return wait
    }

    @Test("Starts idle: no deadline, nobody parked, not settled")
    func startsIdle() {
        let wait = JoinBackfillWait()
        #expect(name(wait.phase) == "idle")
        #expect(wait.deadline == nil)
        #expect(!wait.isWaiterParked)
        #expect(!wait.isSettled)
    }

    @Test("Only the first begin starts a fetch; a second one changes nothing")
    func beginsOnce() {
        var wait = JoinBackfillWait()
        let began = wait.begin(deadline: deadline)
        #expect(began)
        #expect(name(wait.phase) == "fetching")
        #expect(wait.deadline == deadline)

        let beganAgain = wait.begin(deadline: deadline + Duration.seconds(60))
        #expect(!beganAgain)
        #expect(wait.deadline == deadline)
    }

    @Test("start() parks only while the fetch is in flight, nobody is parked and it isn't cancelled")
    func parksOnlyWhenThereIsSomethingToWaitFor() {
        // Never begun: nothing to wait for.
        let idle = JoinBackfillWait()
        #expect(idle.deadlineToWaitFor(isCancelled: false) == nil)

        var wait = fetching()
        #expect(wait.deadlineToWaitFor(isCancelled: false) == deadline)
        // A cancelled start must not sit out the deadline.
        #expect(wait.deadlineToWaitFor(isCancelled: true) == nil)

        // One waiter: a second finish never overwrites the parked one.
        wait.parkWaiter()
        #expect(wait.isWaiterParked)
        #expect(wait.deadlineToWaitFor(isCancelled: false) == nil)

        // History already back: commit straight away.
        var arrived = fetching()
        _ = arrived.historyArrived([record("h1")])
        #expect(arrived.deadlineToWaitFor(isCancelled: false) == nil)
    }

    @Test("History that lands during the wait wakes start() once and is what it commits")
    func historyDuringTheWait() {
        var wait = fetching()
        wait.parkWaiter()

        let arrival = wait.historyArrived([record("h1"), record("h2")])
        #expect(arrival == .onTime)
        #expect(name(wait.phase) == "arrived(2)")
        let woke = wait.releaseWaiter()
        #expect(woke)
        // The deadline timer (or a cancel) firing afterwards resumes nothing.
        let wokeAgain = wait.releaseWaiter()
        #expect(!wokeAgain)

        let outcome = wait.settle()
        #expect(name(outcome) == "commit:h1,h2")
        #expect(wait.isSettled)
    }

    @Test("History that lands before start() reaches the wait is committed without parking")
    func historyBeforeTheWait() {
        var wait = fetching()
        let arrival = wait.historyArrived([record("h1")])
        #expect(arrival == .onTime)
        // Nobody is parked yet, so there is nobody to resume.
        let woke = wait.releaseWaiter()
        #expect(!woke)
        #expect(wait.deadlineToWaitFor(isCancelled: false) == nil)

        let outcome = wait.settle()
        #expect(name(outcome) == "commit:h1")
        #expect(wait.isSettled)
    }

    @Test("Deadline first: start() opens without history, and the late answer is merged exactly once")
    func historyAfterTheTimeout() {
        var wait = fetching()
        wait.parkWaiter()

        // The deadline timer wakes start().
        let woke = wait.releaseWaiter()
        #expect(woke)
        let outcome = wait.settle()
        #expect(name(outcome) == "openWithoutHistory")
        #expect(name(wait.phase) == "abandoned")
        #expect(!wait.isSettled)

        // The history lands afterwards: nobody to wake, merge it late.
        let arrival = wait.historyArrived([record("h1")])
        #expect(arrival == .late)
        let wokeAgain = wait.releaseWaiter()
        #expect(!wokeAgain)
        #expect(wait.isSettled)

        // Nothing more comes of it.
        let secondArrival = wait.historyArrived([record("h1")])
        #expect(secondArrival == .unwanted)
        let secondOutcome = wait.settle()
        #expect(name(secondOutcome) == "alreadySettled")
    }

    @Test("A cancelled start opens without history at once; a fetch that still answers merges late")
    func cancelledStart() {
        var wait = fetching()
        #expect(wait.deadlineToWaitFor(isCancelled: true) == nil)
        let outcome = wait.settle()
        #expect(name(outcome) == "openWithoutHistory")

        let arrival = wait.historyArrived([record("h1")])
        #expect(arrival == .late)
        #expect(wait.isSettled)
    }

    @Test("A start cancelled while parked is woken once, by the cancel or the timer, never both")
    func cancelWhileParked() {
        var wait = fetching()
        wait.parkWaiter()
        let wokenByCancel = wait.releaseWaiter()
        let wokenByTimer = wait.releaseWaiter()
        #expect(wokenByCancel)
        #expect(!wokenByTimer)

        let outcome = wait.settle()
        #expect(name(outcome) == "openWithoutHistory")
    }

    @Test("stop() during the wait releases start() once, commits nothing and drops a late answer")
    func stopDuringTheWait() {
        var wait = fetching()
        wait.parkWaiter()

        wait.stop()
        #expect(wait.isSettled)
        let woke = wait.releaseWaiter()
        let wokeAgain = wait.releaseWaiter()
        #expect(woke)
        #expect(!wokeAgain)

        // The released start() finds nothing to commit...
        let outcome = wait.settle()
        #expect(name(outcome) == "alreadySettled")
        // ...and a fetch that completes anyway is not merged.
        let arrival = wait.historyArrived([record("h1")])
        #expect(arrival == .unwanted)
        #expect(wait.isSettled)
    }

    @Test("stop() after the deadline drops the late answer")
    func stopAfterTheTimeout() {
        var wait = fetching()
        _ = wait.settle()
        #expect(name(wait.phase) == "abandoned")

        wait.stop()
        let arrival = wait.historyArrived([record("h1")])
        #expect(arrival == .unwanted)
    }

    @Test("stop() with history already back never commits it")
    func stopWithHistoryArrived() {
        var wait = fetching()
        _ = wait.historyArrived([record("h1")])
        wait.stop()
        let outcome = wait.settle()
        #expect(name(outcome) == "alreadySettled")
    }

    @Test("No fetch begun: settling commits an empty history")
    func settleWithoutFetch() {
        var wait = JoinBackfillWait()
        let outcome = wait.settle()
        #expect(name(outcome) == "commit:")
        #expect(wait.isSettled)

        let secondOutcome = wait.settle()
        #expect(name(secondOutcome) == "alreadySettled")
    }

    @Test("History nobody asked for is dropped")
    func historyWithoutFetch() {
        var wait = JoinBackfillWait()
        let arrival = wait.historyArrived([record("h1")])
        #expect(arrival == .unwanted)
        #expect(name(wait.phase) == "idle")
    }

    @Test("A second answer while the first waits to be committed doesn't replace it")
    func secondAnswerBeforeCommit() {
        var wait = fetching()
        _ = wait.historyArrived([record("h1")])
        let arrival = wait.historyArrived([record("other")])
        #expect(arrival == .unwanted)

        let outcome = wait.settle()
        #expect(name(outcome) == "commit:h1")
    }

    @Test("A direct apply settles the wait from any phase, and no fetch begins after it")
    func markAppliedSettles() {
        var idle = JoinBackfillWait()
        idle.markApplied()
        #expect(idle.isSettled)
        let began = idle.begin(deadline: deadline)
        #expect(!began)
        let outcome = idle.settle()
        #expect(name(outcome) == "alreadySettled")

        var inFlight = fetching()
        inFlight.markApplied()
        #expect(inFlight.isSettled)
        let arrival = inFlight.historyArrived([record("h1")])
        #expect(arrival == .unwanted)
    }
}
