import Testing
import Foundation
import ChatModel
import TwitchKit
@testable import Features

@MainActor
@Suite("AnonymousChatReader.parsePrivmsg")
struct AnonymousChatReaderTests {
    @Test("Parses a tagged PRIVMSG")
    func tagged() throws {
        let line = "@badge-info=;color=#FF4500;display-name=SomeUser;id=abc-123 :someuser!someuser@someuser.tmi.twitch.tv PRIVMSG #channel :hello there: friend"
        let message = try #require(AnonymousChatReader.parsePrivmsg(line))
        #expect(message.id == "abc-123")
        #expect(message.author == "SomeUser")
        #expect(message.color == "#FF4500")
        #expect(message.text == "hello there: friend")
        #expect(!message.isAction)
    }

    @Test("Falls back to the login when display-name is empty")
    func emptyDisplayName() throws {
        let line = "@color=;display-name= :lurker!lurker@lurker.tmi.twitch.tv PRIVMSG #channel :hi"
        let message = try #require(AnonymousChatReader.parsePrivmsg(line))
        #expect(message.author == "lurker")
        #expect(message.color == nil)
    }

    @Test("Unwraps /me actions")
    func action() throws {
        let line = ":bot!bot@bot.tmi.twitch.tv PRIVMSG #channel :\u{1}ACTION waves\u{1}"
        let message = try #require(AnonymousChatReader.parsePrivmsg(line))
        #expect(message.isAction)
        #expect(message.text == "waves")
    }

    @Test("Parses moderation commands' tags and target")
    func moderationLines() throws {
        let clearMsg = try #require(IRCLine("@login=someone;target-msg-id=abc-123 :tmi.twitch.tv CLEARMSG #channel :bad words"))
        #expect(clearMsg.command == "CLEARMSG")
        #expect(clearMsg.tags["target-msg-id"] == "abc-123")

        let timeout = try #require(IRCLine("@ban-duration=600;target-user-id=42 :tmi.twitch.tv CLEARCHAT #channel :someone"))
        #expect(timeout.command == "CLEARCHAT")
        #expect(timeout.tags["target-user-id"] == "42")

        let clearAll = try #require(IRCLine(":tmi.twitch.tv CLEARCHAT #channel"))
        #expect(clearAll.tags["target-user-id"] == nil)
        #expect(clearAll.params == ["#channel"])
    }

    @Test("Uses Twitch's send time as a stable timestamp")
    func sentTimestamp() throws {
        let line = "@id=m1;tmi-sent-ts=1700000000123 :a!a@a.tmi.twitch.tv PRIVMSG #channel :hi"
        let message = try #require(AnonymousChatReader.parsePrivmsg(line))
        #expect(message.timestamp == Date(timeIntervalSince1970: 1_700_000_000.123))
        #expect(message == AnonymousChatReader.parsePrivmsg(line))
    }

    @Test("Keeps the sender's user id for user-wide removal")
    func userId() throws {
        let line = "@display-name=A;user-id=42;id=m1 :a!a@a.tmi.twitch.tv PRIVMSG #channel :hi"
        #expect(try #require(AnonymousChatReader.parsePrivmsg(line)).userId == "42")
    }

    @Test("Parses the emotes tag into sorted spans")
    func emoteSpans() {
        let spans = AnonymousChatReader.parseEmoteSpans("1902:6-10/25:0-4,12-16")
        #expect(spans == [
            .init(id: "25", start: 0, end: 4),
            .init(id: "1902", start: 6, end: 10),
            .init(id: "25", start: 12, end: 16),
        ])
        #expect(AnonymousChatReader.parseEmoteSpans("").isEmpty)
    }

    @Test("Builds Twitch emote runs at their positions")
    func twitchEmoteRuns() {
        let runs = AnonymousChatReader.runs(
            text: "Kappa hi Kappa",
            spans: AnonymousChatReader.parseEmoteSpans("25:0-4,9-13"),
            emotes: [:]
        )
        let emoteNames = runs.compactMap { run -> String? in
            if case .twitchEmote(_, let name) = run { return name }
            return nil
        }
        #expect(emoteNames == ["Kappa", "Kappa"])
        #expect(runs.contains(.text("hi")))
    }

    @Test("Emote positions count unicode scalars, not UTF-16")
    func scalarPositions() {
        // 😀 is one scalar (two UTF-16 units); Kappa starts at scalar 2.
        let runs = AnonymousChatReader.runs(
            text: "😀 Kappa",
            spans: AnonymousChatReader.parseEmoteSpans("25:2-6"),
            emotes: [:]
        )
        let names = runs.compactMap { run -> String? in
            if case .twitchEmote(_, let name) = run { return name }
            return nil
        }
        #expect(names == ["Kappa"])
    }

    @Test("A Twitch emote reference can be built from an id")
    func reference() throws {
        let reference = try #require(AnonymousChatReader.twitchEmoteReference(id: "25"))
        #expect(reference.id == "25")
        #expect(reference.format == ["static"])
    }

    @Test("Ignores non-PRIVMSG lines")
    func ignoresOthers() {
        #expect(AnonymousChatReader.parsePrivmsg(":tmi.twitch.tv 001 justinfan123 :Welcome, GLHF!") == nil)
        #expect(AnonymousChatReader.parsePrivmsg("PING :tmi.twitch.tv") == nil)
    }
}
