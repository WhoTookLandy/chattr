import Testing
import Foundation
@testable import ChatModel

@Suite("TwitchClipLink")
struct TwitchClipLinkTests {

    @Test("clip links yield their slug", arguments: [
        ("https://clips.twitch.tv/BraveSmoggyCatKappa-AbC_123", "BraveSmoggyCatKappa-AbC_123"),
        ("https://clips.twitch.tv/embed?clip=FunnyClip-xyz&parent=foo", "FunnyClip-xyz"),
        ("https://www.twitch.tv/soochu/clip/TallClip-Q1w2", "TallClip-Q1w2"),
        ("https://m.twitch.tv/soochu/clip/TallClip-Q1w2?filter=clips", "TallClip-Q1w2"),
        ("https://twitch.tv/clip/RootClip", "RootClip"),
        ("https://twitch.tv/clips/RootClips", "RootClips"),
    ])
    func clipLinks(link: String, slug: String) throws {
        let url = try #require(URL(string: link))
        #expect(TwitchClipLink.slug(in: url) == slug)
    }

    @Test("other Twitch and non-Twitch links are not clips", arguments: [
        "https://www.twitch.tv/soochu",
        "https://www.twitch.tv/soochu/clips",
        "https://www.twitch.tv/soochu/clips?filter=clips&range=7d",
        "https://www.twitch.tv/soochu/videos/123",
        "https://clips.twitch.tv/create",
        "https://clips.twitch.tv/embed",
        "https://clips.twitch.tv/",
        "https://example.com/soochu/clip/NotTwitch",
        "https://clips.twitch.tv/bad%20slug",
    ])
    func notClips(link: String) throws {
        let url = try #require(URL(string: link))
        #expect(TwitchClipLink.slug(in: url) == nil)
    }

    @Test("detector output feeds the clip parser")
    func bareWordRoundTrip() throws {
        let url = try #require(ChatLinkDetector.url(in: "clips.twitch.tv/BraveClip-abc"))
        #expect(TwitchClipLink.slug(in: url) == "BraveClip-abc")
    }
}
