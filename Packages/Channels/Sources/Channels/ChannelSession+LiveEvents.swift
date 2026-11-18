import Foundation
import TwitchKit
import Core
import os

private let logger = AppLogger.make("Channels.LiveEvents")

/// Polls, predictions and Hype Trains for the chat banner area.
///
/// ## Where the events come from (feasibility)
///
/// Twitch publishes these only as EventSub `channel.poll.*`,
/// `channel.prediction.*` and `channel.hype_train.*` (v2), and authorizes
/// every one of them with the BROADCASTER's own user token
/// (`channel:read:polls` / `channel:read:predictions` /
/// `channel:read:hype_train`) — there is no moderator or viewer condition.
/// The legacy public PubSub topics that third-party viewers used were shut
/// down with PubSub itself, and the web client's replacement (Hermes / GQL)
/// is undocumented. So chattr uses the official topics and nothing else:
/// banners work on the signed-in account's own channel and stay silently
/// absent everywhere else. Everything below the decode step
/// (`LiveEventsState`, the mailbox, the Features banners) is source-agnostic,
/// so another feed could be added later without touching the UI.
///
/// ## Flow
///
/// `start()` (own channel only) → `startLiveEvents()` subscribes the ten
/// topics concurrently and seeds an already-running poll / prediction /
/// train from Helix, off the critical path. Events arrive through the normal
/// router inbox; `handle(event:)` diverts them here before the chat
/// pipeline, so they never enter the ring and never wake a transcript. The
/// reduced state is posted to each banner's latest-value
/// `LiveEventsSubscription`.
///
/// EventSub alone can leave a banner stale (an end or resolve missed while
/// the socket was down), so `reconcileLiveEvents()` re-reads Helix after
/// every EventSub reconnect, on return to the foreground, and every
/// `liveEventsVerifyInterval` while an event is unfinished. The reducer's
/// tombstones and ordering rules keep a late or duplicated event from
/// undoing either.
///
/// ## Network budget
///
/// Own channel only, and never while the app is in the background (the
/// EventSub socket can stay up for background audio / PiP; its events still
/// reduce, but no Helix request starts). The periodic check is one task
/// that exists only while something is unfinished; see
/// `updateLiveEventsVerification()`.
///
/// ## Layout
///
/// The state, the consumers' mailboxes and every decision (may a request
/// start, is a reconcile queued, should the periodic check run) live in
/// `LiveEventsHub`, a value the session owns as `liveEvents`. What stays
/// here is what needs the actor: the tasks, the topic subscribes and the
/// Helix reads, which go through the session's `client` and `topics`.
extension ChannelSession {

    // MARK: - Subscriber API

    /// The banner consumers currently subscribed. Read by tests (here and in
    /// Features) to check that a consumer unsubscribed.
    var liveEventSubscribers: [UUID: LiveEventsSubscription] { liveEvents.subscribers }

    /// Registers a banner consumer, primed with the current state (already
    /// rung — the first wakeup delivers it). Drain `wakeups` /
    /// `takeLatest()`; pass `token` to `unsubscribeLiveEvents(_:)` when done.
    public func subscribeLiveEvents() -> LiveEventsSubscription {
        let (subscription, pruned) = liveEvents.subscribe(now: Date())
        if pruned {
            updateLiveEventsVerification()
        }
        return subscription
    }

    /// Removes and closes a banner consumer. Idempotent.
    public func unsubscribeLiveEvents(_ token: UUID) {
        liveEvents.unsubscribe(token)
    }

    // MARK: - Reduce + publish

    /// Folds one update into the live-event state and posts the result to
    /// every consumer when it changed. Synchronous — never waits on a
    /// consumer.
    func applyLiveEvent(_ update: LiveEventUpdate) {
        if liveEvents.apply(update, now: Date()) {
            updateLiveEventsVerification()
        }
        requestPollDeadlineIfNeeded()
    }

    // MARK: - Startup (own channel only)

    /// How often the session re-checks Helix while a poll, prediction or
    /// train is unfinished. EventSub sends nothing between a prediction's
    /// lock and its resolve, so this is what confirms a locked prediction is
    /// still locked (or catches a resolve EventSub dropped). One request per
    /// kind per interval, own channel only, and nothing at all while no
    /// event is running or the app is in the background.
    static let liveEventsVerifyInterval: Duration = .seconds(5 * 60)

    /// Subscribes the live-event topics and seeds from Helix. Never throws:
    /// a token that predates the scopes gets 403s on the subscribes and
    /// sends no Helix read at all (`requireLiveEventScope`), each logged at
    /// info, and the banners simply never appear. The seed arms the
    /// periodic check if it finds something unfinished.
    ///
    /// Runs in a task of its own, off the critical path (see
    /// `beginLiveEvents()`).
    func startLiveEvents() async {
        await withTaskGroup(of: Void.self) { group in
            for topic in EventSubTopics.liveEventSubscriptions(broadcasterID: channelId) {
                let subscription = topic.subscription
                let label = topic.label
                group.addTask { await self.subscribeToLiveEventTopic(subscription, label: label) }
            }
            // A poll / prediction / train already running when the session
            // started has no `begin` coming: the reconcile seeds it.
            group.addTask { await self.reconcileLiveEvents() }
        }
    }

    /// Kicks off `startLiveEvents()` without waiting for it. `stop()` and
    /// `rebind(to:)` cancel the task. Callers check that this is the
    /// account's own channel first.
    func beginLiveEvents() {
        let task: Task<Void, Never> = Task { [weak self] in
            await self?.startLiveEvents()
        }
        liveEvents.startupStarted(task)
    }

    /// The periodic check: reconciles with Helix only while something is
    /// unfinished, so a quiet channel costs no requests.
    func verifyLiveEvents() async {
        guard liveEvents.state.hasUnconcludedEvent else { return }
        await reconcileLiveEvents()
    }

    /// Starts or cancels the periodic Helix check to match the session: it
    /// runs only on the own channel, before `stop()`, with the app in the
    /// foreground, and while some event is unfinished. Idempotent and cheap
    /// (it allocates only when it starts the one task), so it is called
    /// after anything that can change one of those: a reduce that changed
    /// state, the end of a reconcile pass and a scene-phase change.
    /// (`stop()` cancels the check itself, in `LiveEventsHub.stop()`.)
    func updateLiveEventsVerification() {
        guard liveEvents.wantsVerification else {
            liveEvents.cancelVerification()
            return
        }
        guard !liveEvents.isVerifying else { return }
        // `self` is re-bound each round, so the sleeping loop never keeps
        // the session alive.
        let task: Task<Void, Never> = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: ChannelSession.liveEventsVerifyInterval)
                guard !Task.isCancelled, let self else { return }
                await self.verifyLiveEvents()
            }
        }
        liveEvents.verificationStarted(task)
    }

    /// Whether the periodic check is armed. Internal for tests.
    var isVerifyingLiveEvents: Bool { liveEvents.isVerifying }

    /// The app moved between foreground and background: the registry
    /// updated the shared `appForeground` flag and nudges every session.
    /// Re-reads the flag and its transition generation, so a stale or
    /// repeated nudge is a no-op while a transition this session missed —
    /// both nudges of a background → foreground flip arriving after the
    /// flag is already back to `true` — still counts.
    /// Backgrounded: the periodic check stops, an in-flight reconcile pass
    /// is cancelled, and no live-event Helix request starts. Foregrounded
    /// (including after a missed background stretch): one reconcile catches
    /// up on whatever changed meanwhile (and confirms a locked prediction
    /// that sat past `unconfirmedExpiry` unchecked), then the check re-arms
    /// if something is still unfinished. If the cancelled pass hasn't
    /// exited yet, the request is queued behind it rather than dropped
    /// (`LiveEventsHub.isReconcilePending`).
    public func appForegroundDidChange() async {
        guard let transition = liveEvents.takeForegroundTransition() else { return }
        updateLiveEventsVerification()
        switch transition {
        case .foregrounded:
            await reconcileLiveEvents()
        case .backgrounded:
            liveEvents.cancelReconcilePass()
        }
    }

    private func subscribeToLiveEventTopic(_ subscription: EventSubSubscription, label: String) async {
        guard !Task.isCancelled, !isStopped else { return }
        guard let id = await topics.subscribeToLiveEventTopic(subscription, label: label) else { return }
        // `stop()` ran while the POST was in flight and already deleted the
        // ids it knew about — delete this one ourselves rather than leak it
        // until the socket closes.
        if isStopped {
            await topics.unsubscribe([id])
        } else {
            activeSubscriptionIds.append(id)
        }
    }

    // MARK: - Helix reconcile

    /// Brings the live-event state in line with what Helix says is the
    /// channel's latest poll, prediction and Hype Train. Runs at start (the
    /// seed), after an EventSub reconnect (anything that began, ended or
    /// resolved while the socket was down) and periodically while an event
    /// is unfinished. Own channel only; a no-op elsewhere, after `stop()`
    /// and while the app is in the background (returning to the foreground
    /// reconciles).
    ///
    /// Exactly one pass runs at a time, in its own task
    /// (`LiveEventsHub.reconcileTask`), so backgrounding and `stop()` can
    /// cancel it whoever asked for it. A request that arrives while a pass
    /// is in flight isn't dropped: it is queued
    /// (`LiveEventsHub.isReconcilePending`) and the running pass, on exit,
    /// starts one more. Returns once no pass is in flight (so the request
    /// has been served).
    ///
    /// Each kind goes through `LiveEventsState.reconcile`, which can replace
    /// or clear a stored event but never undoes an EventSub update that
    /// landed while the request was in flight. A failed request leaves that
    /// kind alone: no answer is not the same as "nothing running".
    public func reconcileLiveEvents() async {
        switch liveEvents.requestReconcile() {
        case .refused:
            return
        case .startPass:
            startLiveEventsReconcilePass()
        case .queued:
            break
        }
        await waitForLiveEventsReconcile()
    }

    /// Waits until no reconcile pass is in flight, including a follow-up
    /// a finishing pass started. Internal for tests.
    func waitForLiveEventsReconcile() async {
        while let running = liveEvents.reconcileTask {
            await running.value
        }
    }

    /// Whether a reconcile is queued behind the running pass. Internal for
    /// tests.
    var isLiveEventsReconcilePending: Bool { liveEvents.isReconcilePending }

    /// Own channel, not stopped, app in the foreground: the conditions for
    /// starting ANY live-event Helix request. Re-checked before every fetch,
    /// because each one suspends and any of them can change meanwhile.
    var canFetchLiveEvents: Bool { liveEvents.canFetch }

    /// Starts a pass in a fresh, uncancelled task. The handle is set before
    /// the task can run (it needs this actor), and only the pass clears it.
    private func startLiveEventsReconcilePass() {
        let task: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            await self.runLiveEventsReconcilePass()
        }
        liveEvents.reconcilePassStarted(task)
    }

    private func runLiveEventsReconcilePass() async {
        do {
            try await reconcileLiveEventsOnce()
        } catch {
            // Only `CancellationError` reaches here: backgrounded or stopped
            // mid-pass. The kinds already reconciled stay applied.
            logger.debug("Live-event reconcile for #\(self.channelLoginName, privacy: .public) stopped early")
        }
        if liveEvents.reconcilePassFinished() {
            startLiveEventsReconcilePass()
        }
        // Arm or cancel the periodic check once the whole pass is in, never
        // per kind.
        updateLiveEventsVerification()
    }

    /// One pass over the three kinds. Throws `CancellationError` — and
    /// starts no further request — as soon as the task is cancelled or the
    /// session can no longer fetch.
    ///
    /// Each GET goes through `authRetry` (refresh via the bridge, retry
    /// once), so a token that went stale before the seed doesn't leave a
    /// running event hidden — and the periodic check un-armed — until some
    /// later trigger. Every attempt first re-checks that the session can
    /// still fetch (the bridge refresh suspends) and that the stored token
    /// carries the kind's scope (`requireLiveEventScope`).
    private func reconcileLiveEventsOnce() async throws {
        try checkCanFetchLiveEvents()
        let pollFetchedAt = Date()
        do {
            let page = try await authRetry.run("fetchPollsPage") {
                try checkCanFetchLiveEvents()
                try await requireLiveEventScope(.channelReadPolls)
                return try await client.api.fetchPollsPage(broadcasterID: channelId, first: 1)
            }
            reconcileLiveEvent(.poll, snapshot: page.data.first.map(LiveEventUpdate.init(helixPoll:)), fetchedAt: pollFetchedAt)
        } catch {
            try rethrowIfCancelled(error)
            logger.info("Poll fetch failed for #\(self.channelLoginName, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        try checkCanFetchLiveEvents()
        let predictionFetchedAt = Date()
        do {
            let page = try await authRetry.run("fetchPredictionsPage") {
                try checkCanFetchLiveEvents()
                try await requireLiveEventScope(.channelReadPredictions)
                return try await client.api.fetchPredictionsPage(broadcasterID: channelId, first: 1)
            }
            reconcileLiveEvent(.prediction, snapshot: page.data.first.flatMap(LiveEventUpdate.init(helixPrediction:)), fetchedAt: predictionFetchedAt)
        } catch {
            try rethrowIfCancelled(error)
            logger.info("Prediction fetch failed for #\(self.channelLoginName, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        try checkCanFetchLiveEvents()
        let trainFetchedAt = Date()
        do {
            let status = try await authRetry.run("fetchHypeTrainStatus") {
                try checkCanFetchLiveEvents()
                try await requireLiveEventScope(.channelReadHypeTrain)
                return try await client.api.fetchHypeTrainStatus(forBroadcasterID: channelId)
            }
            reconcileLiveEvent(.hypeTrain, snapshot: status?.current.map(LiveEventUpdate.init(helixHypeTrain:)), fetchedAt: trainFetchedAt)
        } catch {
            try rethrowIfCancelled(error)
            logger.info("Hype Train status fetch failed for #\(self.channelLoginName, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func checkCanFetchLiveEvents() throws {
        try Task.checkCancellation()
        guard canFetchLiveEvents else { throw CancellationError() }
    }

    /// Throws before any request unless the stored token is CONFIRMED to
    /// carry `scope` — the same fail-closed pre-check `HelixChatActions`
    /// runs for moderation actions, and for the same reason: a request
    /// Twitch answers 401 makes TwitchKit's `HelixClient` run its own
    /// `/oauth2/token` refresh, which always fails in chattr (the client
    /// secret lives on the bridge) and deletes the Keychain token. A sign-in
    /// that predates the live-event scopes would hit that on every reconcile.
    ///
    /// - No token stored: rethrows `HelixError.notAuthenticated`, which
    ///   `authRetry` answers with a bridge refresh and one more attempt —
    ///   no request has gone out, so nothing destructive ran.
    /// - Token without the scope, or with no recorded scope list:
    ///   `LiveEventScopeNotGranted`, which is not auth-refreshable
    ///   (refreshing never adds a scope), so the kind is skipped quietly.
    ///
    /// Runs inside each `authRetry` attempt, so the credential a bridge
    /// refresh swapped in is checked again before the retry goes out. Reads
    /// the token without refreshing.
    private func requireLiveEventScope(_ scope: TwitchScope) async throws {
        // Loading the token suspends: the app may have backgrounded, or the
        // session stopped, meanwhile. Re-check on both outcomes, so neither
        // the GET nor (on a token failure) `authRetry`'s bridge refresh
        // starts after that.
        let token: OAuthToken
        do {
            token = try await client.auth.tokenProvider.token()
        } catch {
            try checkCanFetchLiveEvents()
            throw error
        }
        try checkCanFetchLiveEvents()
        guard HelixChatActions.grants(token, anyOf: [scope]) else {
            throw LiveEventScopeNotGranted(scope: scope.rawValue)
        }
    }

    /// A cancelled fetch can surface as `CancellationError` or as a
    /// transport error thrown while the task was cancelled; both end the
    /// pass instead of being logged as a failed kind.
    private func rethrowIfCancelled(_ error: any Error) throws {
        if error is CancellationError || Task.isCancelled {
            throw CancellationError()
        }
    }

    private func reconcileLiveEvent(_ kind: LiveEventKind, snapshot: LiveEventUpdate?, fetchedAt: Date) {
        liveEvents.reconcile(kind, snapshot: snapshot, fetchedAt: fetchedAt, now: Date())
        requestPollDeadlineIfNeeded()
    }

    /// TwitchKit's EventSub poll model has no `ends_at`, so a poll that
    /// began over EventSub has no countdown until Helix tells us its
    /// duration. One fetch per poll, fire-and-forget; the result lands as a
    /// `.pollDeadline`, which only ever fills the deadline in.
    private func requestPollDeadlineIfNeeded() {
        guard let pollId = liveEvents.takePollDeadlineRequest() else { return }
        Task { [weak self] in
            await self?.fetchPollDeadline(pollId: pollId)
        }
    }

    /// Internal for tests.
    func fetchPollDeadline(pollId: String) async {
        // Queued while in the foreground, but it may run after the app was
        // backgrounded or the session stopped: re-check at execution time.
        // Un-mark the poll so the next foreground pass can ask again (its
        // poll snapshot usually brings the deadline anyway).
        guard canFetchLiveEvents, !Task.isCancelled else {
            liveEvents.pollDeadlineFetchSkipped(pollId: pollId)
            return
        }
        do {
            // Same scope pre-check and auth retry as the reconcile pass.
            let page = try await authRetry.run("fetchPollsPage(deadline)") {
                try checkCanFetchLiveEvents()
                try await requireLiveEventScope(.channelReadPolls)
                return try await client.api.fetchPollsPage(broadcasterID: channelId, ids: [pollId])
            }
            guard let poll = page.data.first, !isStopped else { return }
            applyLiveEvent(.pollDeadline(
                pollId: pollId,
                endsAt: poll.startedAt.addingTimeInterval(TimeInterval(poll.duration))
            ))
        } catch {
            logger.info("Poll deadline fetch failed for #\(self.channelLoginName, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// A live-event read skipped before any request: the stored token isn't
/// confirmed to carry the kind's scope (the account signed in before chattr
/// asked for it). Not auth-refreshable — refreshing never adds a scope — so
/// `HelixAuthRetry` passes it straight through. See
/// `ChannelSession.requireLiveEventScope(_:)`.
struct LiveEventScopeNotGranted: Error, LocalizedError, Equatable {
    let scope: String

    var errorDescription: String? {
        "\(scope) isn't confirmed for this sign-in; skipped"
    }
}
