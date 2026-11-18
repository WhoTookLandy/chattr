import Testing
import Foundation
import ChatModel
import EmoteSources
@testable import Features

/// The pure pieces of guest chat ingest: tag unescaping, the line buffer
/// the view renders from, and the reconnect ladder. The socket itself isn't
/// exercised here.
@Suite("Guest chat ingest")
struct GuestChatIngestTests {

    private func message(_ id: String, userId: String = "u1", text: String = "hi") -> GuestChatMessage {
        GuestChatMessage(
            id: id,
            userId: userId,
            author: "Author",
            color: nil,
            text: text,
            isAction: false,
            login: "author",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func emote(_ name: String) -> Emote {
        Emote(
            id: "7tv:\(name)",
            name: name,
            urls: [:],
            isAnimated: false,
            isZeroWidth: false,
            source: .sevenTV
        )
    }

    // MARK: - Tag values

    @Test("IRCv3 tag escapes are reversed", arguments: [
        ("plain", "plain"),
        (#"Some\sUser"#, "Some User"),
        (#"a\:b"#, "a;b"),
        (#"back\\slash"#, #"back\slash"#),
        (#"line\r\nbreak"#, "line\r\nbreak"),
        (#"odd\xescape"#, "oddxescape"),
        (#"trailing\"#, #"trailing\"#),
        (#"\\s"#, #"\s"#),
    ])
    func unescapesTagValues(escaped: String, expected: String) {
        #expect(GuestIRC.unescapeTagValue(Substring(escaped)) == expected)
    }

    @Test("A parsed line carries unescaped tag values")
    func parsedLineUnescapesTags() throws {
        let line = #"@display-name=Some\sUser;id=m1;system-msg=5\:1 :someuser!someuser@someuser.tmi.twitch.tv PRIVMSG #channel :hello"#
        let irc = try #require(IRCLine(line))
        #expect(irc.tags["display-name"] == "Some User")
        #expect(irc.tags["system-msg"] == "5;1")
        #expect(GuestIRC.parsePrivmsg(line)?.author == "Some User")
    }

    // MARK: - Emote references

    @Test("Asking for the same Twitch emote twice gives the same reference")
    func referencesAreStablePerId() throws {
        let first = try #require(GuestIRC.twitchEmoteReference(id: "guest-ingest-25"))
        let second = try #require(GuestIRC.twitchEmoteReference(id: "guest-ingest-25"))
        #expect(first == second)
        #expect(first.id == "guest-ingest-25")
        #expect(first.format == ["static"])
    }

    // MARK: - Buffer

    @Test("Each message's line is built on arrival, in order")
    func appendBuildsLines() {
        var buffer = GuestChatBuffer()
        #expect(buffer.isEmpty)
        buffer.append(message("m1", text: "hello there"))
        buffer.append(message("m2", text: "again"))

        #expect(buffer.lines.map(\.id) == ["m1", "m2"])
        #expect(buffer.lines.first?.runs == [.text("hello"), .text("there")])
        #expect(buffer.lines.first?.authorDisplayName == "Author")
        #expect(buffer.lines.first?.timestamp == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(buffer.revision == 2)
    }

    @Test("Only the newest 300 messages are kept")
    func capsAtMaxMessages() {
        var buffer = GuestChatBuffer()
        for index in 0..<(GuestChatBuffer.maxMessages + 5) {
            buffer.append(message("m\(index)"))
        }
        let lines = buffer.lines
        #expect(lines.count == GuestChatBuffer.maxMessages)
        #expect(lines.first?.id == "m5")
        #expect(lines.last?.id == "m\(GuestChatBuffer.maxMessages + 4)")
    }

    @Test("Moderation removes one message, one user's messages, or everything")
    func moderationRemovals() {
        var buffer = GuestChatBuffer()
        buffer.append(message("m1", userId: "alice"))
        buffer.append(message("m2", userId: "bob"))
        buffer.append(message("m3", userId: "alice"))
        buffer.append(message("m4", userId: "carol"))

        buffer.removeMessage(id: "m2")
        #expect(buffer.lines.map(\.id) == ["m1", "m3", "m4"])

        buffer.removeMessages(fromUserId: "alice")
        #expect(buffer.lines.map(\.id) == ["m4"])

        buffer.removeAll()
        #expect(buffer.isEmpty)
    }

    @Test("The revision changes only when the lines do")
    func revisionTracksChanges() {
        var buffer = GuestChatBuffer()
        buffer.removeAll()
        buffer.setEmotes([:])
        #expect(buffer.revision == 0)

        buffer.append(message("m1"))
        let afterAppend = buffer.revision
        buffer.removeMessage(id: "missing")
        buffer.removeMessages(fromUserId: "nobody")
        #expect(buffer.revision == afterAppend)

        buffer.removeMessage(id: "m1")
        #expect(buffer.revision != afterAppend)
    }

    @Test("Lines built before the emote table arrived are rebuilt with it")
    func emoteTableRebuildsExistingLines() {
        var buffer = GuestChatBuffer()
        buffer.append(message("m1", text: "nice Pog"))
        #expect(buffer.lines.first?.runs == [.text("nice"), .text("Pog")])
        let before = buffer.revision

        let pog = emote("Pog")
        buffer.setEmotes(["Pog": pog])
        #expect(buffer.lines.first?.runs == [.text("nice"), .emote(pog)])
        #expect(buffer.revision != before)

        // Later messages use the table directly, and installing the same
        // table again changes nothing.
        buffer.append(message("m2", text: "Pog"))
        #expect(buffer.lines.last?.runs == [.emote(pog)])
        let settled = buffer.revision
        buffer.setEmotes(["Pog": pog])
        #expect(buffer.revision == settled)
    }

    // MARK: - Reconnect ladder

    @Test("Failed attempts back off 1, 2, 4, 8, 16, 30, 30 seconds")
    func backoffLadder() {
        var policy = GuestReconnectPolicy()
        let delays = (0..<7).map { _ in policy.nextDelay(connectedFor: nil) }
        #expect(delays == [1, 2, 4, 8, 16, 30, 30])
    }

    @Test("A connection that drops soon after joining keeps climbing the ladder")
    func shortConnectionDoesNotResetBackoff() {
        var policy = GuestReconnectPolicy()
        #expect(policy.nextDelay(connectedFor: nil) == 1)
        #expect(policy.nextDelay(connectedFor: .seconds(5)) == 2)
        #expect(policy.nextDelay(connectedFor: .seconds(29)) == 4)
    }

    @Test("A connection that stayed up starts the ladder over")
    func stableConnectionResetsBackoff() {
        var policy = GuestReconnectPolicy()
        for _ in 0..<4 { _ = policy.nextDelay(connectedFor: nil) }
        #expect(policy.nextDelay(connectedFor: GuestReconnectPolicy.stableAfter) == 1)
        #expect(policy.nextDelay(connectedFor: nil) == 2)
    }
}
