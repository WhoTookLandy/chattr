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
/// method inherits the caller's isolation, so from the session these run on
/// the session actor exactly as the inline calls did.
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
}
