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
/// A known timeout clears itself when it ends, so the banner disappears and
/// the compose bar re-enables without a send attempt.
@MainActor
@Observable
final class OwnChatRestrictionState {

    private(set) var current: OwnChatRestriction?

    /// Clears a timed restriction at its end. Replaced on every change.
    @ObservationIgnored private var expiryTask: Task<Void, Never>?

    /// A precise restriction learned from a send attempt.
    func apply(_ restriction: OwnChatRestriction) {
        // A vague "timed out" (no duration) must not erase a known end time
        // we already hold for the same timeout.
        if case .timedOut(.none) = restriction, case .timedOut(let until?)? = current, until > .now {
            return
        }
        set(restriction)
    }

    /// `channel.chat.clear_user_messages` targeted us. Keeps anything more
    /// precise we already know; otherwise "removed by a moderator".
    func noteOwnMessagesCleared() {
        guard current == nil else { return }
        set(.removedByModerator)
    }

    /// One of our messages was broadcast, so nothing is blocking us.
    func noteOwnMessageDelivered() {
        guard current != nil else { return }
        set(nil)
    }

    /// The user dismissed the banner (e.g. after acknowledging a warning on
    /// twitch.tv, or after being unbanned — events chattr can't see).
    func dismiss() {
        set(nil)
    }

    private func set(_ restriction: OwnChatRestriction?) {
        // Same value: keep the running expiry timer rather than dropping it.
        guard current != restriction else { return }
        expiryTask?.cancel()
        expiryTask = nil
        current = restriction
        logger.info("Own chat restriction → \(String(describing: restriction), privacy: .public)")

        guard case .timedOut(let until?)? = restriction else { return }
        let delay = until.timeIntervalSinceNow
        guard delay > 0 else {
            current = nil
            return
        }
        expiryTask = Task { [weak self] in
            // A beat of slack so the wake-up lands after `until`, not on it.
            try? await Task.sleep(for: .seconds(delay + 0.25))
            guard !Task.isCancelled, let self else { return }
            if case .timedOut(let end?)? = self.current, end <= .now {
                self.current = nil
            }
        }
    }
}
