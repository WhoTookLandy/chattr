import Testing
import Foundation
@testable import Channels

/// `LiveEventsHub` with no session and no network: the mailbox fan-out, the
/// foreground gate, and the bookkeeping that decides whether a Helix
/// reconcile, the periodic check or a poll-deadline fetch may start. Tasks
/// the session would hand it are stood in for by parked ones.
@Suite("LiveEventsHub", .timeLimit(.minutes(1)))
struct LiveEventsHubTests {

    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeHub(
        isOwnChannel: Bool = true,
        foreground: AppForegroundSignal = AppForegroundSignal()
    ) -> LiveEventsHub {
        LiveEventsHub(isOwnChannel: isOwnChannel, appForeground: foreground)
    }

    private func activePoll(id: String = "poll-1", endsAt: Date? = nil) -> LiveEventUpdate {
        .poll(LivePoll(
            id: id,
            title: "Best map?",
            choices: [LivePoll.Choice(id: "a", title: "A", votes: 0)],
            startedAt: t0,
            endsAt: endsAt
        ))
    }

    private func endedPoll(id: String = "poll-1") -> LiveEventUpdate {
        .poll(LivePoll(
            id: id,
            title: "Best map?",
            choices: [LivePoll.Choice(id: "a", title: "A", votes: 3)],
            startedAt: t0,
            status: .completed
        ))
    }

    /// Stands in for a task the session started: runs until cancelled.
    private func parkedTask() -> Task<Void, Never> {
        Task {
            _ = try? await Task.sleep(for: .seconds(3_600))
        }
    }

    /// Returns only once `subscription`'s stream has ended (the suite's
    /// time limit bounds a stream nothing finished).
    private func drainUntilFinished(_ subscription: LiveEventsSubscription) async {
        for await _ in subscription.wakeups {}
    }

    // MARK: - Subscribers + reduce

    @Test("A consumer is primed with the current state and gets each change after it")
    func subscribersArePrimedThenPosted() {
        var hub = makeHub()
        hub.apply(activePoll(), now: t0)

        let (subscription, pruned) = hub.subscribe(now: t0)
        #expect(!pruned)
        #expect(subscription.takeLatest()?.poll?.id == "poll-1")
        #expect(subscription.takeLatest() == nil)

        let changed = hub.apply(endedPoll(), now: t0)
        #expect(changed)
        #expect(subscription.takeLatest()?.poll?.status == .completed)
        #expect(hub.state.poll?.status == .completed)
    }

    @Test("An update that changes nothing posts nothing")
    func unchangedUpdateIsSilent() {
        var hub = makeHub()
        hub.apply(activePoll(), now: t0)
        let (subscription, _) = hub.subscribe(now: t0)
        _ = subscription.takeLatest()

        let changed = hub.apply(activePoll(), now: t0)
        #expect(!changed)
        #expect(subscription.takeLatest() == nil)
    }

    @Test("Subscribing drops a result that has lingered long enough, and says so")
    func subscribePrunes() {
        var hub = makeHub()
        hub.apply(activePoll(), now: t0)
        hub.apply(endedPoll(), now: t0)

        let later = t0.addingTimeInterval(LiveEventsState.resultLinger + 1)
        let (subscription, pruned) = hub.subscribe(now: later)
        #expect(pruned)
        #expect(subscription.takeLatest()?.isEmpty == true)
    }

    @Test("An unsubscribed consumer's stream ends and it gets nothing more")
    func unsubscribeFinishes() async {
        var hub = makeHub()
        let (subscription, _) = hub.subscribe(now: t0)
        _ = subscription.takeLatest()

        hub.unsubscribe(subscription.token)
        hub.unsubscribe(subscription.token)   // idempotent
        hub.apply(activePoll(), now: t0)

        await drainUntilFinished(subscription)
        #expect(subscription.takeLatest() == nil)
    }

    @Test("A Helix snapshot is folded in and posted like an EventSub update")
    func reconcilePublishes() {
        var hub = makeHub()
        let (subscription, _) = hub.subscribe(now: t0)
        _ = subscription.takeLatest()

        let changed = hub.reconcile(.poll, snapshot: activePoll(), fetchedAt: t0, now: t0)
        #expect(changed)
        #expect(subscription.takeLatest()?.poll?.id == "poll-1")

        // Helix now reports nothing running, and nothing confirmed the poll
        // since that fetch began: it is cleared.
        let later = t0.addingTimeInterval(60)
        let cleared = hub.reconcile(.poll, snapshot: nil, fetchedAt: later, now: later)
        #expect(cleared)
        #expect(subscription.takeLatest()?.isEmpty == true)
    }

    // MARK: - Stop

    @Test("stop() ends every consumer, cancels the hub's tasks and refuses everything after it")
    func stopShutsEverythingDown() async {
        var hub = makeHub()
        hub.apply(activePoll(), now: t0)
        let (subscription, _) = hub.subscribe(now: t0)
        let startup = parkedTask()
        let verify = parkedTask()
        let pass = parkedTask()
        hub.startupStarted(startup)
        hub.verificationStarted(verify)
        hub.reconcilePassStarted(pass)

        hub.stop()

        #expect(hub.isStopped)
        await drainUntilFinished(subscription)
        #expect(startup.isCancelled)
        #expect(verify.isCancelled)
        #expect(pass.isCancelled)
        #expect(hub.startupTask == nil)
        #expect(!hub.isVerifying)
        // Only the pass clears its own handle, when it exits.
        #expect(hub.reconcileTask != nil)

        #expect(!hub.canFetch)
        #expect(!hub.wantsVerification)
        let request = hub.requestReconcile()
        #expect(request == .refused)
        let deadlineRequest = hub.takePollDeadlineRequest()
        #expect(deadlineRequest == nil)

        // A Helix answer that lands after the stop is dropped.
        let changed = hub.reconcile(.poll, snapshot: nil, fetchedAt: t0.addingTimeInterval(60), now: t0.addingTimeInterval(60))
        #expect(!changed)
        #expect(hub.state.poll?.id == "poll-1")

        // A consumer that subscribes now gets a stream that has already
        // ended, still carrying the last state.
        let (late, _) = hub.subscribe(now: t0)
        await drainUntilFinished(late)
        #expect(late.takeLatest()?.poll?.id == "poll-1")

        let exited = hub.reconcilePassFinished()
        #expect(!exited)
        #expect(hub.reconcileTask == nil)
    }

    // MARK: - Foreground gate

    @Test("A nudge with no transition since the last one is nothing")
    func noTransition() {
        var hub = makeHub()
        let transition = hub.takeForegroundTransition()
        #expect(transition == nil)
    }

    @Test("Each transition is reported once, whichever way it went")
    func transitionsAreReportedOnce() {
        let foreground = AppForegroundSignal()
        var hub = makeHub(foreground: foreground)

        foreground.set(false)
        let backgrounded = hub.takeForegroundTransition()
        let repeated = hub.takeForegroundTransition()
        #expect(backgrounded == .backgrounded)
        #expect(repeated == nil)

        foreground.set(true)
        let foregrounded = hub.takeForegroundTransition()
        #expect(foregrounded == .foregrounded)
    }

    @Test("A background → foreground flip seen only after the flag is back still counts as one return")
    func missedFlipStillCounts() {
        let foreground = AppForegroundSignal()
        var hub = makeHub(foreground: foreground)

        foreground.set(false)
        foreground.set(true)

        let first = hub.takeForegroundTransition()
        let second = hub.takeForegroundTransition()
        #expect(first == .foregrounded)
        #expect(second == nil)
    }

    @Test("A hub built while backgrounded starts from that transition")
    func builtInBackground() {
        let foreground = AppForegroundSignal(isInForeground: false)
        var hub = makeHub(foreground: foreground)
        #expect(!hub.canFetch)
        let none = hub.takeForegroundTransition()
        #expect(none == nil)

        foreground.set(true)
        let foregrounded = hub.takeForegroundTransition()
        #expect(foregrounded == .foregrounded)
        #expect(hub.canFetch)
    }

    // MARK: - Periodic check

    @Test("The periodic check is wanted only on the own channel, in the foreground, with something unfinished")
    func verificationIsWantedOnlyWhenItCanHelp() {
        let foreground = AppForegroundSignal()
        var hub = makeHub(foreground: foreground)
        // Quiet channel.
        #expect(!hub.wantsVerification)

        hub.apply(activePoll(), now: t0)
        #expect(hub.wantsVerification)

        foreground.set(false)
        #expect(!hub.wantsVerification)
        foreground.set(true)
        #expect(hub.wantsVerification)

        // The poll ends: nothing unfinished.
        hub.apply(endedPoll(), now: t0)
        #expect(!hub.wantsVerification)

        var other = makeHub(isOwnChannel: false)
        other.apply(activePoll(), now: t0)
        #expect(!other.wantsVerification)
    }

    @Test("Cancelling the periodic check cancels its task and forgets it")
    func cancelVerification() {
        var hub = makeHub()
        let task = parkedTask()
        hub.verificationStarted(task)
        #expect(hub.isVerifying)

        hub.cancelVerification()
        #expect(task.isCancelled)
        #expect(!hub.isVerifying)
    }

    // MARK: - Helix reconcile

    @Test("Nothing is fetched off the own channel or in the background")
    func reconcileRefused() {
        var other = makeHub(isOwnChannel: false)
        let offChannel = other.requestReconcile()
        #expect(offChannel == .refused)

        let foreground = AppForegroundSignal(isInForeground: false)
        var backgrounded = makeHub(foreground: foreground)
        let inBackground = backgrounded.requestReconcile()
        #expect(inBackground == .refused)
        #expect(!backgrounded.isReconcilePending)
    }

    @Test("The first request starts a pass; requests during it collapse into one follow-up")
    func requestsDuringAPassQueueOne() {
        var hub = makeHub()
        let first = hub.requestReconcile()
        #expect(first == .startPass)
        // Nothing is queued until a pass is actually running.
        #expect(!hub.isReconcilePending)

        let pass = parkedTask()
        hub.reconcilePassStarted(pass)
        let second = hub.requestReconcile()
        let third = hub.requestReconcile()
        #expect(second == .queued)
        #expect(third == .queued)
        #expect(hub.isReconcilePending)

        // The pass exits: one more starts, and the queue is empty again.
        let startAnother = hub.reconcilePassFinished()
        #expect(startAnother)
        #expect(hub.reconcileTask == nil)
        #expect(!hub.isReconcilePending)

        let followUp = parkedTask()
        hub.reconcilePassStarted(followUp)
        let done = hub.reconcilePassFinished()
        #expect(!done)

        pass.cancel()
        followUp.cancel()
    }

    @Test("A pass that exits with nothing queued starts nothing")
    func passWithNothingQueued() {
        var hub = makeHub()
        let pass = parkedTask()
        hub.reconcilePassStarted(pass)
        let startAnother = hub.reconcilePassFinished()
        #expect(!startAnother)
        #expect(hub.reconcileTask == nil)
        pass.cancel()
    }

    @Test("A queued reconcile is dropped, not run, if the app is in the background when the pass exits")
    func queuedRequestDroppedInBackground() {
        let foreground = AppForegroundSignal()
        var hub = makeHub(foreground: foreground)
        let pass = parkedTask()
        hub.reconcilePassStarted(pass)
        _ = hub.requestReconcile()
        #expect(hub.isReconcilePending)

        foreground.set(false)
        hub.cancelReconcilePass()
        #expect(pass.isCancelled)
        // Cancelling doesn't clear the handle: the pass does, when it exits.
        #expect(hub.reconcileTask != nil)

        let startAnother = hub.reconcilePassFinished()
        #expect(!startAnother)
        #expect(!hub.isReconcilePending)
        #expect(hub.reconcileTask == nil)
    }

    @Test("Backgrounded then foregrounded before the cancelled pass exits: the catch-up is queued behind it")
    func catchUpQueuedBehindCancelledPass() {
        let foreground = AppForegroundSignal()
        var hub = makeHub(foreground: foreground)
        let pass = parkedTask()
        hub.reconcilePassStarted(pass)

        foreground.set(false)
        _ = hub.takeForegroundTransition()
        hub.cancelReconcilePass()

        foreground.set(true)
        let transition = hub.takeForegroundTransition()
        #expect(transition == .foregrounded)
        let request = hub.requestReconcile()
        #expect(request == .queued)

        let startAnother = hub.reconcilePassFinished()
        #expect(startAnother)
    }

    // MARK: - Poll deadline

    @Test("A poll with no deadline is asked about once")
    func pollDeadlineRequestedOnce() {
        var hub = makeHub()
        let none = hub.takePollDeadlineRequest()
        #expect(none == nil)

        hub.apply(activePoll(), now: t0)
        let first = hub.takePollDeadlineRequest()
        let second = hub.takePollDeadlineRequest()
        #expect(first == "poll-1")
        #expect(second == nil)

        // A different poll is a new question.
        hub.apply(endedPoll(), now: t0)
        hub.apply(activePoll(id: "poll-2"), now: t0.addingTimeInterval(1))
        #expect(hub.state.poll?.id == "poll-2")
        let next = hub.takePollDeadlineRequest()
        #expect(next == "poll-2")
    }

    @Test("No deadline fetch for a poll that has its deadline, has ended, or while backgrounded")
    func pollDeadlineNotRequested() {
        var withDeadline = makeHub()
        withDeadline.apply(activePoll(endsAt: t0.addingTimeInterval(60)), now: t0)
        let hasDeadline = withDeadline.takePollDeadlineRequest()
        #expect(hasDeadline == nil)

        var ended = makeHub()
        ended.apply(activePoll(), now: t0)
        ended.apply(endedPoll(), now: t0)
        let concluded = ended.takePollDeadlineRequest()
        #expect(concluded == nil)

        let foreground = AppForegroundSignal(isInForeground: false)
        var backgrounded = makeHub(foreground: foreground)
        backgrounded.apply(activePoll(), now: t0)
        let inBackground = backgrounded.takePollDeadlineRequest()
        #expect(inBackground == nil)

        // Back in the foreground the question is still open.
        foreground.set(true)
        let afterReturn = backgrounded.takePollDeadlineRequest()
        #expect(afterReturn == "poll-1")
    }

    @Test("A deadline fetch that never went out can be asked for again")
    func skippedPollDeadlineFetchIsRetried() {
        var hub = makeHub()
        hub.apply(activePoll(), now: t0)
        _ = hub.takePollDeadlineRequest()

        // A skip for some other poll leaves the mark alone.
        hub.pollDeadlineFetchSkipped(pollId: "other")
        let stillMarked = hub.takePollDeadlineRequest()
        #expect(stillMarked == nil)

        hub.pollDeadlineFetchSkipped(pollId: "poll-1")
        let again = hub.takePollDeadlineRequest()
        #expect(again == "poll-1")
    }

    @Test("Once the deadline lands the poll isn't asked about again")
    func pollDeadlineFillsIn() {
        var hub = makeHub()
        hub.apply(activePoll(), now: t0)
        _ = hub.takePollDeadlineRequest()
        hub.pollDeadlineFetchSkipped(pollId: "poll-1")

        let changed = hub.apply(.pollDeadline(pollId: "poll-1", endsAt: t0.addingTimeInterval(60)), now: t0)
        #expect(changed)
        let request = hub.takePollDeadlineRequest()
        #expect(request == nil)
    }

    // MARK: - Startup

    @Test("Cancelling the startup cancels its task and forgets it")
    func cancelStartup() {
        var hub = makeHub()
        let task = parkedTask()
        hub.startupStarted(task)
        #expect(hub.startupTask != nil)

        hub.cancelStartup()
        #expect(task.isCancelled)
        #expect(hub.startupTask == nil)
        // A rebind cancels the startup without stopping anything else.
        #expect(!hub.isStopped)
        #expect(hub.canFetch)
    }
}
