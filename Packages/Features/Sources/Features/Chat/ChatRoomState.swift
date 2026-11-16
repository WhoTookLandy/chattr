import Observation
import Channels
import Core
import os

private let logger = AppLogger.make("Features.ChatRoomState")

/// The attached channel's chat restrictions (slow mode, followers-only,
/// subscribers-only, emote-only) — what the compose bar's inline strip and
/// the chat settings sheet render.
///
/// nil until the attach-time read of the session's cached settings lands,
/// typically within a few hundred ms of session start. Kept current by the
/// session's `.restrictionsUpdated` fan-out (`channel.chat_settings.update`)
/// and by the response to the viewer's own `updateSettings` PATCH.
@MainActor
@Observable
final class ChatRoomState {

    private(set) var restrictions: ChatRestrictions?

    /// Attach-time read of the session's cached settings. Not re-derived from
    /// a replayed ring — the cache is fresher than any replayed update.
    func prime(from session: ChannelSession) async {
        restrictions = await session.currentChatRestrictions()
    }

    /// A live `.restrictionsUpdated` arrived.
    func apply(_ restrictions: ChatRestrictions) {
        self.restrictions = restrictions
        logger.info("Chat restrictions updated mid-session: hasAny=\(restrictions.hasAny)")
    }

    /// Forwards a chat-mode change to `session` (see
    /// `ChannelSession.updateChatSettings` for parameter semantics). Throws
    /// when there's no session or Helix rejects the PATCH (not actually a
    /// mod, token missing `moderator:manage:chat_settings`, network) — the
    /// settings sheet surfaces the error and reverts its controls.
    ///
    /// Assigns the PATCH response in addition to the session's fan-out
    /// (which also lands, idempotently) so the caller observes the new state
    /// the moment this returns.
    func updateSettings(
        on session: ChannelSession?,
        emoteOnly: Bool?,
        subscribersOnly: Bool?,
        followersOnly: Bool?,
        followersDurationMinutes: Int?,
        slowMode: Bool?,
        slowModeSeconds: Int?
    ) async throws {
        guard let session else {
            throw AppError(message: "Not connected to chat.")
        }
        restrictions = try await session.updateChatSettings(
            emoteOnly: emoteOnly,
            subscribersOnly: subscribersOnly,
            followersOnly: followersOnly,
            followersDurationMinutes: followersDurationMinutes,
            slowMode: slowMode,
            slowModeSeconds: slowModeSeconds
        )
    }
}
