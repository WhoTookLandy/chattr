import Testing
import Foundation
import TwitchKit
@testable import Features

/// `ChannelStatusStore.mergedLiveStream`: which of the two live-status
/// sources (the open-channel status store, the follows live list) answers
/// for a channel.
@Suite("Channel live-status merge")
struct ChannelStatusMergeTests {

    /// `TwitchStream` is Decodable-only, so build one from JSON shaped like
    /// the already-camelCased model.
    private func stream(viewers: Int) throws -> TwitchStream {
        let json = """
        {
          "id": "1", "userId": "100", "userLogin": "soochu", "userName": "Soochu",
          "gameId": "509658", "gameName": "Just Chatting", "type": "live",
          "title": "hello", "tags": [], "viewerCount": \(viewers),
          "startedAt": "2026-06-12T14:02:11Z", "language": "en",
          "thumbnailUrl": "https://x/live_user_soochu-{width}x{height}.jpg",
          "isMature": false
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TwitchStream.self, from: Data(json.utf8))
    }

    private let earlier = Date(timeIntervalSince1970: 1_000_000)
    private let later = Date(timeIntervalSince1970: 1_000_090)

    @Test("A newer follows refresh that no longer lists the channel wins: not live")
    func newerFollowsOfflineWins() throws {
        let merged = ChannelStatusStore.mergedLiveStream(
            statusStream: try stream(viewers: 10),
            statusFetchedAt: earlier,
            followedStream: nil,
            followsRefreshedAt: later,
            isFollowed: true
        )
        #expect(merged == nil)
    }

    @Test("A newer status fetch that found the channel offline wins: not live")
    func newerStatusOfflineWins() throws {
        let merged = ChannelStatusStore.mergedLiveStream(
            statusStream: nil,
            statusFetchedAt: later,
            followedStream: try stream(viewers: 10),
            followsRefreshedAt: earlier,
            isFollowed: true
        )
        #expect(merged == nil)
    }

    @Test("When both say live, the newer one's numbers are used")
    func newerLiveWins() throws {
        let fromStatus = try stream(viewers: 10)
        let fromFollows = try stream(viewers: 20)
        #expect(ChannelStatusStore.mergedLiveStream(
            statusStream: fromStatus, statusFetchedAt: later,
            followedStream: fromFollows, followsRefreshedAt: earlier,
            isFollowed: true
        )?.viewerCount == 10)
        #expect(ChannelStatusStore.mergedLiveStream(
            statusStream: fromStatus, statusFetchedAt: earlier,
            followedStream: fromFollows, followsRefreshedAt: later,
            isFollowed: true
        )?.viewerCount == 20)
    }

    @Test("The follows list says nothing about a channel that isn't followed")
    func notFollowedKeepsStatus() throws {
        let merged = ChannelStatusStore.mergedLiveStream(
            statusStream: try stream(viewers: 10),
            statusFetchedAt: earlier,
            followedStream: nil,
            followsRefreshedAt: later,
            isFollowed: false
        )
        #expect(merged?.viewerCount == 10)
    }

    @Test("Before the follows list has loaded, the status store answers")
    func followsNotLoadedYet() throws {
        let merged = ChannelStatusStore.mergedLiveStream(
            statusStream: try stream(viewers: 10),
            statusFetchedAt: earlier,
            followedStream: nil,
            followsRefreshedAt: nil,
            isFollowed: true
        )
        #expect(merged?.viewerCount == 10)
    }

    @Test("Stream state the status store never fetched defers to the follows list")
    func unfetchedStatusDefers() throws {
        let merged = ChannelStatusStore.mergedLiveStream(
            statusStream: nil,
            statusFetchedAt: .distantPast,
            followedStream: try stream(viewers: 20),
            followsRefreshedAt: later,
            isFollowed: true
        )
        #expect(merged?.viewerCount == 20)
    }
}
