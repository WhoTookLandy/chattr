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
/// Stateless — each subscribe returns the created subscription's id, or how
/// the attempt ended (no id on a 409 "already subscribed", where Twitch keeps
/// the existing subscription alive on our WebSocket and returns no record),
/// and `ChannelSession` keeps the bookkeeping (`activeSubscriptionIds`, the
/// moderation-enabled flag, which topics to retry) on the actor. Every method inherits
/// the caller's isolation, so no Sendable hop is needed to call it.
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

    /// A topic the session subscribes in `start()` (and again after its
    /// client is replaced). `chat` is the required one; the rest are
    /// enrichment.
    enum SessionTopic: Sendable, Hashable {
        case chat, notification, messageDelete, clear, clearUserMessages, settingsUpdate, raid

        static let enrichment: [SessionTopic] = [
            .notification, .messageDelete, .clear, .clearUserMessages, .settingsUpdate, .raid,
        ]
    }

    /// How a `SessionTopic` subscribe attempt ended.
    enum SubscribeOutcome: Sendable {
        case subscribed(id: String)
        /// 409 — already live on this WebSocket; there is no id to track.
        case alreadySubscribed
        /// `retryable` is false for a 403: the token isn't authorized for
        /// the topic, and asking again can't change that.
        case failed(retryable: Bool)
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

    /// Subscribes one start-time topic without throwing, so the caller can
    /// decide per topic whether to retry. (`start()` itself still uses the
    /// throwing `subscribeToChat()`: a session with no chat must not open.)
    func subscribe(
        _ topic: SessionTopic,
        isolation: isolated (any Actor)? = #isolation
    ) async -> SubscribeOutcome {
        switch topic {
        case .chat:
            do {
                if let id = try await subscribeToChat() {
                    return .subscribed(id: id)
                }
                return .alreadySubscribed
            } catch HelixError.forbidden {
                logger.warning("Not authorized to subscribe to channel.chat.message for #\(self.channelLoginName, privacy: .public)")
                return .failed(retryable: false)
            } catch {
                logger.warning("Failed to subscribe to channel.chat.message for #\(self.channelLoginName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return .failed(retryable: true)
            }
        case .notification:
            return await subscribeToNotificationTopic(.notification, label: "notification")
        case .messageDelete:
            return await subscribeToNotificationTopic(.messageDelete, label: "message_delete")
        case .clear:
            return await subscribeToNotificationTopic(.clear, label: "chat_clear")
        case .clearUserMessages:
            return await subscribeToNotificationTopic(.clearUserMessages, label: "clear_user_messages")
        case .settingsUpdate:
            return await subscribeToNotificationTopic(.settingsUpdate, label: "settings_update")
        case .raid:
            return await subscribeToRaid()
        }
    }

    /// Subscribes to one notification topic. Never throws.
    func subscribeToNotificationTopic(
        _ kind: NotificationKind,
        label: String,
        isolation: isolated (any Actor)? = #isolation
    ) async -> SubscribeOutcome {
        let subscription = kind.subscription(broadcasterID: channelId, userID: accountUserId)
        do {
            let record = try await client.eventSub.subscribe(subscription)
            logger.info("Subscribed to channel.chat.\(label, privacy: .public) for #\(self.channelLoginName, privacy: .public)")
            return .subscribed(id: record.id)
        } catch HelixError.conflict {
            logger.info("Already subscribed to channel.chat.\(label, privacy: .public) for #\(self.channelLoginName, privacy: .public)")
            return .alreadySubscribed
        } catch HelixError.forbidden {
            logger.warning("Not authorized to subscribe to channel.chat.\(label, privacy: .public) for #\(self.channelLoginName, privacy: .public)")
            return .failed(retryable: false)
        } catch {
            // Not fatal — chat still works. The session retries it.
            logger.warning("Failed to subscribe to channel.chat.\(label, privacy: .public) for #\(self.channelLoginName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return .failed(retryable: true)
        }
    }

    /// Subscribes to `channel.raid` keyed by toBroadcasterID — "raids
    /// arriving at this channel." Failure swallowed for the same reason
    /// as the other notification topics.
    func subscribeToRaid(
        isolation: isolated (any Actor)? = #isolation
    ) async -> SubscribeOutcome {
        let subscription = EventSubSubscription.Channel.raid(toBroadcasterID: channelId)
        do {
            let record = try await client.eventSub.subscribe(subscription)
            logger.info("Subscribed to channel.raid for #\(self.channelLoginName, privacy: .public)")
            return .subscribed(id: record.id)
        } catch HelixError.conflict {
            logger.info("Already subscribed to channel.raid for #\(self.channelLoginName, privacy: .public)")
            return .alreadySubscribed
        } catch HelixError.forbidden {
            logger.warning("Not authorized to subscribe to channel.raid for #\(self.channelLoginName, privacy: .public)")
            return .failed(retryable: false)
        } catch {
            logger.warning("Failed to subscribe to channel.raid for #\(self.channelLoginName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return .failed(retryable: true)
        }
    }

    /// The live-event banner topics (polls, predictions, Hype Train). Twitch
    /// authorizes all of them only with the BROADCASTER's own token
    /// (`channel:read:polls` / `:predictions` / `:hype_train`), so the
    /// session only asks for them on the signed-in account's own channel —
    /// see `ChannelSession.startLiveEvents()`.
    static func liveEventSubscriptions(broadcasterID: String) -> [(label: String, subscription: EventSubSubscription)] {
        [
            ("channel.poll.begin", EventSubSubscription.Channel.pollBegin(broadcasterID: broadcasterID)),
            ("channel.poll.progress", EventSubSubscription.Channel.pollProgress(broadcasterID: broadcasterID)),
            ("channel.poll.end", EventSubSubscription.Channel.pollEnd(broadcasterID: broadcasterID)),
            ("channel.prediction.begin", EventSubSubscription.Channel.predictionBegin(broadcasterID: broadcasterID)),
            ("channel.prediction.progress", EventSubSubscription.Channel.predictionProgress(broadcasterID: broadcasterID)),
            ("channel.prediction.lock", EventSubSubscription.Channel.predictionLock(broadcasterID: broadcasterID)),
            ("channel.prediction.end", EventSubSubscription.Channel.predictionEnd(broadcasterID: broadcasterID)),
            ("channel.hype_train.begin", EventSubSubscription.Channel.hypeTrainBegin(broadcasterID: broadcasterID)),
            ("channel.hype_train.progress", EventSubSubscription.Channel.hypeTrainProgress(broadcasterID: broadcasterID)),
            ("channel.hype_train.end", EventSubSubscription.Channel.hypeTrainEnd(broadcasterID: broadcasterID)),
        ]
    }

    /// Subscribes to one live-event topic. Never throws; nil when no id was
    /// captured (409 or failure). A 403 (token predates the scopes) is the
    /// expected degrade path and logs at info, not warning.
    func subscribeToLiveEventTopic(
        _ subscription: EventSubSubscription,
        label: String,
        isolation: isolated (any Actor)? = #isolation
    ) async -> String? {
        do {
            let record = try await client.eventSub.subscribe(subscription)
            logger.info("Subscribed to \(label, privacy: .public) for #\(self.channelLoginName, privacy: .public)")
            return record.id
        } catch HelixError.conflict {
            logger.info("Already subscribed to \(label, privacy: .public) for #\(self.channelLoginName, privacy: .public)")
        } catch {
            logger.info("Couldn't subscribe to \(label, privacy: .public) for #\(self.channelLoginName, privacy: .public): \(error.localizedDescription, privacy: .public) — live banner stays off")
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
    ///
    /// The deletes run concurrently: they are independent Helix requests,
    /// and a re-acquire of the same channel waits for all of them.
    func unsubscribe(
        _ ids: [String],
        isolation: isolated (any Actor)? = #isolation
    ) async {
        guard !ids.isEmpty else { return }
        let eventSub = client.eventSub
        let channelLoginName = self.channelLoginName
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask {
                    do {
                        try await eventSub.unsubscribe(id: id)
                        logger.info("Deleted EventSub subscription \(id, privacy: .public) for #\(channelLoginName, privacy: .public)")
                    } catch {
                        logger.warning("Failed to delete EventSub subscription \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        }
    }
}
