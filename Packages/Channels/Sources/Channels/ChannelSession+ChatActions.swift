import Foundation
import TwitchKit
import Core
import os

private let logger = AppLogger.make("Channels.ChannelSession")

extension ChannelSession {

    // MARK: - Chat restrictions

    /// Returns the current chat restrictions for this channel, fetching
    /// from Helix on first access and returning the cached value
    /// afterwards. The compose bar in `ChatScreen` reads from this via
    /// `ChatTranscriptModel` to render an inline strip showing what's enabled
    /// (slow mode, followers-only, subscribers-only, etc.).
    ///
    /// Returns nil if the fetch fails — restrictions are bonus polish,
    /// not safety-critical, so the failure case just falls back to "no
    /// restrictions" rather than blocking chat entirely. Twitch will
    /// still return a `dropReason` on `sendChatMessage` if a hidden
    /// restriction blocks the send.
    public func currentChatRestrictions() -> ChatRestrictions? {
        restrictionsCache.value
    }

    /// Refresh the restrictions snapshot from Helix and fan the result out.
    /// Kicked off as a background task by `start()` — deliberately NOT
    /// awaited there, so session exposure doesn't block on this Helix
    /// round-trip (the compose-bar strip is enrichment, not first-frame
    /// critical). The fetched snapshot reaches an already-attached tab
    /// reactively via `applyInitialRestrictions`'s `.restrictionsUpdated`
    /// fan-out — the same path a live `channel.chat_settings.update` takes.
    func refreshChatRestrictions() async {
        do {
            let settings = try await chatActions.fetchChatSettings()
            applyInitialRestrictions(ChatRestrictions(from: settings))
            logger.debug("Refreshed chat restrictions for #\(self.channelLoginName, privacy: .public)")
        } catch is CancellationError {
            // Session tear-down racing fetch — silent exit.
        } catch {
            // Non-fatal. Leave whatever was cached (or nil) in place;
            // the user can still chat and Twitch's dropReason will fill
            // in any restriction we miss.
            logger.warning("Failed to fetch chat restrictions: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Commit a start-time restrictions snapshot to the cache and fan it out
    /// to subscribers as `.restrictionsUpdated`, so a tab attached before the
    /// fetch resolved updates its compose-bar strip reactively. Goes through
    /// the same `emit` as `updateChatSettings` / `handle`, so a backgrounded
    /// initial fetch is indistinguishable downstream from a live EventSub update.
    ///
    /// No-ops when:
    ///   - `restrictions` is nil — the Helix fetch failed; leave the cache as is.
    ///   - the cache is already live — a live `chat_settings.update` already
    ///     landed while the fetch was in flight, so the Helix snapshot is older
    ///     than what we hold. Same race guard the awaited refresh used to apply
    ///     inline (CR MEDIUM 4), now that the fetch resolves after exposure.
    ///
    /// Internal (not private) so ChannelsTests can drive the fan-out + guard
    /// offline — same visibility relaxation as `applyBackfill`.
    func applyInitialRestrictions(_ restrictions: ChatRestrictions?) {
        guard let restrictions else { return }
        guard restrictionsCache.applyInitial(restrictions) else {
            logger.debug("Skipping Helix restrictions overwrite — EventSub update already populated cache")
            return
        }
        emit([.restrictionsUpdated(restrictions)])
    }

    /// The signed-in user's chat name color (GET /chat/color), e.g.
    /// "#FF69B4". Used to stamp optimistic send rows with the right
    /// color BEFORE the first echo of the session teaches us — without
    /// it, the user's first message flashes plain-white for the echo
    /// round-trip (~0.5s). nil on failure or when the user never picked
    /// a color (Twitch returns "" then) — callers fall back to the
    /// echo-taught value.
    public func fetchOwnChatColor() async -> String? {
        await chatActions.fetchOwnChatColor()
    }

    /// Update the broadcaster's chat-mode settings (PATCH /chat/settings)
    /// on behalf of the signed-in account, which must be the broadcaster
    /// or a moderator — Twitch enforces that server-side (the UI gates
    /// the controls behind `ChatTranscriptModel.currentUserCanModerate` too).
    /// Requires the `moderator:manage:chat_settings` scope on the token.
    ///
    /// nil parameters are omitted from the PATCH body and left unchanged
    /// on Twitch's side. To enable slow/followers mode with a duration,
    /// pass BOTH the flag and the duration (Twitch's API shape).
    ///
    /// On success the cached restrictions snapshot is replaced with the
    /// PATCH response (the authoritative new state) and a
    /// `.restrictionsUpdated` event fans out to subscribers, so the
    /// compose-bar strip and any open settings UI update instantly
    /// instead of waiting on the EventSub `chat_settings.update` echo.
    /// The echo still arrives and re-applies identical state — both
    /// paths are idempotent.
    @discardableResult
    public func updateChatSettings(
        emoteOnly: Bool? = nil,
        subscribersOnly: Bool? = nil,
        followersOnly: Bool? = nil,
        followersDurationMinutes: Int? = nil,
        slowMode: Bool? = nil,
        slowModeSeconds: Int? = nil
    ) async throws -> ChatRestrictions {
        let settings = try await chatActions.updateChatSettings(
            emoteOnly: emoteOnly,
            subscribersOnly: subscribersOnly,
            followersOnly: followersOnly,
            followersDurationMinutes: followersDurationMinutes,
            slowMode: slowMode,
            slowModeSeconds: slowModeSeconds
        )

        let restrictions = ChatRestrictions(from: settings)
        restrictionsCache.applyLive(restrictions)

        // Same `emit` as handle(event:), so a local settings change is
        // indistinguishable from an EventSub-delivered one downstream.
        emit([.restrictionsUpdated(restrictions)])
        return restrictions
    }

    // MARK: - Send

    /// Sends a chat message through this session's authenticated user. Wraps
    /// `client.api.sendChatMessage(...)` with a one-shot token-refresh-and-retry
    /// on any auth-refreshable error (`HelixAuthRetry`), matching
    /// `subscribeToChat()` — sends are short, so we don't go through
    /// `AccountStore.withTokenRefresh` (which is geared at the SwiftData-isolated Account model that doesn't
    /// belong inside this actor).
    ///
    /// Returns the Helix response so the caller can:
    ///   - Inspect `isSent` (a `true` response can still mean "dropped";
    ///     Twitch returns `isSent=false` + a `dropReason` for automod holds,
    ///     rate-limit hits, banned-word triggers, etc.).
    ///   - Read the canonical `messageId` for echo-dedup against the EventSub
    ///     `channel.chat.message` event that arrives ~100ms after a successful
    ///     send.
    ///
    /// Does NOT touch the ring buffer. The send's success is observable via
    /// the EventSub echo, which arrives through the same dispatcher that
    /// drives every other chat event. The send call is fire-then-let-EventSub-
    /// confirm — see `ChatTranscriptModel.send(...)` for the optimistic-insert /
    /// dedup orchestration on top of that.
    public func send(
        _ text: String,
        replyParentMessageId: String? = nil
    ) async throws -> SendChatMessageResponse {
        // Whitespace trim, empty-message guard and refresh-once/retry-once
        // live in `HelixChatActions.send`.
        //
        // Own restriction: the outcome is recorded HERE, against the ledger
        // sequence captured before the first suspension — not by the page,
        // whose copy may lag a self-clear or echo the session has already
        // seen. A rejection is dropped if a clear / echo landed meanwhile
        // (`OwnChatRestrictionLedger.finishSend`); the page then just syncs.
        let basis = ownRestriction.beginSend()
        let response: SendChatMessageResponse
        do {
            response = try await chatActions.send(text, replyParentMessageId: replyParentMessageId)
        } catch {
            // Twitch answers a banned sender with 403 rather than a drop.
            var rejection: OwnChatRestriction?
            if let helixError = error as? HelixError, case .forbidden(let apiError) = helixError {
                rejection = OwnChatRestriction(dropCode: nil, message: apiError.message)
            }
            ownRestriction.finishSend(basis: basis, rejection: rejection)
            throw error
        }
        let rejection = response.isSent
            ? nil
            : OwnChatRestriction(dropCode: response.dropReason?.code, message: response.dropReason?.message)
        ownRestriction.finishSend(basis: basis, rejection: rejection)
        return response
    }

    // MARK: - Moderation

    /// Deletes a single chat message in this channel. The signed-in
    /// account acts as the moderator — Twitch verifies that the account
    /// is actually a mod (or the broadcaster) of `channelId` before
    /// proceeding; non-mods get `HelixError.unauthorized`.
    ///
    /// Does NOT mutate local state directly. The deletion arrives
    /// through the existing `channel.chat.message_delete` EventSub
    /// subscription as a `.messageDeleted` update — `apply()` in
    /// `ChatTranscriptModel` already flips the corresponding row to
    /// `.deletedPlaceholder` when that arrives, so the visual update
    /// flows through the same path as a moderator's web-UI delete.
    ///
    /// Refresh-and-retry on auth failure (`HelixAuthRetry`) matches the other
    /// Helix calls (send, fetchChatSettings).
    public func deleteMessage(messageId: String) async throws {
        try await chatActions.deleteMessage(messageId: messageId)
    }

    /// Returns true if `accountUserId == channelId` — i.e., the
    /// signed-in user IS the broadcaster of this channel. This is an
    /// instant, no-network mod-check that's true for broadcasters
    /// before they've sent any message. For mods-who-aren't-the-
    /// broadcaster, we infer from echoed badges (see `ChatTranscriptModel`).
    public nonisolated var isAccountBroadcaster: Bool {
        accountUserId == channelId
    }
}
