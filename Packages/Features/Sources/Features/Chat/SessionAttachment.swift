import Foundation
import Observation
import Channels

/// A transcript's live link to its channel sessions: the subscriptions, the
/// tasks draining each subscription's mailbox, and the attach epoch that
/// keeps overlapping attaches and teardowns from stranding each other.
///
/// ## Epochs
///
/// SwiftUI's `.task` can fire overlapping attaches for one model (a paged
/// tab disappearing and reappearing, a session torn down and rebuilt) that
/// interleave at their suspensions. Each attach claims a fresh epoch
/// synchronously, before any await, and re-checks `isCurrent` after every
/// suspension: a superseded attach bails (undoing its partial subscription)
/// so the LAST attach wins. That replaced a "skip if already attaching"
/// guard, which left the *surviving* call un-attached when it raced an
/// in-flight one — primed lines but no live subscription, "Not connected to
/// chat". The epoch also guards teardown: the session-lifecycle `.task`
/// detaches only with the epoch its attach returned, so a dying screen
/// appearance can't detach a model a newer appearance just re-attached.
@MainActor
@Observable
final class SessionAttachment {

    /// Drives the empty state's "connecting" vs "quiet channel" copy.
    private(set) var state: ChatTranscriptModel.AttachState = .detached

    @ObservationIgnored private var epoch = 0

    /// Active subscription tokens with the sessions they belong to. Always
    /// operated on together, so a list rather than a map.
    @ObservationIgnored private var subscriptions: [(session: ChannelSession, token: UUID)] = []

    /// One drain task per subscription: wakes when its session posts, takes
    /// everything queued as one batch, applies it in one main-actor turn.
    @ObservationIgnored private var consumers: [Task<Void, Never>] = []

    /// True while draining is parked — the app is in the background, where
    /// the EventSub socket can stay up (background audio, Picture in
    /// Picture) and every batch would still cost a main-actor turn for a
    /// transcript nobody can see. Updates wait in the subscriptions'
    /// mailboxes, which are bounded: past the cap the session swaps the
    /// backlog for one `.reprime` snapshot, so however long the pause, the
    /// catch-up is at most a mailbox of updates or one ring replay.
    @ObservationIgnored private(set) var isDrainingPaused = false

    /// What `startDraining` was given, kept so a resume can drain every
    /// mailbox in its own turn instead of waiting for the tasks to be
    /// scheduled.
    @ObservationIgnored private var drainedSubscriptions: [ChannelSubscription] = []
    @ObservationIgnored private var applyBatch: (@MainActor @Sendable ([ChannelUpdate]) -> Bool)?

    /// Drain tasks that woke during a pause and are waiting it out.
    @ObservationIgnored private var parkedDrains: [CheckedContinuation<Void, Never>] = []

    isolated deinit {
        // Dropped mid-pause without a tear-down: let the parked tasks end
        // (their `apply` finds its owner gone).
        for parked in parkedDrains {
            parked.resume()
        }
    }

    /// The session sends, deletes and settings changes go to. Single-channel
    /// MVP: the first attached session.
    var primarySession: ChannelSession? { subscriptions.first?.session }

    // MARK: - Epochs

    /// Claims a fresh epoch. Call synchronously, before any await.
    func claimEpoch() -> Int {
        epoch &+= 1
        return epoch
    }

    /// False once a newer attach has claimed an epoch.
    func isCurrent(_ epoch: Int) -> Bool {
        epoch == self.epoch
    }

    // MARK: - Lifecycle

    /// Subscribes to each session — atomic prime + subscribe, see
    /// `ChannelSession.subscribe` — and returns the combined priming snapshot
    /// with the new subscriptions, not yet draining. Returns nil if a newer
    /// attach superseded `epoch` mid-way, after undoing the subscription it
    /// just made so the registry-owned session doesn't leak a subscriber.
    func subscribe(
        to sessions: [ChannelSession],
        epoch: Int
    ) async -> (snapshot: [ChannelUpdate], subscriptions: [ChannelSubscription])? {
        state = .attaching
        var snapshot: [ChannelUpdate] = []
        var newSubscriptions: [ChannelSubscription] = []
        for session in sessions {
            let (subscription, sessionSnapshot) = await session.subscribe()
            guard isCurrent(epoch) else {
                await session.unsubscribe(subscription.token)
                return nil
            }
            subscriptions.append((session, subscription.token))
            newSubscriptions.append(subscription)
            snapshot.append(contentsOf: sessionSnapshot)
        }
        return (snapshot: snapshot, subscriptions: newSubscriptions)
    }

    /// Starts draining `subscriptions` and marks the attachment live. Call
    /// only after priming from the snapshot: everything posted since
    /// `subscribe` waits in the mailbox, so nothing is lost — and nothing can
    /// land before the prime (whose reset would wipe it).
    ///
    /// `apply` returns false when its owner is gone, which ends the drain.
    ///
    /// Started during a pause (`setDrainingPaused`), the drains begin parked;
    /// the resume applies whatever queued meanwhile.
    func startDraining(
        _ subscriptions: [ChannelSubscription],
        apply: @escaping @MainActor @Sendable ([ChannelUpdate]) -> Bool
    ) {
        drainedSubscriptions.append(contentsOf: subscriptions)
        applyBatch = apply
        for subscription in subscriptions {
            consumers.append(Task { @MainActor [weak self] in
                for await _ in subscription.wakeups {
                    // A wakeup already in flight when `tearDown` cancelled us
                    // still resumes the loop once — don't apply it.
                    guard !Task.isCancelled else { return }
                    // Paused: wait it out HERE rather than loop on the
                    // doorbell, so nothing wakes the main actor per post.
                    // The mailbox keeps filling (bounded); the resume drains
                    // it. `self` is only borrowed inside the closure — a
                    // parked task doesn't keep the attachment alive.
                    if self?.isDrainingPaused == true {
                        await withCheckedContinuation { (parked: CheckedContinuation<Void, Never>) in
                            guard let self, self.isDrainingPaused else {
                                parked.resume()
                                return
                            }
                            self.parkedDrains.append(parked)
                        }
                        // `tearDown` cancels and then releases a parked drain.
                        guard !Task.isCancelled else { return }
                    }
                    guard apply(subscription.takePending()) else { return }
                }
            })
        }
        state = .attached
    }

    /// Parks (`true`) or resumes (`false`) draining — see `isDrainingPaused`.
    ///
    /// Resuming drains every mailbox right here, in the caller's turn, before
    /// releasing the parked tasks: the transcript is current by the time this
    /// returns, not whenever those tasks are next scheduled. Returns whether
    /// that catch-up applied anything.
    @discardableResult
    func setDrainingPaused(_ paused: Bool) -> Bool {
        guard paused != isDrainingPaused else { return false }
        isDrainingPaused = paused
        guard !paused else { return false }

        var caughtUp = false
        if let applyBatch {
            for subscription in drainedSubscriptions {
                let backlog = subscription.takePending()
                guard !backlog.isEmpty else { continue }
                caughtUp = true
                guard applyBatch(backlog) else { break }
            }
        }
        releaseParkedDrains()
        return caughtUp
    }

    /// Lets every parked drain task run on: back to its mailbox after a
    /// resume, or out of its loop after a tear-down cancelled it.
    private func releaseParkedDrains() {
        guard !parkedDrains.isEmpty else { return }
        let parked = parkedDrains
        parkedDrains = []
        for continuation in parked {
            continuation.resume()
        }
    }

    /// Stops draining, then unsubscribes from every session (sessions stay
    /// alive in the registry — other tabs may share them). Returns how many
    /// subscriptions it removed; 0 when already detached.
    ///
    /// Draining stops first: a batch must not land in a transcript that's no
    /// longer attached (it would resurface after the next prime, or in the
    /// wrong channel).
    func tearDown() async -> Int {
        for consumer in consumers {
            consumer.cancel()
        }
        consumers.removeAll()
        // After the cancels, so a released drain sees it was cancelled. The
        // pause itself outlives the attach: it follows the app, not a session.
        releaseParkedDrains()
        drainedSubscriptions = []
        applyBatch = nil

        guard !subscriptions.isEmpty else { return 0 }
        // Snapshot before mutating — the unsubscribes below are awaits.
        let removed = subscriptions
        subscriptions = []
        state = .detached
        for subscription in removed {
            await subscription.session.unsubscribe(subscription.token)
        }
        return removed.count
    }
}
