import Testing
import Foundation
import TwitchKit
@testable import Channels

/// Tests for `ChannelSession.translate`'s `channel.moderate` v2 mapping —
/// the live mod-status signals behind `.moderationStatusChanged`. Payloads
/// are decoded from JSON fixtures with the same snake_case strategy
/// TwitchKit's wire decoder uses, because `EventSubModerate` /
/// `EventSubRevocation` expose no public memberwise inits — and decoding
/// the real wire shape is a better test anyway.
@Suite("ChannelSession moderation-event translation")
struct ChannelSessionModerationTests {

    private let channelId = "chan-1"
    private let accountUserId = "me-42"

    /// Mirrors `JSONDecoder.twitch()`'s key strategy. (Dictionary KEYS —
    /// e.g. a revocation's `condition` — are exempt from the strategy in
    /// modern Foundation, so they arrive verbatim snake_case.)
    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    /// A `channel.moderate` payload performing `action` against one
    /// target user, carried in the action's matching nested field
    /// (`"mod"`, `"unmod"`, `"ban"`, …) the way Twitch shapes it.
    private func moderateEvent(
        action: String,
        targetField: String,
        targetUserId: String,
        broadcasterId: String? = nil
    ) throws -> EventSubModerate {
        let json = """
        {
            "broadcaster_user_id": "\(broadcasterId ?? channelId)",
            "broadcaster_user_login": "somechannel",
            "broadcaster_user_name": "SomeChannel",
            "moderator_user_id": "actor-7",
            "moderator_user_login": "someactor",
            "moderator_user_name": "SomeActor",
            "action": "\(action)",
            "\(targetField)": {
                "user_id": "\(targetUserId)",
                "user_login": "target",
                "user_name": "Target"
            }
        }
        """
        return try decoder.decode(EventSubModerate.self, from: Data(json.utf8))
    }

    private func revocation(
        type: String,
        status: String = "moderator_removed",
        broadcasterId: String? = nil,
        moderatorId: String? = nil
    ) throws -> EventSubRevocation {
        let json = """
        {
            "id": "sub-1",
            "status": "\(status)",
            "type": "\(type)",
            "version": "2",
            "condition": {
                "broadcaster_user_id": "\(broadcasterId ?? channelId)",
                "moderator_user_id": "\(moderatorId ?? accountUserId)"
            }
        }
        """
        return try decoder.decode(EventSubRevocation.self, from: Data(json.utf8))
    }

    private func translate(_ event: EventSubEvent) -> ChannelSession.ChannelEvent? {
        ChannelSession.translate(
            event: event,
            expectedChannelId: channelId,
            accountUserId: accountUserId
        )
    }

    // MARK: - mod / unmod actions

    @Test("unmod targeting our account → moderationStatusChanged(false)")
    func unmodSelf() throws {
        let m = try moderateEvent(action: "unmod", targetField: "unmod", targetUserId: accountUserId)
        guard case .moderationStatusChanged(let canModerate)? = translate(.moderate(m)) else {
            Issue.record("Expected .moderationStatusChanged")
            return
        }
        #expect(!canModerate)
    }

    @Test("mod targeting our account → moderationStatusChanged(true)")
    func modSelf() throws {
        let m = try moderateEvent(action: "mod", targetField: "mod", targetUserId: accountUserId)
        guard case .moderationStatusChanged(let canModerate)? = translate(.moderate(m)) else {
            Issue.record("Expected .moderationStatusChanged")
            return
        }
        #expect(canModerate)
    }

    @Test("unmod targeting a DIFFERENT user → nil (not our status)")
    func unmodOther() throws {
        let m = try moderateEvent(action: "unmod", targetField: "unmod", targetUserId: "someone-else")
        #expect(translate(.moderate(m)) == nil)
    }

    @Test("Non-mod actions (ban) → nil until mod-feed features render them")
    func banAction() throws {
        let m = try moderateEvent(action: "ban", targetField: "ban", targetUserId: accountUserId)
        #expect(translate(.moderate(m)) == nil)
    }

    @Test("Wrong-channel moderate event → nil (defensive routing check)")
    func wrongChannel() throws {
        let m = try moderateEvent(action: "unmod", targetField: "unmod", targetUserId: accountUserId, broadcasterId: "other-chan")
        #expect(translate(.moderate(m)) == nil)
    }

    // MARK: - Revocation

    @Test("channel.moderate revocation for our subscription → moderationStatusChanged(false)")
    func moderateRevocation() throws {
        let r = try revocation(type: "channel.moderate")
        guard case .moderationStatusChanged(let canModerate)? = translate(.revocation(r)) else {
            Issue.record("Expected .moderationStatusChanged")
            return
        }
        #expect(!canModerate)
    }

    @Test("Revocation of an unrelated subscription type → nil")
    func unrelatedRevocation() throws {
        let r = try revocation(type: "channel.chat.message")
        #expect(translate(.revocation(r)) == nil)
    }

    @Test("channel.moderate revocation for a different moderator → nil")
    func otherModeratorRevocation() throws {
        let r = try revocation(type: "channel.moderate", moderatorId: "someone-else")
        #expect(translate(.revocation(r)) == nil)
    }

    // MARK: - Dispatcher routing

    @Test("broadcasterUserId(from:) routes moderate events and revocations")
    func routing() throws {
        let m = try moderateEvent(action: "unmod", targetField: "unmod", targetUserId: accountUserId)
        #expect(ChannelSession.broadcasterUserId(from: .moderate(m)) == channelId)
        let r = try revocation(type: "channel.moderate")
        #expect(ChannelSession.broadcasterUserId(from: .revocation(r)) == channelId)
    }
}
