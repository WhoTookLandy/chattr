import Foundation
import TwitchKit
import Core
import os

private let logger = AppLogger.make("Channels.ChannelSession")

/// User-targeted moderation (ban / timeout / unban / warn) on behalf of the
/// signed-in account. Twitch checks server-side that the account moderates
/// the channel; the UI only offers these when `ChannelModerationState` says
/// so.
///
/// None of these touch the ring. A ban / timeout echoes back as
/// `channel.chat.clear_user_messages` (→ `.messagesClearedFromUser`), which
/// flips the target's rows through the same path as a web-UI timeout.
///
/// Failures Twitch explains are rethrown as `ModerationActionError` (scope
/// missing on an older sign-in → `.needsSignInAgain`; refusals → its
/// message); anything else (network, cancellation) propagates unchanged.
extension ChannelSession {

    /// Longest timeout Twitch accepts: two weeks.
    public static let maxTimeoutSeconds = 1_209_600

    /// Times `userId` out for `seconds` (clamped to Twitch's 1s…2w range).
    public func timeoutUser(userId: String, seconds: Int, reason: String? = nil) async throws {
        let clamped = min(max(seconds, 1), Self.maxTimeoutSeconds)
        do {
            try await chatActions.banUser(userId: userId, durationSeconds: clamped, reason: reason)
        } catch {
            throw Self.moderationError(from: error, label: "timeout")
        }
        logger.notice("Timed out \(userId, privacy: .public) for \(clamped)s in #\(self.channelLoginName, privacy: .public)")
    }

    /// Permanently bans `userId`.
    public func banUser(userId: String, reason: String? = nil) async throws {
        do {
            try await chatActions.banUser(userId: userId, durationSeconds: nil, reason: reason)
        } catch {
            throw Self.moderationError(from: error, label: "ban")
        }
        logger.notice("Banned \(userId, privacy: .public) in #\(self.channelLoginName, privacy: .public)")
    }

    /// Lifts a ban or an active timeout.
    public func unbanUser(userId: String) async throws {
        do {
            try await chatActions.unbanUser(userId: userId)
        } catch {
            throw Self.moderationError(from: error, label: "unban")
        }
        logger.notice("Unbanned \(userId, privacy: .public) in #\(self.channelLoginName, privacy: .public)")
    }

    /// Issues a warning. `reason` must be non-empty (Twitch requires one).
    public func warnUser(userId: String, reason: String) async throws {
        do {
            try await chatActions.warnUser(userId: userId, reason: reason)
        } catch {
            throw Self.moderationError(from: error, label: "warn")
        }
        logger.notice("Warned \(userId, privacy: .public) in #\(self.channelLoginName, privacy: .public)")
    }

    /// Whether `userId` is currently banned / timed out here; nil when
    /// unknown. Only the broadcaster's own token can ask Twitch (see
    /// `HelixChatActions.banState`): for a moderator this is always nil and
    /// makes no request.
    public func banState(of userId: String) async -> UserBanState? {
        await chatActions.banState(userId: userId)
    }

    // MARK: - Own restriction

    /// The signed-in user's own standing here, for a chat page to restore on
    /// attach (see `ownRestriction`).
    public func ownChatRestriction() -> OwnChatRestrictionLedger {
        ownRestriction
    }

    /// Records a signal only the chat page sees (a send rejection, our own
    /// echo, the user dismissing the banner). Self-clears arrive through
    /// `handle(event:)` instead and must not be forwarded here.
    public func recordOwnChatRestriction(_ event: OwnChatRestrictionLedger.Event) {
        ownRestriction.apply(event)
    }

    /// Translates a Twitch refusal into `ModerationActionError`; anything
    /// else (network, cancellation) passes through unchanged.
    private static func moderationError(from error: any Error, label: String) -> any Error {
        if let mapped = ModerationActionError.from(error) {
            logger.warning("\(label, privacy: .public) refused: \(error.localizedDescription, privacy: .public)")
            return mapped
        }
        logger.error("\(label, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        return error
    }
}
