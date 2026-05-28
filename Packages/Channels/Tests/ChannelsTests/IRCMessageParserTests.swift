import Testing
import Foundation
@testable import Channels

/// Tests for the IRC tag-format parser inside `BackfillProvider`.
///
/// The parser is internal-but-`internal` access (chattr's only consumer is
/// `BackfillProvider`); we use `@testable import` to reach it. Each test
/// pins one decoding rule against a representative real-world IRC line —
/// captured from rustlog's actual API responses where possible.
@Suite("IRCMessageParser")
struct IRCMessageParserTests {

    @Test("Parses a basic PRIVMSG with display name + color + badges")
    func basicPrivmsg() throws {
        let line = "@badge-info=;badges=moderator/1;color=#FF0000;display-name=ModUser;emotes=;flags=;id=abc-123;mod=1;room-id=99999;subscriber=0;tmi-sent-ts=1700000000000;turbo=0;user-id=11111;user-type=mod :moduser!moduser@moduser.tmi.twitch.tv PRIVMSG #lirik :hello world"
        let message = try #require(IRCMessageParser.parse(line, channelLogin: "lirik"))

        #expect(message.messageId == "abc-123")
        #expect(message.chatterUserId == "11111")
        #expect(message.chatterUserLogin == "moduser")
        #expect(message.chatterUserName == "ModUser")
        #expect(message.broadcasterUserId == "99999")
        #expect(message.broadcasterUserLogin == "lirik")
        #expect(message.color == "#FF0000")
        #expect(message.message.text == "hello world")
        // Single text fragment — IRC doesn't pre-tokenize emotes the same
        // way EventSub does; the Normalizer handles 3rd-party emote
        // resolution downstream.
        #expect(message.message.fragments.count == 1)
        #expect(message.message.fragments.first?.text == "hello world")
        #expect(message.badges.count == 1)
        #expect(message.badges.first?.setId == "moderator")
        #expect(message.badges.first?.id == "1")
    }

    @Test("Falls back to nick when display-name is missing")
    func missingDisplayNameUsesNick() throws {
        // Some Twitch users have no display name set — Twitch sends the
        // tag empty in that case. Our parser falls back to nick.
        let line = "@badge-info=;badges=;color=;display-name=;id=def-456;room-id=1;user-id=22222 :anon!anon@anon.tmi.twitch.tv PRIVMSG #ch :greetings"
        let message = try #require(IRCMessageParser.parse(line, channelLogin: "ch"))
        #expect(message.chatterUserName == "anon")
    }

    @Test("Unescapes IRC tag values (\\s for space, \\\\: for ;)")
    func unescapesTagValues() throws {
        // display-name="My Name; Cool" → encoded as "My\sName\:\sCool"
        // (\s = space, \: = ;)
        let line = #"@display-name=My\sName\:\sCool;id=xyz;room-id=1;user-id=3 :nick!nick@nick.tmi.twitch.tv PRIVMSG #ch :hi"#
        let message = try #require(IRCMessageParser.parse(line, channelLogin: "ch"))
        #expect(message.chatterUserName == "My Name; Cool")
    }

    @Test("Multi-word message body with colon in text")
    func messageBodyWithColon() throws {
        // Real chat messages can contain `:` in them (URLs, emoji, etc.).
        // Our split on " :" must only consume the FIRST occurrence — the
        // rest is part of the message body verbatim.
        let line = "@id=1;room-id=1;user-id=2 :nick!nick@nick.tmi.twitch.tv PRIVMSG #ch :check this: https://example.com/foo"
        let message = try #require(IRCMessageParser.parse(line, channelLogin: "ch"))
        #expect(message.message.text == "check this: https://example.com/foo")
    }

    @Test("Parses multi-badge tag")
    func multiBadge() throws {
        let line = "@badges=broadcaster/1,subscriber/12,partner/1;id=1;room-id=1;user-id=2 :nick!nick@nick.tmi.twitch.tv PRIVMSG #ch :hey"
        let message = try #require(IRCMessageParser.parse(line, channelLogin: "ch"))
        #expect(message.badges.count == 3)
        #expect(message.badges.map(\.setId).sorted() == ["broadcaster", "partner", "subscriber"])
    }

    @Test("Returns nil for non-PRIVMSG lines (USERNOTICE, JOIN, etc.)")
    func nonPrivmsgReturnsNil() {
        // rustlog sometimes includes USERNOTICE (subs/raids) and JOIN/PART
        // in its history. Backfill is currently chat-only — return nil
        // for everything that isn't PRIVMSG so the caller's compactMap
        // filters them out cleanly.
        let usernotice = "@badge-info=;badges= :tmi.twitch.tv USERNOTICE #ch :resubscribed"
        let join = ":nick!nick@nick.tmi.twitch.tv JOIN #ch"
        #expect(IRCMessageParser.parse(usernotice, channelLogin: "ch") == nil)
        #expect(IRCMessageParser.parse(join, channelLogin: "ch") == nil)
    }

    @Test("Returns nil for malformed lines")
    func malformedReturnsNil() {
        // Missing tag prefix
        #expect(IRCMessageParser.parse("not an irc line", channelLogin: "ch") == nil)
        // Tag block but no rest
        #expect(IRCMessageParser.parse("@tag=value", channelLogin: "ch") == nil)
        // Truncated source
        #expect(IRCMessageParser.parse("@id=1 :nick PRIVMSG #ch :hi", channelLogin: "ch") == nil)
    }

    @Test("Synthesizes message_id when tag is missing")
    func synthesizesMissingMessageId() throws {
        // If rustlog ever returns a line without an `id` tag, parser
        // synthesizes a UUID. Otherwise SwiftUI ForEach would dedupe
        // multiple "no id" messages to one row.
        let line = "@room-id=1;user-id=2 :nick!nick@nick.tmi.twitch.tv PRIVMSG #ch :hi"
        let m1 = try #require(IRCMessageParser.parse(line, channelLogin: "ch"))
        let m2 = try #require(IRCMessageParser.parse(line, channelLogin: "ch"))
        #expect(m1.messageId != m2.messageId)
    }
}
