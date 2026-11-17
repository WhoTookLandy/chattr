import Testing
import Foundation
import TwitchKit
@testable import Channels

/// How chattr learns the SIGNED-IN user is timed out / banned / warned:
/// send drop reasons (`OwnChatRestriction.init(dropCode:message:)`), and the
/// `channel.chat.clear_user_messages` translation that the transcript
/// matches against its own user id.
@Suite("OwnChatRestriction")
struct OwnChatRestrictionTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("msg_timedout with a duration → timedOut(until: now + seconds)")
    func timedOutWithDuration() {
        let restriction = OwnChatRestriction(
            dropCode: "msg_timedout",
            message: "You are timed out for 597 more seconds.",
            now: now
        )
        #expect(restriction == .timedOut(until: now.addingTimeInterval(597)))
        #expect(restriction?.blocksSending(at: now) == true)
        #expect(restriction?.blocksSending(at: now.addingTimeInterval(600)) == false)
    }

    @Test("Timed out without a number → timedOut(until: nil), still sendable")
    func timedOutUnknownLength() {
        let restriction = OwnChatRestriction(dropCode: "msg_timedout", message: "You are timed out.", now: now)
        #expect(restriction == .timedOut(until: nil))
        #expect(restriction?.blocksSending(at: now) == false)
    }

    @Test("A 403 message alone is enough (no code)")
    func messageOnly() {
        #expect(OwnChatRestriction(dropCode: nil, message: "You are banned from this channel.", now: now) == .banned)
        #expect(OwnChatRestriction(dropCode: nil, message: "You are timed out for 30 more seconds", now: now)
                == .timedOut(until: now.addingTimeInterval(30)))
    }

    @Test("msg_banned → banned, which blocks sending")
    func banned() {
        let restriction = OwnChatRestriction(dropCode: "msg_banned", message: "You are permanently banned from talking in xqc.", now: now)
        #expect(restriction == .banned)
        #expect(restriction?.blocksSending(at: now) == true)
    }

    @Test("Warning drops → warned, sendable (acknowledging happens elsewhere)")
    func warned() {
        let restriction = OwnChatRestriction(dropCode: "msg_warned", message: "You must acknowledge your warning.", now: now)
        #expect(restriction == .warned(reason: nil))
        #expect(restriction?.blocksSending(at: now) == false)
    }

    @Test("Drops unrelated to our standing → nil")
    func unrelatedDrops() {
        #expect(OwnChatRestriction(dropCode: "msg_slowmode", message: "This room is in slow mode.", now: now) == nil)
        #expect(OwnChatRestriction(dropCode: "msg_duplicate", message: "Your message is identical to the previous one.", now: now) == nil)
        #expect(OwnChatRestriction(dropCode: "automod_held", message: "Your message is being checked by mods.", now: now) == nil)
        #expect(OwnChatRestriction(dropCode: nil, message: nil, now: now) == nil)
    }

    @Test("Seconds are read from the number before the 'second(s)' word")
    func remainingSecondsParsing() {
        #expect(OwnChatRestriction.remainingSeconds(in: "You are timed out for 597 more seconds.") == 597)
        #expect(OwnChatRestriction.remainingSeconds(in: "Timed out for 1 second") == 1)
        #expect(OwnChatRestriction.remainingSeconds(in: "You are timed out.") == nil)
        #expect(OwnChatRestriction.remainingSeconds(in: "2 users, 10 minutes") == nil)
    }

    @Test("clear_user_messages translates to messagesClearedFromUser for any target, including us")
    func clearUserMessagesTranslation() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let json = """
        {
            "broadcaster_user_id": "chan-1",
            "broadcaster_user_login": "somechannel",
            "broadcaster_user_name": "SomeChannel",
            "target_user_id": "me-42",
            "target_user_login": "me",
            "target_user_name": "Me"
        }
        """
        let clear = try decoder.decode(EventSubChatClearUserMessages.self, from: Data(json.utf8))
        let translated = ChannelSession.translate(
            event: .chatClearUserMessages(clear),
            expectedChannelId: "chan-1",
            accountUserId: "me-42"
        )
        guard case .messagesClearedFromUser(let target)? = translated else {
            Issue.record("Expected .messagesClearedFromUser, got \(String(describing: translated))")
            return
        }
        #expect(target == "me-42")
    }

    @Test("UserBanState reads Twitch's expires_at")
    func userBanStateParsing() {
        #expect(UserBanState(expiresAt: "") == .banned)
        #expect(UserBanState(expiresAt: nil) == .banned)
        #expect(UserBanState(expiresAt: "2026-11-17T10:10:00Z") == .timedOut(until: Date(timeIntervalSince1970: 1_794_910_200)))
        #expect(UserBanState(expiresAt: "2026-11-17T10:10:00.500Z") == .timedOut(until: Date(timeIntervalSince1970: 1_794_910_200.5)))
        #expect(UserBanState.notBanned.isRestricted() == false)
        #expect(UserBanState.timedOut(until: .distantPast).isRestricted() == false)
    }
}
