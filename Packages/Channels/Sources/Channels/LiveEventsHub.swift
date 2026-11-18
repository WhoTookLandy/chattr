import Foundation

/// A channel's live events (polls, predictions, Hype Trains) and everything
/// that decides what happens to them next: the reduced state, the banner
/// consumers' latest-value mailboxes, the foreground gate, and the
/// bookkeeping of the Helix reconcile (one pass at a time, one queued behind
/// it), the periodic check and the poll-deadline fetch.
///
/// A value type owned by (and only ever mutated inside) `ChannelSession`,
/// as `ChannelUpdateHub` is for the ring: every method is one synchronous
/// step of the session's actor turn. Nothing here awaits or touches the
/// network. The session makes the requests and spawns the tasks — they need
/// its `client` and `topics`, which a rebind swaps under them — and stores
/// the task handles here, asking before and after each step what to do. See
/// `ChannelSession+LiveEvents.swift`.
struct LiveEventsHub {

    /// Current live events, reduced off-main from EventSub + Helix reconciles.
    private(set) var state = LiveEventsState()

    /// Latest-value mailboxes of the banner consumers.
    private(set) var subscribers: [UUID: LiveEventsSubscription] = [:]

    /// Whether this is the signed-in account's own channel: Twitch
    /// authorizes the live-event topics and reads for the broadcaster's
    /// token alone, so nothing is fetched anywhere else.
    let isOwnChannel: Bool

    /// The registry's shared foreground flag (`AppForegroundSignal`). While
    /// the app is in the background no live-event Helix request starts:
    /// EventSub updates still reduce (no network), and coming back
    /// reconciles once (`takeForegroundTransition()`).
    let appForeground: AppForegroundSignal

    /// The foreground transition (`AppForegroundSignal.State.generation`)
    /// last acted on. A repeated or out-of-order nudge is a no-op, but a
    /// transition not yet seen is never lost — even when both nudges of a
    /// background → foreground flip arrive after the flag is already back to
    /// the value last acted on.
    private(set) var lastSeenAppForegroundGeneration: UInt64

    /// Set by `stop()`, which the session calls in the same actor turn that
    /// sets its own flag.
    private(set) var isStopped = false

    /// The non-blocking live-topic subscribe + Helix seed the session kicks
    /// off on the account's own channel. Cancelled by `stop()` and by a
    /// client rebind.
    private(set) var startupTask: Task<Void, Never>?

    /// The periodic Helix check. At most one, and it exists ONLY while
    /// `wantsVerification`: a quiet channel, or a backgrounded app
    /// (background audio / PiP), has no task and makes no requests.
    private(set) var verifyTask: Task<Void, Never>?

    /// The one Helix reconcile pass in flight, if any (start, reconnect,
    /// foreground and the periodic check can overlap; they never stack).
    /// Only the pass clears it, when it exits (`reconcilePassFinished()`),
    /// so non-nil ⇔ a pass is running. Backgrounding and `stop()` cancel it.
    private(set) var reconcileTask: Task<Void, Never>?

    /// A reconcile was requested while a pass was in flight: when that pass
    /// exits (finished or cancelled), one more runs in a fresh task if the
    /// session can still reconcile. Coalesces any number of requests.
    private(set) var isReconcilePending = false

    /// The poll whose deadline was already asked of Helix (EventSub's poll
    /// payload in TwitchKit carries no `ends_at`). One fetch per poll.
    private(set) var pollDeadlineRequestedFor: String?

    init(isOwnChannel: Bool, appForeground: AppForegroundSignal) {
        self.isOwnChannel = isOwnChannel
        self.appForeground = appForeground
        self.lastSeenAppForegroundGeneration = appForeground.state.generation
    }

    var isAppInForeground: Bool { appForeground.isInForeground }

    // MARK: - Subscribers

    /// Registers a banner consumer, primed with the current state (already
    /// rung — the first wakeup delivers it). After `stop()` the subscription
    /// comes back already finished. `pruned`: priming dropped something that
    /// was due, so the caller re-checks the periodic check.
    mutating func subscribe(now: Date) -> (subscription: LiveEventsSubscription, pruned: Bool) {
        let pruned = state.prune(now: now)
        let subscription = LiveEventsSubscription(initial: state)
        if isStopped {
            subscription.finish()
        } else {
            subscribers[subscription.token] = subscription
        }
        return (subscription, pruned)
    }

    /// Removes and closes a banner consumer. Idempotent.
    mutating func unsubscribe(_ token: UUID) {
        subscribers.removeValue(forKey: token)?.finish()
    }

    private mutating func finishSubscribers() {
        for subscription in subscribers.values {
            subscription.finish()
        }
        subscribers.removeAll()
    }

    private func publish() {
        let state = self.state
        for subscription in subscribers.values {
            subscription.post(state)
        }
    }

    // MARK: - Reduce + publish

    /// Folds one EventSub update into `state` and posts the result to every
    /// consumer when it changed. Returns whether it changed. Never waits on
    /// a consumer.
    @discardableResult
    mutating func apply(_ update: LiveEventUpdate, now: Date) -> Bool {
        let pruned = state.prune(now: now)
        let applied = state.apply(update, at: now)
        guard pruned || applied else { return false }
        publish()
        return true
    }

    /// Folds in what Helix says is the channel's latest event of `kind` and
    /// posts the result when it changed. Ignored after `stop()`.
    @discardableResult
    mutating func reconcile(
        _ kind: LiveEventKind,
        snapshot: LiveEventUpdate?,
        fetchedAt: Date,
        now: Date
    ) -> Bool {
        guard !isStopped else { return false }
        // Reconcile FIRST. After a long background nothing has confirmed a
        // locked prediction for longer than `unconfirmedExpiry`; pruning
        // first would expire the very event Helix still reports as running.
        // Reconciling confirms (or restores) it, then the prune only drops
        // what is really due.
        let changed = state.reconcile(kind, snapshot: snapshot, fetchedAt: fetchedAt, now: now)
        let pruned = state.prune(now: now)
        guard pruned || changed else { return false }
        publish()
        return true
    }

    // MARK: - Foreground gate

    /// Which way the app moved since the transition last acted on.
    enum ForegroundTransition: Equatable {
        case foregrounded
        case backgrounded
    }

    /// Re-reads the shared flag and its transition generation. nil when
    /// nothing changed since the last call (a stale or repeated nudge);
    /// otherwise where the app is now — including when both nudges of a
    /// background → foreground flip arrive after the flag is already back
    /// to `true`, which still counts as one return to the foreground.
    mutating func takeForegroundTransition() -> ForegroundTransition? {
        let foreground = appForeground.state
        guard foreground.generation != lastSeenAppForegroundGeneration else { return nil }
        lastSeenAppForegroundGeneration = foreground.generation
        return foreground.isInForeground ? .foregrounded : .backgrounded
    }

    // MARK: - Periodic check

    /// Whether the periodic Helix check should be running: only on the own
    /// channel, before `stop()`, with the app in the foreground, and while
    /// some event is unfinished.
    var wantsVerification: Bool {
        isOwnChannel
            && !isStopped
            && isAppInForeground
            && state.hasUnconcludedEvent
    }

    /// Whether the periodic check is armed.
    var isVerifying: Bool { verifyTask != nil }

    mutating func verificationStarted(_ task: Task<Void, Never>) {
        verifyTask = task
    }

    mutating func cancelVerification() {
        verifyTask?.cancel()
        verifyTask = nil
    }

    // MARK: - Helix reconcile

    /// Own channel, not stopped, app in the foreground: the conditions for
    /// starting ANY live-event Helix request. Re-checked before every fetch,
    /// because each one suspends and any of them can change meanwhile.
    var canFetch: Bool {
        isOwnChannel && !isStopped && isAppInForeground
    }

    /// What a request to reconcile comes to.
    enum ReconcileRequest: Equatable {
        /// Can't fetch right now: nothing happens.
        case refused
        /// No pass is running: the caller starts one.
        case startPass
        /// A pass is in flight: one more is queued behind it.
        case queued
    }

    /// A reconcile was asked for. A request that arrives while a pass is in
    /// flight isn't dropped: it is queued, and the running pass, on exit,
    /// starts one more.
    mutating func requestReconcile() -> ReconcileRequest {
        guard canFetch else { return .refused }
        guard reconcileTask != nil else { return .startPass }
        isReconcilePending = true
        return .queued
    }

    /// The caller started a pass in a fresh task. The handle is stored
    /// before the task can run (it needs the session's actor).
    mutating func reconcilePassStarted(_ task: Task<Void, Never>) {
        isReconcilePending = false
        reconcileTask = task
    }

    /// The running pass exited (finished or cancelled) and clears its
    /// handle. Returns whether the caller starts one more now: a request was
    /// queued behind it and the session can still fetch.
    mutating func reconcilePassFinished() -> Bool {
        reconcileTask = nil
        let startAnother = isReconcilePending && canFetch
        isReconcilePending = false
        return startAnother
    }

    /// Cancels the pass in flight (backgrounded). The pass still clears its
    /// own handle when it exits.
    func cancelReconcilePass() {
        reconcileTask?.cancel()
    }

    // MARK: - Poll deadline

    /// TwitchKit's EventSub poll model has no `ends_at`, so a poll that
    /// began over EventSub has no countdown until Helix tells us its
    /// duration. Returns the id of the poll to fetch — once per poll — or
    /// nil when there is nothing to ask for.
    mutating func takePollDeadlineRequest() -> String? {
        guard let poll = state.poll,
              poll.status == .active,
              poll.endsAt == nil,
              pollDeadlineRequestedFor != poll.id,
              !isStopped,
              // No background network. The foreground reconcile brings the
              // deadline in its poll snapshot, and this runs again after it.
              isAppInForeground
        else { return nil }
        pollDeadlineRequestedFor = poll.id
        return poll.id
    }

    /// The fetch for `pollId` never went out (backgrounded or stopped by
    /// the time it ran): un-mark the poll so the next foreground pass can
    /// ask again.
    mutating func pollDeadlineFetchSkipped(pollId: String) {
        if pollDeadlineRequestedFor == pollId { pollDeadlineRequestedFor = nil }
    }

    // MARK: - Lifecycle

    mutating func startupStarted(_ task: Task<Void, Never>) {
        startupTask = task
    }

    /// Stops background work that would go on subscribing with a client
    /// being replaced (or a session being stopped).
    mutating func cancelStartup() {
        startupTask?.cancel()
        startupTask = nil
    }

    /// The session is stopping: cancels the startup, the pass in flight and
    /// the periodic check, and ends every consumer's stream. From here on
    /// nothing fetches and nothing new is subscribed.
    mutating func stop() {
        isStopped = true
        cancelStartup()
        reconcileTask?.cancel()   // the pass clears its own handle
        cancelVerification()
        finishSubscribers()
    }
}
