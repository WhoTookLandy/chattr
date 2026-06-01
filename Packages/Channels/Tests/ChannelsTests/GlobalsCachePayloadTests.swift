import Foundation
import Testing
import TwitchKit
@testable import Channels

@Suite("GlobalsCachePayload")
struct GlobalsCachePayloadTests {
    @Test("badge dictionary survives the DTO round-trip")
    func badgeDictRoundTrips() throws {
        let badges: [ChatBadgeKey: ChatBadgeEntry] = [
            ChatBadgeKey(setId: "moderator", id: "1"):
                ChatBadgeEntry(url: URL(string: "https://badge/mod")!, title: "Moderator"),
            ChatBadgeKey(setId: "subscriber", id: "0"):
                ChatBadgeEntry(url: URL(string: "https://badge/sub")!, title: nil),
        ]
        let payload = GlobalsCachePayload(badges: badges, emotes: [:])

        let decoded = try JSONDecoder().decode(
            GlobalsCachePayload.self, from: try JSONEncoder().encode(payload))

        #expect(decoded.badgeDictionary == badges)
        #expect(GlobalsCachePayload.cacheVersion == 1)
    }
}
