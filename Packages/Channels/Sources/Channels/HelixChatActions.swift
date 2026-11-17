import Foundation
import TwitchKit
import Core
import os

private let logger = AppLogger.make("Channels.ChannelSession")

/// The Helix calls a channel session makes on behalf of its signed-in
/// account: send, delete, read/update chat settings, and the account's own
/// chat colour. Each auth-sensitive call goes through `HelixAuthRetry`
/// (refresh via the bridge, retry once).
///
/// Stateless — `ChannelSession` owns the cache / fan-out side effects. Every
/// method inherits the caller's isolation (so the session needs no Sendable
/// hop to call it); the closures handed to `authRetry` touch no session
/// state, only the Sendable client and ids.
struct HelixChatActions: Sendable {
    let client: TwitchClient
    let channelId: String
    let accountUserId: String
    let authRetry: HelixAuthRetry

    /// GET /chat/settings with the shared auth-refresh-and-retry, matching
    /// `send(...)` and the chat.message subscribe.
    func fetchChatSettings(
        isolation: isolated (any Actor)? = #isolation
    ) async throws -> ChatSettings {
        try await authRetry.run("fetchChatSettings") {
            try await client.api.fetchChatSettings(broadcasterID: channelId)
        }
    }

    /// The signed-in user's chat name color (GET /chat/color), e.g.
    /// "#FF69B4". nil on failure or when the user never picked a color
    /// (Twitch returns "" then). See `ChannelSession.fetchOwnChatColor()`.
    func fetchOwnChatColor(
        isolation: isolated (any Actor)? = #isolation
    ) async -> String? {
        do {
            let color = try await client.api.fetchUserChatColors(userIDs: [accountUserId]).first?.color
            return (color?.isEmpty == false) ? color : nil
        } catch {
            // Cosmetic-only data; the echo upgrade corrects the row anyway.
            logger.debug("Own-chat-color fetch failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// PATCH /chat/settings as the signed-in account (broadcaster or mod).
    /// nil parameters are omitted from the body and left unchanged on
    /// Twitch's side. Returns the authoritative new settings.
    func updateChatSettings(
        emoteOnly: Bool?,
        subscribersOnly: Bool?,
        followersOnly: Bool?,
        followersDurationMinutes: Int?,
        slowMode: Bool?,
        slowModeSeconds: Int?,
        isolation: isolated (any Actor)? = #isolation
    ) async throws -> ChatSettings {
        let update = ChatSettingsUpdate(
            emoteMode: emoteOnly,
            followerMode: followersOnly,
            followerModeDuration: followersDurationMinutes,
            slowMode: slowMode,
            slowModeWaitTime: slowModeSeconds,
            subscriberMode: subscribersOnly
        )
        return try await authRetry.run("updateChatSettings") {
            try await client.api.updateChatSettings(
                broadcasterID: channelId, moderatorID: accountUserId, with: update
            )
        }
    }

    /// Sends a chat message as the signed-in account. See
    /// `ChannelSession.send(_:replyParentMessageId:)`.
    func send(
        _ text: String,
        replyParentMessageId: String?,
        isolation: isolated (any Actor)? = #isolation
    ) async throws -> SendChatMessageResponse {
        // Trim leading/trailing whitespace only — preserve internal whitespace
        // so users can put their `:` between word and emote in
        // ":wave: hello :wave:" style messages. Twitch handles the rest.
        let payload = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else {
            throw AppError(message: "Can't send an empty message")
        }
        // Refresh once, retry once. A second auth failure propagates and lets
        // the caller (ChatTranscriptModel.send → ChatScreen) surface the
        // sign-in-expired UX.
        return try await authRetry.run("sendChatMessage") {
            try await client.api.sendChatMessage(
                broadcasterId: channelId,
                senderId: accountUserId,
                message: payload,
                replyParentMessageId: replyParentMessageId
            )
        }
    }

    /// Deletes one chat message with the signed-in account as moderator. See
    /// `ChannelSession.deleteMessage(messageId:)`.
    func deleteMessage(
        messageId: String,
        isolation: isolated (any Actor)? = #isolation
    ) async throws {
        try await authRetry.run("deleteChatMessages") {
            try await client.api.deleteChatMessages(
                broadcasterID: channelId,
                moderatorID: accountUserId,
                messageID: messageId
            )
        }
    }

    // MARK: - Bans, timeouts, warnings

    /// POST /moderation/bans as the signed-in account. `durationSeconds`
    /// nil = permanent ban; otherwise a timeout (Twitch accepts 1…1_209_600).
    ///
    /// The response body is deliberately ignored: Twitch answers with
    /// `{broadcaster_id, moderator_id, user_id, created_at, end_time}`, which
    /// TwitchKit 0.3.4's `BannedUser` (shaped for GET /moderation/banned,
    /// with logins and a reason) can't decode. `decodingFailed` is only
    /// thrown AFTER the 2xx status was validated, so it means the ban
    /// landed — treat it as success rather than reporting a failure for an
    /// action that happened.
    func banUser(
        userId: String,
        durationSeconds: Int?,
        reason: String?,
        isolation: isolated (any Actor)? = #isolation
    ) async throws {
        let trimmedReason = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try await authRetry.run(durationSeconds == nil ? "banUser" : "timeoutUser") {
                try await client.api.banUser(
                    broadcasterID: channelId,
                    moderatorID: accountUserId,
                    userID: userId,
                    duration: durationSeconds,
                    reason: (trimmedReason?.isEmpty == false) ? trimmedReason : nil
                )
            }
        } catch HelixError.decodingFailed {
            logger.debug("banUser: 2xx with an undecodable body — treating as success")
        }
    }

    /// DELETE /moderation/bans — lifts a ban or an active timeout.
    func unbanUser(
        userId: String,
        isolation: isolated (any Actor)? = #isolation
    ) async throws {
        try await authRetry.run("unbanUser") {
            try await client.api.unbanUser(
                broadcasterID: channelId,
                moderatorID: accountUserId,
                userID: userId
            )
        }
    }

    /// POST /moderation/warnings. Twitch requires a non-empty reason (the
    /// warned user sees it and must acknowledge it before chatting again).
    func warnUser(
        userId: String,
        reason: String,
        isolation: isolated (any Actor)? = #isolation
    ) async throws {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AppError(message: "A warning needs a reason.")
        }
        do {
            _ = try await authRetry.run("warnChatUser") {
                try await client.api.warnChatUser(
                    broadcasterID: channelId,
                    moderatorID: accountUserId,
                    userID: userId,
                    reason: trimmed
                )
            }
        } catch HelixError.decodingFailed {
            // Same rationale as banUser: past the 2xx check, so it landed.
            logger.debug("warnUser: 2xx with an undecodable body — treating as success")
        }
    }

    /// GET /moderation/banned for one user: whether they're currently banned
    /// or timed out here. nil expiry on a found entry = permanent ban.
    ///
    /// Returns nil ("unknown") WITHOUT a request unless the signed-in account
    /// is the broadcaster: Twitch requires `broadcaster_id` to match the
    /// token's user for this endpoint, so for an ordinary moderator it always
    /// answers 401. Deliberately not routed through `authRetry` either — a
    /// 401 here says nothing about the token's freshness, and treating it as
    /// one would run a bridge refresh + retry on every card open. Any failure
    /// is reported as unknown; the card then keeps Unban in its menu.
    func banState(
        userId: String,
        isolation: isolated (any Actor)? = #isolation
    ) async -> UserBanState? {
        guard channelId == accountUserId else { return nil }
        do {
            let page = try await client.api.fetchBannedUsersPage(broadcasterID: channelId, userIDs: [userId])
            guard let entry = page.data.first(where: { $0.userId == userId }) else {
                return .notBanned
            }
            return UserBanState(expiresAt: entry.expiresAt)
        } catch {
            logger.debug("Banned lookup failed, state unknown: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
