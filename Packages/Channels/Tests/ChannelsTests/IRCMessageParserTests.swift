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
        // Empty emotes tag → single text fragment; the Normalizer handles
        // 3rd-party emote resolution downstream.
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

    @Test("Parses emotes tag into interleaved text + emote fragments")
    func emotesTagSingleEmote() throws {
        // Kappa (emote id 25) at offsets 6-10 of "hello Kappa world".
        let line = "@emotes=25:6-10;id=1;room-id=1;user-id=2 :nick!nick@nick.tmi.twitch.tv PRIVMSG #ch :hello Kappa world"
        let message = try #require(IRCMessageParser.parse(line, channelLogin: "ch"))

        #expect(message.message.text == "hello Kappa world")
        let fragments = message.message.fragments
        try #require(fragments.count == 3)
        #expect(fragments[0].type == .text)
        #expect(fragments[0].text == "hello ")
        #expect(fragments[1].type == .emote)
        #expect(fragments[1].text == "Kappa")
        #expect(fragments[1].emote?.id == "25")
        #expect(fragments[2].type == .text)
        #expect(fragments[2].text == " world")
    }

    @Test("Emote offsets are UTF-16 code units — emoji before the emote")
    func emotesTagAfterEmoji() throws {
        // "👍👍 Kappa hi" — each 👍 is TWO UTF-16 code units (surrogate
        // pair), so Kappa spans UTF-16 offsets 5-9. A parser that counts
        // Characters (or scalars) would slice mid-emoji or off-by-N.
        let line = "@emotes=25:5-9;id=1;room-id=1;user-id=2 :nick!nick@nick.tmi.twitch.tv PRIVMSG #ch :👍👍 Kappa hi"
        let message = try #require(IRCMessageParser.parse(line, channelLogin: "ch"))

        let fragments = message.message.fragments
        try #require(fragments.count == 3)
        #expect(fragments[0].type == .text)
        #expect(fragments[0].text == "👍👍 ")
        #expect(fragments[1].type == .emote)
        #expect(fragments[1].text == "Kappa")
        #expect(fragments[1].emote?.id == "25")
        #expect(fragments[2].text == " hi")
    }

    @Test("Multiple emotes, including repeats of the same emote id")
    func emotesTagMultipleEmotes() throws {
        // "Kappa Keepo Kappa" — Kappa (25) at 0-4 and 12-16, Keepo (1902)
        // at 6-10. The tag groups ranges per emote id, slash-separated, so
        // occurrences arrive out of message order and must be re-sorted.
        let line = "@emotes=25:0-4,12-16/1902:6-10;id=1;room-id=1;user-id=2 :nick!nick@nick.tmi.twitch.tv PRIVMSG #ch :Kappa Keepo Kappa"
        let message = try #require(IRCMessageParser.parse(line, channelLogin: "ch"))

        let fragments = message.message.fragments
        try #require(fragments.count == 5)
        #expect(fragments.map(\.type) == [.emote, .text, .emote, .text, .emote])
        #expect(fragments[0].emote?.id == "25")
        #expect(fragments[1].text == " ")
        #expect(fragments[2].emote?.id == "1902")
        #expect(fragments[2].text == "Keepo")
        #expect(fragments[4].emote?.id == "25")
        // Fragment texts must concatenate back to the full message.
        #expect(fragments.map(\.text).joined() == "Kappa Keepo Kappa")
    }

    @Test("Whole-message emote produces a single emote fragment")
    func emotesTagWholeMessage() throws {
        let line = "@emotes=25:0-4;id=1;room-id=1;user-id=2 :nick!nick@nick.tmi.twitch.tv PRIVMSG #ch :Kappa"
        let message = try #require(IRCMessageParser.parse(line, channelLogin: "ch"))

        let fragments = message.message.fragments
        try #require(fragments.count == 1)
        #expect(fragments[0].type == .emote)
        #expect(fragments[0].text == "Kappa")
        #expect(fragments[0].emote?.id == "25")
    }

    @Test("Out-of-range or malformed emote ranges fall back to plain text")
    func emotesTagOutOfRange() throws {
        // Defensive: rustlog occasionally relays truncated messages whose
        // emote ranges no longer fit. Bad ranges are dropped, not crashed on.
        let line = "@emotes=25:50-60;id=1;room-id=1;user-id=2 :nick!nick@nick.tmi.twitch.tv PRIVMSG #ch :hi"
        let message = try #require(IRCMessageParser.parse(line, channelLogin: "ch"))

        let fragments = message.message.fragments
        try #require(fragments.count == 1)
        #expect(fragments[0].type == .text)
        #expect(fragments[0].text == "hi")
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

    @Test("tmi-sent-ts (epoch ms) becomes the record's send time")
    func parsesSentTimestamp() throws {
        let line = "@id=t-1;room-id=1;tmi-sent-ts=1700000000123;user-id=2 :nick!nick@nick.tmi.twitch.tv PRIVMSG #ch :hi"
        let record = try #require(IRCMessageParser.parseRecord(line, channelLogin: "ch"))
        #expect(record.message.messageId == "t-1")
        let sentAt = try #require(record.sentAt)
        #expect(abs(sentAt.timeIntervalSince1970 - 1_700_000_000.123) < 0.000_5)
    }

    @Test("A missing or malformed tmi-sent-ts leaves the send time unset")
    func missingSentTimestamp() throws {
        let missing = "@id=t-2;room-id=1;user-id=2 :nick!nick@nick.tmi.twitch.tv PRIVMSG #ch :hi"
        let withoutTag = try #require(IRCMessageParser.parseRecord(missing, channelLogin: "ch"))
        #expect(withoutTag.sentAt == nil)
        let garbage = "@id=t-3;room-id=1;tmi-sent-ts=soon;user-id=2 :nick!nick@nick.tmi.twitch.tv PRIVMSG #ch :hi"
        let malformed = try #require(IRCMessageParser.parseRecord(garbage, channelLogin: "ch"))
        #expect(malformed.sentAt == nil)
    }
}
