import Testing
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

    @Test("Ignores non-PRIVMSG lines")
    func ignoresOthers() {
        #expect(AnonymousChatReader.parsePrivmsg(":tmi.twitch.tv 001 justinfan123 :Welcome, GLHF!") == nil)
        #expect(AnonymousChatReader.parsePrivmsg("PING :tmi.twitch.tv") == nil)
    }
}
