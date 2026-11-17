import Foundation
import Channels
import Core

// User-targeted moderation for the user card (timeout / ban / unban / warn,
// plus "is this user banned right now"). Thin forwards to the attached
// session; the card's `UserModerationModel` owns the UI state around them.
// Twitch has the final say on every call — the card only offers them when
// `currentUserCanModerate`.

extension ChatTranscriptModel {

    func timeoutUser(userId: String, seconds: Int, reason: String? = nil) async throws {
        try await requireSession().timeoutUser(userId: userId, seconds: seconds, reason: reason)
    }

    func banUser(userId: String, reason: String?) async throws {
        try await requireSession().banUser(userId: userId, reason: reason)
    }

    func unbanUser(userId: String) async throws {
        try await requireSession().unbanUser(userId: userId)
    }

    func warnUser(userId: String, reason: String) async throws {
        try await requireSession().warnUser(userId: userId, reason: reason)
    }

    /// nil when unknown (a moderator rather than the broadcaster, transient
    /// failure) — the card then keeps Unban in its menu rather than hiding it.
    func banState(of userId: String) async -> UserBanState? {
        guard let session = primarySession else { return nil }
        return await session.banState(of: userId)
    }

    private func requireSession() throws -> ChannelSession {
        guard let session = primarySession else {
            throw AppError(message: "Not connected to chat.")
        }
        return session
    }
}
