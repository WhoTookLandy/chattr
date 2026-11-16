import Testing
import Foundation
@testable import ChatModel

@Suite("ChatLinkDetector")
struct ChatLinkDetectorTests {

    @Test("explicit schemes link as-is", arguments: [
        "https://www.twitch.tv/tandeeze",
        "http://example.com/a?b=c",
    ])
    func explicitScheme(word: String) {
        #expect(ChatLinkDetector.url(in: word)?.absoluteString == word)
    }

    @Test("bare domains get https", arguments: [
        ("www.twitch.tv/tandeeze", "https://www.twitch.tv/tandeeze"),
        ("twitch.tv/soochu", "https://twitch.tv/soochu"),
        ("youtu.be/dQw4w9WgXcQ", "https://youtu.be/dQw4w9WgXcQ"),
        ("(twitch.tv/foo).", "https://twitch.tv/foo"),
    ])
    func bareDomain(word: String, expected: String) {
        #expect(ChatLinkDetector.url(in: word)?.absoluteString == expected)
    }

    @Test("ordinary words never link", arguments: [
        "hello", "e.g.", "1.5", "lol...ok", "hello.world", "...", "a.b", "U.S.",
        "https://localhost", "file.txt",
    ])
    func notLinks(word: String) {
        #expect(ChatLinkDetector.url(in: word) == nil)
    }
}
