import Foundation
import Observation
import Channels
import Core
import os

private let logger = AppLogger.make("Features.OwnChatRestrictionState")

/// The signed-in user's own standing in the attached channel — timed out,
/// banned, warned — for `OwnChatRestrictionBanner` and the compose bar.
///
/// Deliberately its own tiny `@Observable` (owned by `ChatTranscriptModel`
/// as a `let`): the only observers are the banner and the compose bar, so a
/// change here never re-renders the transcript, and the per-message path
/// never touches it except the own-echo branch (`noteOwnMessageDelivered`),
/// which is a nil check.
///
/// ## One authority
///
/// The session's `OwnChatRestrictionLedger` is the single source of truth
/// (it outlives this page — the pager destroys pages two swipes away — and
/// it sees self-clears and own echoes in arrival order). While attached,
/// this page never runs the reducer itself: it REPORTS what only it sees
/// (dismiss) to the session, and SYNCS from it when the session's copy
/// moved (our own clear or echo, a refused send, a reprime). Every report
/// and sync returns the session's ledger, adopted only if its `generation`
/// is newer than the copy held — so out-of-order completions can never put
/// an older state back. Send outcomes are recorded by `ChannelSession.send`
/// itself, ordered against clears and echoes by the ledger's `sequence`;
/// the page holds no basis of its own that could lag.
///
/// Detached (tests, previews), the same reducer runs locally instead.
///
/// Expiry is deadline-based: a known timeout stores its end `Date`, and the
/// published `current` is recomputed from it. One timer per restriction
/// (not a tick) wakes at the deadline so the banner disappears and the
/// compose bar re-enables; it's tied to the ledger's generation, so an old
/// timeout's end can never lift a newer restriction. Cancelled on detach
/// and deinit, rescheduled on restore.
@MainActor
@Observable
final class OwnChatRestrictionState {

    /// The restriction in force now. The only observed property.
    private(set) var current: OwnChatRestriction?

    /// The copy shown: the session's ledger as of the last adopt (or the
    /// local one when detached).
    @ObservationIgnored private var ledger = OwnChatRestrictionLedger()

    /// Wakes at a known timeout's end. Replaced on every change.
    @ObservationIgnored private var expiryTask: Task<Void, Never>?

    /// The attached session. nil when detached: the state then works
    /// locally only.
    @ObservationIgnored private var session: ChannelSession?
    /// The session `ledger` was copied from. Survives detach, so a re-attach
    /// to the same session keeps a newer copy than its snapshot.
    @ObservationIgnored private var source: ChannelSession?

    /// The previous report / sync, so the next runs after it: the session
    /// receives this page's reports in the order they were made.
    @ObservationIgnored private var tail: Task<Void, Never>?

    /// The latest report / sync, for tests to await.
    var pendingSync: Task<Void, Never>? { tail }

    isolated deinit {
        expiryTask?.cancel()
    }

    // MARK: - Session

    /// Adopts the session's ledger (attach). A self-clear that landed while
    /// this page wasn't mounted is already in there.
    func restore(from session: ChannelSession, ledger snapshot: OwnChatRestrictionLedger) {
        // Re-attaching to the same session: a report or sync that finished
        // after the snapshot was taken may already hold a newer copy.
        let keepsNewer = source === session && ledger.generation > snapshot.generation
        self.session = session
        source = session
        if !keepsNewer {
            ledger = snapshot
        }
        publish()
    }

    /// Stops adopting the session's state (detach). Keeps what's shown — the
    /// next attach restores from the session anyway — but cancels the
    /// expiry wake-up, which `restore` reschedules.
    func detachSession() {
        session = nil
        expiryTask?.cancel()
        expiryTask = nil
    }

    // MARK: - Signals

    /// A send through `session` came back refused for our standing. The
    /// session already recorded the outcome in `ChannelSession.send` (or
    /// dropped it as stale — the session alone knows its own order), so
    /// this only syncs. A no-op if the page detached meanwhile: the next
    /// attach restores from the session anyway.
    func syncAfterRejectedSend(on session: ChannelSession) {
        guard self.session === session else { return }
        enqueue(.sync, on: session)
    }

    /// A precise restriction learned outside a session send — the detached
    /// / test form: records on the attached session, else applies locally.
    func apply(_ restriction: OwnChatRestriction) {
        if let session {
            enqueue(.record(.rejected(restriction)), on: session)
        } else {
            applyLocally(.rejected(restriction))
        }
    }

    /// `channel.chat.clear_user_messages` targeted us. The session already
    /// recorded it in `handle(event:)` before fanning the update out, so
    /// this only syncs. (Detached: applied locally — a fresh clear always
    /// wins, even over a known running timeout.)
    func noteOwnMessagesCleared() {
        if let session {
            enqueue(.sync, on: session)
        } else {
            applyLocally(.ownMessagesCleared)
        }
    }

    /// One of our messages was broadcast, so nothing is blocking us. The
    /// per-message own-echo path: a nil check when unrestricted. The session
    /// recorded it already; this syncs.
    func noteOwnMessageDelivered() {
        guard ledger.stored != nil else { return }
        if let session {
            enqueue(.sync, on: session)
        } else {
            applyLocally(.ownMessageDelivered)
        }
    }

    /// The transcript re-primed (late history, or a mailbox overflow that
    /// may have dropped our own clear / echo): resync from the session.
    func resync() {
        guard let session else { return }
        enqueue(.sync, on: session)
    }

    /// The user dismissed the banner (e.g. after acknowledging a warning on
    /// twitch.tv, or after being unbanned — events chattr can't see).
    /// Hidden at once; the session's copy follows.
    func dismiss() {
        if current != nil { current = nil }
        if let session {
            enqueue(.record(.dismissed), on: session)
        } else {
            applyLocally(.dismissed)
        }
    }

    // MARK: - Private

    private enum Operation: Sendable {
        case sync
        case record(OwnChatRestrictionLedger.Event)
    }

    private func enqueue(_ operation: Operation, on session: ChannelSession) {
        let previous = tail
        tail = Task { [weak self] in
            await previous?.value
            let result: OwnChatRestrictionLedger
            switch operation {
            case .sync:
                result = await session.ownChatRestriction()
            case .record(let event):
                result = await session.recordOwnChatRestriction(event)
            }
            self?.adopt(result, from: session)
        }
    }

    /// Takes the session's copy if it's newer than the one held — and only
    /// while still attached to that session.
    private func adopt(_ incoming: OwnChatRestrictionLedger, from session: ChannelSession) {
        // Not newer: the copy held already reflects it. (A pending dismiss's
        // optimistic hide stays until its own result arrives — re-deriving
        // here from an older sync would flash the banner back.)
        guard self.session === session, source === session,
              incoming.generation > ledger.generation else { return }
        ledger = incoming
        let described = String(describing: ledger.stored)
        logger.info("Own chat restriction → \(described, privacy: .public)")
        publish()
    }

    private func applyLocally(_ event: OwnChatRestrictionLedger.Event) {
        guard ledger.apply(event) else { return }
        let described = String(describing: ledger.stored)
        logger.info("Own chat restriction (local) → \(described, privacy: .public)")
        publish()
    }

    /// Recomputes `current` from the ledger at the wall clock and schedules
    /// the one wake-up a running timeout needs.
    private func publish() {
        expiryTask?.cancel()
        expiryTask = nil
        let now = Date.now
        let next = ledger.current(at: now)
        if current != next { current = next }

        guard case .timedOut(let until?)? = next else { return }
        let generation = ledger.generation
        let delay = until.timeIntervalSince(now)
        expiryTask = Task { [weak self] in
            // A beat of slack so the wake-up lands after `until`, not on it.
            try? await Task.sleep(for: .seconds(delay + 0.25))
            guard !Task.isCancelled, let self, self.ledger.generation == generation else { return }
            self.publish()
        }
    }
}
