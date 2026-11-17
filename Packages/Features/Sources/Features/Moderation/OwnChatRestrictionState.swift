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
/// The source of truth that outlives this page is the session's
/// `OwnChatRestrictionLedger` (the pager destroys pages two swipes away; the
/// session stays). On attach, `restore(from:)` adopts the session's copy;
/// while attached, the signals only this page sees are mirrored to the
/// session in order. Both run the same reducer, so they agree.
///
/// Expiry is deadline-based: a known timeout stores its end `Date`, and the
/// published `current` is recomputed from it. One timer per restriction
/// (not a tick) wakes at the deadline so the banner disappears and the
/// compose bar re-enables; it's tied to the ledger's generation, so an old
/// timeout's end can never lift a newer restriction.
@MainActor
@Observable
final class OwnChatRestrictionState {

    /// The restriction in force now. The only observed property.
    private(set) var current: OwnChatRestriction?

    @ObservationIgnored private var ledger = OwnChatRestrictionLedger()

    /// Wakes at a known timeout's end. Replaced on every change.
    @ObservationIgnored private var expiryTask: Task<Void, Never>?

    /// Mirrors page-only signals to the session. nil when detached (tests,
    /// previews): the state then works locally only.
    @ObservationIgnored private var session: ChannelSession?
    /// The previous mirror call, so the next one runs after it: the
    /// session's ledger sees events in the order this page applied them.
    @ObservationIgnored private var mirrorTail: Task<Void, Never>?

    /// The latest mirror call, for tests to await.
    var pendingMirror: Task<Void, Never>? { mirrorTail }

    // MARK: - Session

    /// Adopts the session's ledger (attach) and mirrors later page-only
    /// signals to it. A self-clear that landed while this page wasn't
    /// mounted is already in there.
    func restore(from session: ChannelSession, ledger: OwnChatRestrictionLedger) {
        self.session = session
        self.ledger = ledger
        publish()
    }

    /// Stops mirroring (detach). Keeps what's shown: the next attach
    /// restores from the session anyway.
    func detachSession() {
        session = nil
        mirrorTail = nil
    }

    // MARK: - Signals

    /// A precise restriction learned from a send attempt.
    func apply(_ restriction: OwnChatRestriction) {
        record(.rejected(restriction), mirror: true)
    }

    /// `channel.chat.clear_user_messages` targeted us. Always wins — even
    /// over a running known timeout, which may have been extended or turned
    /// into a ban — and becomes an unknown-length restriction until a send
    /// rejection refines it. Not mirrored: the session records the same
    /// event itself in `handle(event:)`.
    func noteOwnMessagesCleared() {
        record(.ownMessagesCleared, mirror: false)
    }

    /// One of our messages was broadcast, so nothing is blocking us. The
    /// per-message own-echo path: a nil check when unrestricted.
    func noteOwnMessageDelivered() {
        guard ledger.stored != nil else { return }
        record(.ownMessageDelivered, mirror: true)
    }

    /// The user dismissed the banner (e.g. after acknowledging a warning on
    /// twitch.tv, or after being unbanned — events chattr can't see).
    func dismiss() {
        record(.dismissed, mirror: true)
    }

    // MARK: - Private

    private func record(_ event: OwnChatRestrictionLedger.Event, mirror: Bool) {
        guard ledger.apply(event) else { return }
        let described = String(describing: ledger.stored)
        logger.info("Own chat restriction → \(described, privacy: .public)")
        publish()
        if mirror, let session {
            let previous = mirrorTail
            mirrorTail = Task {
                await previous?.value
                await session.recordOwnChatRestriction(event)
            }
        }
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
