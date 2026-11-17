import Foundation
import TwitchKit

extension ChannelSession {

    /// One EventSub event, translated and filtered to this channel — the
    /// raw input to normalization (see `ChannelUpdateNormalizer.makeUpdate`).
    /// Internal: subscribers receive `ChannelUpdate`s, never these.
    enum ChannelEvent: Sendable {
        /// A regular chat message, live over EventSub.
        case message(ChatMessage)

        /// A `channel.chat.notification` event — subs, resubs, gift subs,
        /// raids (notification variant), announcements, etc. The Normalizer
        /// (in ChatModel) decodes this into one of `ChatLine.Kind`'s bubble
        /// cases based on `noticeType`.
        case notification(EventSubChatNotification)

        /// A `channel.raid` event — someone raided INTO this channel.
        /// Distinct from `.notification(raid)` which is the older
        /// notification-topic variant; both render as raid bubbles.
        case raid(EventSubRaid)

        /// A `channel.chat.message_delete` event — a moderator deleted one
        /// specific message. Consumers find the matching `ChatLine` by
        /// `targetMessageId` and flip its kind to `.deletedPlaceholder`.
        /// (The actor stores this in the ring so late subscribers see
        /// pre-deleted state too.)
        case messageDeleted(targetMessageId: String)

        /// A `channel.chat.clear` event — the entire chat was cleared
        /// (typically by a mod or chat-clear button). Consumers flip
        /// every existing message to `.deletedPlaceholder`.
        case chatCleared

        /// A `channel.chat.clear_user_messages` event — a moderator
        /// timed out / banned a user, hiding all their prior messages.
        /// Consumers flip every message from `targetUserId` to deleted.
        case messagesClearedFromUser(targetUserId: String)

        /// A `channel.chat_settings.update` event — the broadcaster (or
        /// a mod) changed chat settings mid-stream (toggled slow mode,
        /// enabled followers-only, etc). Consumers update their cached
        /// restrictions snapshot so the compose bar's inline strip
        /// stays accurate without a tab reopen.
        case restrictionsUpdated(ChatRestrictions)

        /// The signed-in account's mod status in this channel changed
        /// mid-session. Emitted from two `channel.moderate` v2 signals
        /// (see `enableModerationEvents`):
        ///   - a `mod`/`unmod` action targeting OUR account → true/false.
        ///   - Twitch revoking our `channel.moderate` subscription →
        ///     false (Twitch revokes it when the subscriber stops being
        ///     a mod, so revocation IS the unmod signal when the action
        ///     event loses the race or doesn't arrive).
        /// Consumers flip `currentUserCanModerate`; no row is produced.
        case moderationStatusChanged(canModerate: Bool)
    }

    /// Translate one TwitchKit EventSub event to a chattr ChannelEvent.
    /// Returns nil for event types we don't render OR events whose
    /// broadcaster ID doesn't match this session (defensive — the registry
    /// already routes by broadcaster, but a misrouted event would corrupt
    /// the ring).
    ///
    /// `accountUserId` filters `channel.moderate` traffic down to the two
    /// actions that target OUR account (`mod`/`unmod`) — bans, timeouts,
    /// and settings flips performed by other mods translate to nil until
    /// chattr grows mod-feed features that render them.
    ///
    /// Internal (not private) so ChannelsTests can drive the
    /// moderate/revocation mapping directly with decoded fixtures.
    static func translate(event: EventSubEvent, expectedChannelId: String, accountUserId: String) -> ChannelEvent? {
        switch event {
        case .chatMessage(let m) where m.broadcasterUserId == expectedChannelId:
            return .message(m)
        case .chatNotification(let n) where n.broadcasterUserId == expectedChannelId:
            return .notification(n)
        case .raid(let r) where r.toBroadcasterUserId == expectedChannelId:
            return .raid(r)
        case .chatMessageDelete(let d) where d.broadcasterUserId == expectedChannelId:
            return .messageDeleted(targetMessageId: d.messageId)
        case .chatClear(let c) where c.broadcasterUserId == expectedChannelId:
            return .chatCleared
        case .chatClearUserMessages(let c) where c.broadcasterUserId == expectedChannelId:
            return .messagesClearedFromUser(targetUserId: c.targetUserId)
        case .chatSettingsUpdate(let s) where s.broadcasterUserId == expectedChannelId:
            // Build a ChatRestrictions directly from the EventSub payload.
            // Mirrors `ChatRestrictions.init(from: ChatSettings)` — same
            // semantic fields, different wire shape (slowModeWaitTimeSeconds
            // vs slowModeWaitTime, etc.). Keeping the construction inline
            // here rather than adding another init keeps the field-name
            // diff visible in one place.
            let restrictions = ChatRestrictions(
                slowModeSeconds: s.slowMode ? s.slowModeWaitTimeSeconds : nil,
                followersOnly: s.followerMode,
                followersDurationMinutes: s.followerMode ? s.followerModeDurationMinutes : nil,
                subscribersOnly: s.subscriberMode,
                emoteOnly: s.emoteMode
            )
            return .restrictionsUpdated(restrictions)
        case .moderate(let m) where m.broadcasterUserId == expectedChannelId:
            // Only the actions that change OUR mod status. The payload's
            // `action` string discriminates; the matching nested object
            // carries the target user. Defensive double-check on both —
            // a `mod` action always carries `mod`, but trusting one field
            // when two must agree invites decoding-drift bugs.
            if m.action == "mod", m.mod?.userId == accountUserId {
                return .moderationStatusChanged(canModerate: true)
            }
            if m.action == "unmod", m.unmod?.userId == accountUserId {
                return .moderationStatusChanged(canModerate: false)
            }
            return nil
        case .revocation(let r)
            where r.type == "channel.moderate"
                && r.condition["broadcaster_user_id"] == expectedChannelId
                && r.condition["moderator_user_id"] == accountUserId:
            // Twitch revokes our channel.moderate subscription when the
            // account stops being a mod of the channel — so the revocation
            // is itself an unmod signal, covering the case where the
            // `unmod` action event never reaches us (revocation raced it).
            // Other revocation causes (authorization revoked, version
            // retired) also mean the live feed is dead; downgrading to
            // "unknown" costs at most one badge-observation round-trip to
            // re-prove status, while NOT downgrading would show mod tools
            // backed by no live feed.
            return .moderationStatusChanged(canModerate: false)
        default:
            return nil
        }
    }

    /// Pulls the broadcaster user ID out of any EventSub event we know how
    /// to route. Used by `ChannelSessionRegistry`'s dispatcher to look up
    /// the owning session before calling `handle(event:)`. Returns nil for
    /// event types we don't subscribe to.
    public static func broadcasterUserId(from event: EventSubEvent) -> String? {
        switch event {
        case let .chatMessage(m):                  return m.broadcasterUserId
        case let .chatNotification(n):             return n.broadcasterUserId
        case let .raid(r):                         return r.toBroadcasterUserId
        case let .chatMessageDelete(d):            return d.broadcasterUserId
        case let .chatClear(c):                    return c.broadcasterUserId
        case let .chatClearUserMessages(c):        return c.broadcasterUserId
        case let .chatSettingsUpdate(s):           return s.broadcasterUserId
        case let .moderate(m):                     return m.broadcasterUserId
        // Live-event banners (see ChannelSession+LiveEvents.swift).
        case let .pollBegin(p), let .pollProgress(p), let .pollEnd(p):
            return p.broadcasterUserId
        case let .predictionBegin(p), let .predictionProgress(p), let .predictionLock(p), let .predictionEnd(p):
            return p.broadcasterUserId
        case let .hypeTrainBegin(h), let .hypeTrainProgress(h), let .hypeTrainEnd(h):
            return h.broadcasterUserId
        // Revocations of ANY subscription type route by the condition's
        // broadcaster id — translate() then keeps only channel.moderate
        // ones. Conditions without the key (e.g. user-scoped types we
        // don't use) fall out as nil and are dropped, same as before.
        case let .revocation(r):                   return r.condition["broadcaster_user_id"]
        default:                                    return nil
        }
    }
}
