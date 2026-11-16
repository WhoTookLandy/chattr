import Foundation
import TwitchKit
import Core
import os

private let logger = AppLogger.make("Channels.ChannelSession")

/// The EventSub topics a channel session subscribes to, and how each one's
/// failure is handled: the core `channel.chat.message` subscription throws
/// (no chat = unusable session); the enrichment topics and `channel.moderate`
/// swallow errors.
///
/// Stateless — each subscribe returns the created subscription's id (nil on
/// a 409 "already subscribed", where Twitch keeps the existing subscription
/// alive on our WebSocket and returns no record) and `ChannelSession` keeps
/// the bookkeeping (`activeSubscriptionIds`, the moderation-enabled flag) on
/// the actor. Every method inherits the caller's isolation, so from the
/// session these run on the actor exactly as the inline calls did.
struct EventSubTopics: Sendable {
    let client: TwitchClient
    let channelId: String
    let accountUserId: String
    /// For log lines only.
    let channelLoginName: String
    /// Wraps the chat.message subscribe — the only topic that refreshes and
    /// retries on a stale token.
    let authRetry: HelixAuthRetry

    /// One of the chat-related notification topics (notification,
    /// message_delete, clear, clear_user_messages, settings_update). All use
    /// the same `(broadcasterID, userID)` shape. Failure swallowed — the
    /// session still works without these, just without bubble rendering.
    enum NotificationKind: Sendable {
        case notification, messageDelete, clear, clearUserMessages, settingsUpdate

        func subscription(broadcasterID: String, userID: String) -> EventSubSubscription {
            switch self {
            case .notification:       return .Chat.notification(broadcasterID: broadcasterID, userID: userID)
            case .messageDelete:      return .Chat.messageDelete(broadcasterID: broadcasterID, userID: userID)
            case .clear:              return .Chat.clear(broadcasterID: broadcasterID, userID: userID)
            case .clearUserMessages:  return .Chat.clearUserMessages(broadcasterID: broadcasterID, userID: userID)
            case .settingsUpdate:     return .Chat.settingsUpdate(broadcasterID: broadcasterID, userID: userID)
            }
        }
    }

    /// How a `channel.moderate` subscribe attempt ended.
    enum ModerationOutcome: Sendable {
        case subscribed(id: String)
        /// 409 — already live on this WebSocket from a prior session.
        case alreadySubscribed
        /// Any other failure (typically a 403); the caller rolls back.
        case failed
    }

    /// The core chat.message subscription — required for the session to be
    /// useful. Throws on failure so the registry doesn't keep a session that
    /// can't deliver chat. Returns nil on 409 "already subscribed".
    func subscribeToChat(
        isolation: isolated (any Actor)? = #isolation
    ) async throws -> String? {
        let subscription = EventSubSubscription.Chat.message(
            broadcasterID: channelId,
            userID: accountUserId
        )
        var id: String?
        do {
            // Auth-refreshable errors are handled inside `authRetry`
            // (refresh via the bridge, retry once); see its doc comment for
            // the three shapes a stale token takes.
            let record = try await authRetry.run("EventSub chat.message subscribe") {
                try await client.eventSub.subscribe(subscription)
            }
            id = record.id
        } catch HelixError.conflict {
            // 409 "already subscribed" — Twitch keeps the subscription alive
            // on this WebSocket from a prior session; events still flow.
            logger.info("EventSub already subscribed to channel.chat.message for #\(self.channelLoginName, privacy: .public) — reusing existing subscription (no id captured)")
        }
        logger.info("Subscribed to channel.chat.message for #\(self.channelLoginName, privacy: .public)")
        return id
    }

    /// Subscribes to one notification topic. Never throws; nil when no id
    /// was captured (409 or failure).
    func subscribeToNotificationTopic(
        _ kind: NotificationKind,
        label: String,
        isolation: isolated (any Actor)? = #isolation
    ) async -> String? {
        let subscription = kind.subscription(broadcasterID: channelId, userID: accountUserId)
        do {
            let record = try await client.eventSub.subscribe(subscription)
            logger.info("Subscribed to channel.chat.\(label, privacy: .public) for #\(self.channelLoginName, privacy: .public)")
            return record.id
        } catch HelixError.conflict {
            logger.info("Already subscribed to channel.chat.\(label, privacy: .public) for #\(self.channelLoginName, privacy: .public)")
        } catch {
            // Not fatal — chat still works. Log and move on.
            logger.warning("Failed to subscribe to channel.chat.\(label, privacy: .public) for #\(self.channelLoginName, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        return nil
    }

    /// Subscribes to `channel.raid` keyed by toBroadcasterID — "raids
    /// arriving at this channel." Failure swallowed for the same reason
    /// as the other notification topics.
    func subscribeToRaid(
        isolation: isolated (any Actor)? = #isolation
    ) async -> String? {
        let subscription = EventSubSubscription.Channel.raid(toBroadcasterID: channelId)
        do {
            let record = try await client.eventSub.subscribe(subscription)
            logger.info("Subscribed to channel.raid for #\(self.channelLoginName, privacy: .public)")
            return record.id
        } catch HelixError.conflict {
            logger.info("Already subscribed to channel.raid for #\(self.channelLoginName, privacy: .public)")
        } catch {
            logger.warning("Failed to subscribe to channel.raid for #\(self.channelLoginName, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        return nil
    }

    /// Subscribes to `channel.moderate` v2 with our account as the
    /// moderator. See `ChannelSession.enableModerationEvents()` for when and
    /// why.
    func subscribeToModeration(
        isolation: isolated (any Actor)? = #isolation
    ) async -> ModerationOutcome {
        let subscription = EventSubSubscription.Moderation.moderate(
            broadcasterID: channelId,
            moderatorID: accountUserId
        )
        do {
            let record = try await client.eventSub.subscribe(subscription)
            logger.info("Subscribed to channel.moderate for #\(self.channelLoginName, privacy: .public)")
            return .subscribed(id: record.id)
        } catch HelixError.conflict {
            // Already live on this WebSocket from a prior session — keep
            // the flag, events flow.
            logger.info("Already subscribed to channel.moderate for #\(self.channelLoginName, privacy: .public)")
            return .alreadySubscribed
        } catch {
            logger.info("Failed to subscribe to channel.moderate for #\(self.channelLoginName, privacy: .public): \(error.localizedDescription, privacy: .public) — mod status stays attach-time-static")
            return .failed
        }
    }

    /// Deletes each subscription on Twitch's side, best-effort: a failure
    /// (network blip, token expiry, server error) is logged and skipped —
    /// Twitch garbage-collects it when the WebSocket disconnects.
    func unsubscribe(
        _ ids: [String],
        isolation: isolated (any Actor)? = #isolation
    ) async {
        for id in ids {
            do {
                try await client.eventSub.unsubscribe(id: id)
                logger.info("Deleted EventSub subscription \(id, privacy: .public) for #\(self.channelLoginName, privacy: .public)")
            } catch {
                logger.warning("Failed to delete EventSub subscription \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
