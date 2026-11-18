import Foundation

/// Where a session's join-time history fetch stands, and what `start()`'s
/// bounded wait for it does next.
///
/// `start()` subscribes to live chat first and buffers it while the history
/// fetch runs, then waits for the history — but no later than a deadline.
/// Whichever happens first (the history lands, the deadline passes, the
/// start is cancelled, the session stops) decides the outcome. Every
/// transition is one synchronous step on the session actor, so "the deadline
/// passed" and "the history arrived" can't both claim it.
///
/// A value type owned by (and only ever mutated inside) `ChannelSession`.
/// It holds no task and no continuation: the session keeps the fetch, the
/// deadline timer and the parked `start()`, and does what each transition
/// here tells it to.
struct JoinBackfillWait {

    enum Phase {
        /// No fetch started (tests drive `applyBackfill` directly).
        case idle
        /// In flight; `start()` may be waiting on it.
        case fetching
        /// Landed before `start()` stopped waiting; not yet applied.
        case arrived([BackfillMessage])
        /// `start()` gave up waiting and exposed the session; a late arrival
        /// is merged in above the live rows.
        case abandoned
        /// Applied (on time, late, or as empty), or given up on by `stop()`.
        case done
    }

    /// What the session does with history that just came back.
    enum Arrival: Equatable {
        /// In time: kept for `settle()`. Wake `start()` if it is parked.
        case onTime
        /// After `start()` stopped waiting: merge it above the live rows.
        case late
        /// Nothing is waiting for it (never begun, a second answer, or the
        /// session stopped): drop it.
        case unwanted
    }

    /// What `start()` commits once it is done waiting.
    enum Outcome {
        /// History then the buffered live rows. Empty when no fetch was
        /// ever begun.
        case commit([BackfillMessage])
        /// The history isn't back: the buffered live rows alone. If it still
        /// lands, `historyArrived` reports it `.late`.
        case openWithoutHistory
        /// Already committed, or stopped: nothing to do.
        case alreadySettled
    }

    private(set) var phase: Phase = .idle

    /// When `start()` stops waiting, measured from when the fetch began.
    private(set) var deadline: ContinuousClock.Instant?

    /// True while the session holds a parked `start()` it hasn't resumed.
    private(set) var isWaiterParked = false

    /// The fetch is starting. False, changing nothing, unless this is the
    /// first one.
    mutating func begin(deadline: ContinuousClock.Instant) -> Bool {
        guard case .idle = phase else { return false }
        phase = .fetching
        self.deadline = deadline
        return true
    }

    /// The instant `start()` should park until, or nil when it must not
    /// park: nothing is in flight, a `start()` is parked already (one
    /// waiter — never overwrite one), or the start was cancelled.
    func deadlineToWaitFor(isCancelled: Bool) -> ContinuousClock.Instant? {
        guard case .fetching = phase, !isWaiterParked, !isCancelled else { return nil }
        return deadline
    }

    /// The session stored the continuation of a `start()` it just parked.
    mutating func parkWaiter() {
        isWaiterParked = true
    }

    /// Whether the session must resume the parked `start()` now. True at
    /// most once per parked waiter, whoever asks first: the history, the
    /// deadline timer, a cancelled start or `stop()`.
    mutating func releaseWaiter() -> Bool {
        guard isWaiterParked else { return false }
        isWaiterParked = false
        return true
    }

    /// The fetch answered.
    mutating func historyArrived(_ history: [BackfillMessage]) -> Arrival {
        switch phase {
        case .fetching:
            phase = .arrived(history)
            return .onTime
        case .abandoned:
            phase = .done
            return .late
        case .idle, .arrived, .done:
            return .unwanted
        }
    }

    /// `start()` is done waiting (or never waited): whatever state this
    /// finds is the outcome.
    mutating func settle() -> Outcome {
        switch phase {
        case .arrived(let history):
            phase = .done
            return .commit(history)
        case .fetching:
            phase = .abandoned
            return .openWithoutHistory
        case .idle:
            phase = .done
            return .commit([])
        case .abandoned, .done:
            return .alreadySettled
        }
    }

    /// The buffering window was committed directly (`applyBackfill`).
    mutating func markApplied() {
        phase = .done
    }

    /// The session stopped: a fetch that completes anyway is not merged.
    /// The session releases a parked `start()` separately.
    mutating func stop() {
        phase = .done
    }

    /// The join history has been applied or merged (or given up on by
    /// `stop()`) — nothing more will come of it.
    var isSettled: Bool {
        if case .done = phase { return true }
        return false
    }
}
