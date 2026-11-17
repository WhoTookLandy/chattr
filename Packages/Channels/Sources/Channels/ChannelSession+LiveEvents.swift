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
extension ChannelSession {

    // MARK: - Subscriber API

    /// Registers a banner consumer, primed with the current state (already
    /// rung — the first wakeup delivers it). Drain `wakeups` /
    /// `takeLatest()`; pass `token` to `unsubscribeLiveEvents(_:)` when done.
    public func subscribeLiveEvents() -> LiveEventsSubscription {
        if liveEvents.prune(now: Date()) {
            updateLiveEventsVerification()
        }
        let subscription = LiveEventsSubscription(initial: liveEvents)
        if isStopped {
            subscription.finish()
        } else {
            liveEventSubscribers[subscription.token] = subscription
        }
        return subscription
    }

    /// Removes and closes a banner consumer. Idempotent.
    public func unsubscribeLiveEvents(_ token: UUID) {
        liveEventSubscribers.removeValue(forKey: token)?.finish()
    }

    func finishLiveEventSubscribers() {
        for subscription in liveEventSubscribers.values {
            subscription.finish()
        }
        liveEventSubscribers.removeAll()
    }

    // MARK: - Reduce + publish

    /// Folds one update into `liveEvents` and posts the result to every
    /// consumer when it changed. Synchronous — never waits on a consumer.
    func applyLiveEvent(_ update: LiveEventUpdate) {
        let now = Date()
        let pruned = liveEvents.prune(now: now)
        let applied = liveEvents.apply(update, at: now)
        if pruned || applied {
            publishLiveEvents()
            updateLiveEventsVerification()
        }
        requestPollDeadlineIfNeeded()
    }

    private func publishLiveEvents() {
        let state = liveEvents
        for subscription in liveEventSubscribers.values {
            subscription.post(state)
        }
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
    /// a token that predates the scopes gets 403s, logged at info, and the
    /// banners simply never appear. The seed arms the periodic check if it
    /// finds something unfinished.
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

    /// The periodic check: reconciles with Helix only while something is
    /// unfinished, so a quiet channel costs no requests.
    func verifyLiveEvents() async {
        guard liveEvents.hasUnconcludedEvent else { return }
        await reconcileLiveEvents()
    }

    /// Starts or cancels the periodic Helix check to match the session: it
    /// runs only on the own channel, before `stop()`, with the app in the
    /// foreground, and while some event is unfinished. Idempotent and cheap
    /// (it allocates only when it starts the one task), so it is called
    /// after anything that can change one of those: a reduce that changed
    /// state, the end of a reconcile pass, a scene-phase change and `stop()`.
    func updateLiveEventsVerification() {
        let wanted = channelId == accountUserId
            && !isStopped
            && isAppInForeground
            && liveEvents.hasUnconcludedEvent
        guard wanted else {
            liveEventsVerifyTask?.cancel()
            liveEventsVerifyTask = nil
            return
        }
        guard liveEventsVerifyTask == nil else { return }
        // `self` is re-bound each round, so the sleeping loop never keeps
        // the session alive.
        liveEventsVerifyTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: ChannelSession.liveEventsVerifyInterval)
                guard !Task.isCancelled, let self else { return }
                await self.verifyLiveEvents()
            }
        }
    }

    /// Whether the periodic check is armed. Internal for tests.
    var isVerifyingLiveEvents: Bool { liveEventsVerifyTask != nil }

    /// The app moved between foreground and background: the registry
    /// updated the shared `appForeground` flag and nudges every session.
    /// Re-reads the flag (so a stale or repeated nudge is a no-op).
    /// Backgrounded: the periodic check stops and no live-event Helix
    /// request starts. Foregrounded: one reconcile catches up on whatever
    /// changed meanwhile (and confirms a locked prediction that sat past
    /// `unconfirmedExpiry` unchecked), then the check re-arms if something
    /// is still unfinished.
    public func appForegroundDidChange() async {
        let inForeground = isAppInForeground
        guard inForeground != lastSeenAppForeground else { return }
        lastSeenAppForeground = inForeground
        updateLiveEventsVerification()
        if inForeground {
            await reconcileLiveEvents()
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

    /// Brings `liveEvents` in line with what Helix says is the channel's
    /// latest poll, prediction and Hype Train. Runs at start (the seed),
    /// after an EventSub reconnect (anything that began, ended or resolved
    /// while the socket was down) and periodically while an event is
    /// unfinished. Own channel only; a no-op elsewhere, after `stop()`,
    /// while the app is in the background (returning to the foreground
    /// reconciles), or while another reconcile is in flight.
    ///
    /// Each kind goes through `LiveEventsState.reconcile`, which can replace
    /// or clear a stored event but never undoes an EventSub update that
    /// landed while the request was in flight. A failed request leaves that
    /// kind alone: no answer is not the same as "nothing running".
    public func reconcileLiveEvents() async {
        guard channelId == accountUserId, !isStopped, isAppInForeground, !liveEventsReconcileInFlight else { return }
        liveEventsReconcileInFlight = true
        defer {
            liveEventsReconcileInFlight = false
            // Arm or cancel the periodic check once the whole pass is in,
            // never per kind: cancelling the check task mid-pass (it may be
            // the one running this) would cancel the remaining fetches.
            updateLiveEventsVerification()
        }

        let pollFetchedAt = Date()
        if let page = try? await client.api.fetchPollsPage(broadcasterID: channelId, first: 1) {
            reconcileLiveEvent(.poll, snapshot: page.data.first.map(LiveEventUpdate.init(helixPoll:)), fetchedAt: pollFetchedAt)
        }
        let predictionFetchedAt = Date()
        if let page = try? await client.api.fetchPredictionsPage(broadcasterID: channelId, first: 1) {
            reconcileLiveEvent(.prediction, snapshot: page.data.first.flatMap(LiveEventUpdate.init(helixPrediction:)), fetchedAt: predictionFetchedAt)
        }
        let trainFetchedAt = Date()
        do {
            let status = try await client.api.fetchHypeTrainStatus(forBroadcasterID: channelId)
            reconcileLiveEvent(.hypeTrain, snapshot: status?.current.map(LiveEventUpdate.init(helixHypeTrain:)), fetchedAt: trainFetchedAt)
        } catch {
            logger.info("Hype Train status fetch failed for #\(self.channelLoginName, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func reconcileLiveEvent(_ kind: LiveEventKind, snapshot: LiveEventUpdate?, fetchedAt: Date) {
        guard !isStopped else { return }
        let now = Date()
        // Reconcile FIRST. After a long background nothing has confirmed a
        // locked prediction for longer than `unconfirmedExpiry`; pruning
        // first would expire the very event Helix still reports as running.
        // Reconciling confirms (or restores) it, then the prune only drops
        // what is really due.
        let changed = liveEvents.reconcile(kind, snapshot: snapshot, fetchedAt: fetchedAt, now: now)
        let pruned = liveEvents.prune(now: now)
        if pruned || changed {
            publishLiveEvents()
        }
        requestPollDeadlineIfNeeded()
    }

    /// TwitchKit's EventSub poll model has no `ends_at`, so a poll that
    /// began over EventSub has no countdown until Helix tells us its
    /// duration. One fetch per poll, fire-and-forget; the result lands as a
    /// `.pollDeadline`, which only ever fills the deadline in.
    private func requestPollDeadlineIfNeeded() {
        guard let poll = liveEvents.poll,
              poll.status == .active,
              poll.endsAt == nil,
              pollDeadlineRequestedFor != poll.id,
              !isStopped,
              // No background network. The foreground reconcile brings the
              // deadline in its poll snapshot, and this runs again after it.
              isAppInForeground
        else { return }
        pollDeadlineRequestedFor = poll.id
        let pollId = poll.id
        Task { [weak self] in
            await self?.fetchPollDeadline(pollId: pollId)
        }
    }

    private func fetchPollDeadline(pollId: String) async {
        do {
            let page = try await client.api.fetchPollsPage(broadcasterID: channelId, ids: [pollId])
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
