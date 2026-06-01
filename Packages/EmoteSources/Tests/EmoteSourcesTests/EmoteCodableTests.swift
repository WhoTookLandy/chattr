import Foundation
import Testing
@testable import EmoteSources

@Suite("Emote Codable")
struct EmoteCodableTests {
    @Test("Emote round-trips through JSON with all sizes and flags")
    func emoteRoundTrips() throws {
        let original = Emote(
            id: "7tv:abc123",
            name: "PogChamp",
            urls: [
                .x1: URL(string: "https://cdn.7tv.app/abc/1x.webp")!,
                .x2: URL(string: "https://cdn.7tv.app/abc/2x.webp")!,
                .x4: URL(string: "https://cdn.7tv.app/abc/4x.webp")!,
            ],
            isAnimated: true,
            isZeroWidth: false,
            source: .sevenTV,
            ownerChannelId: "12345"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Emote.self, from: data)

        #expect(decoded == original)
        #expect(decoded.urls[.x4]?.absoluteString == "https://cdn.7tv.app/abc/4x.webp")
        #expect(decoded.source == .sevenTV)
        #expect(decoded.ownerChannelId == "12345")
    }

    @Test("Global emote (nil ownerChannelId) round-trips")
    func globalEmoteRoundTrips() throws {
        let original = Emote(
            id: "bttv:zzz",
            name: "KEKW",
            urls: [.x1: URL(string: "https://cdn.betterttv.net/zzz/1x")!],
            isAnimated: false,
            isZeroWidth: false,
            source: .bttv,
            ownerChannelId: nil
        )
        let decoded = try JSONDecoder().decode(Emote.self, from: try JSONEncoder().encode(original))
        #expect(decoded == original)
        #expect(decoded.ownerChannelId == nil)
    }
}
