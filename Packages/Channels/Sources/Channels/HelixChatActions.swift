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
    /// Transport for the one request that must NOT go through TwitchKit's
    /// `HelixClient` (the banned lookup — see `banState`). Tests pass the
    /// same recording client the `TwitchClient` uses.
    var http: any HTTPClient = URLSessionHTTPClient()

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
                try await requireGrantedScope(.moderatorManageBannedUsers)
                return try await client.api.banUser(
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
            try await requireGrantedScope(.moderatorManageBannedUsers)
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
                try await requireGrantedScope(.moderatorManageWarnings)
                return try await client.api.warnChatUser(
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
    /// is the broadcaster (Twitch requires `broadcaster_id` to match the
    /// token's user, so a moderator would always get 401) AND the stored
    /// token's granted scopes include one this endpoint accepts.
    ///
    /// Deliberately NOT sent through TwitchKit's `HelixClient`, and not
    /// through `authRetry` either: on a 401 `HelixClient` runs its own
    /// `/oauth2/token` refresh, which always fails in chattr (no client
    /// secret on device) and then `logout()`s — deleting the account's
    /// Keychain token. A best-effort lookup on every card open must never be
    /// able to do that. So this is a plain GET with the current access token
    /// read straight from the store (`TwitchTokenProvider.token()`, which
    /// never refreshes), and every non-200 — 401 / 403 included — is just
    /// "unknown"; the card then keeps Unban in its menu.
    func banState(
        userId: String,
        isolation: isolated (any Actor)? = #isolation
    ) async -> UserBanState? {
        guard channelId == accountUserId else { return nil }
        guard let token = try? await client.auth.tokenProvider.token(),
              Self.grants(token, anyOf: Self.bannedLookupScopes) else {
            logger.debug("Banned lookup skipped: no token, or it lacks a scope for GET /moderation/banned")
            return nil
        }
        var components = URLComponents(url: Endpoints.Helix.bannedUsers, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "broadcaster_id", value: channelId),
            URLQueryItem(name: "user_id", value: userId),
        ]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(client.clientId, forHTTPHeaderField: "Client-Id")
        do {
            let (data, response) = try await http.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200 else {
                logger.debug("Banned lookup answered \(status), state unknown")
                return nil
            }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let page = try decoder.decode(BannedLookupResponse.self, from: data)
            guard let entry = page.data.first(where: { $0.userId == userId }) else {
                return .notBanned
            }
            return UserBanState(expiresAt: entry.expiresAt)
        } catch {
            logger.debug("Banned lookup failed, state unknown: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Granted scopes

    /// Scopes Twitch accepts for GET /moderation/banned.
    static let bannedLookupScopes: [TwitchScope] = [.moderationRead, .moderatorManageBannedUsers]

    /// Whether the token's granted scopes include any of `scopes`. A token
    /// with no recorded scope list counts as NOT granting them.
    static func grants(_ token: OAuthToken, anyOf scopes: [TwitchScope]) -> Bool {
        guard let granted = token.scope else { return false }
        return scopes.contains { granted.contains($0.rawValue) }
    }

    /// Throws `.needsSignInAgain` before any request unless the stored
    /// token is CONFIRMED to carry `scope` (an account signed in before
    /// chattr asked for it doesn't). Runs inside each `authRetry` attempt,
    /// so a credential the bridge refresh swapped in — possibly an older,
    /// unscoped one — is checked again before the retry goes out.
    ///
    /// Why not let Twitch answer: a missing scope is a 401, and a 401
    /// through `HelixClient` triggers TwitchKit's own refresh, which fails in
    /// chattr and deletes the Keychain token (see `banState`); `authRetry`
    /// then refreshes via the bridge, retries, gets 401 again, and TwitchKit
    /// wipes the token a second time. Refreshing never adds a scope, so none
    /// of that can succeed — checking first keeps the credential intact and
    /// gives the card its "sign in again" message.
    ///
    /// Fails closed: a token that can't be read, or that carries no recorded
    /// scope list, can't prove the scope, so nothing is sent. Reads the
    /// token without refreshing.
    private func requireGrantedScope(_ scope: TwitchScope) async throws {
        // Propagate `HelixError.notAuthenticated` (e.g. TwitchKit's store was
        // temporarily emptied) so `HelixAuthRetry` can recover via the
        // refresh-token cache instead of forcing a spurious re-sign-in.
        let token: OAuthToken
        do {
            token = try await client.auth.tokenProvider.token()
        } catch HelixError.notAuthenticated {
            throw HelixError.notAuthenticated
        } catch {
            logger.notice("\(scope.rawValue, privacy: .public) token read failed; asking to sign in again")
            throw ModerationActionError.needsSignInAgain
        }
        guard Self.grants(token, anyOf: [scope]) else {
            logger.notice("\(scope.rawValue, privacy: .public) isn't confirmed for this sign-in; asking to sign in again")
            throw ModerationActionError.needsSignInAgain
        }
    }
}

/// The two fields of a GET /moderation/banned entry the lookup reads. Our
/// own type rather than TwitchKit's `BannedUser`, because the lookup
/// bypasses `HelixClient` and its decoder.
private struct BannedLookupResponse: Decodable {
    struct Entry: Decodable {
        let userId: String
        let expiresAt: String?
    }
    let data: [Entry]
}
