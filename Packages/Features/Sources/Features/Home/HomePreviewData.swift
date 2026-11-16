#if DEBUG
import Foundation
import SwiftUI
import TwitchKit
import Core

/// Sample data for Home previews. `TwitchStream` / `TwitchUser` are
/// Decodable-only (no public memberwise init — they mirror Helix wire
/// payloads), so mocks are decoded from JSON literals shaped like the
/// already-camelCased models, not raw Helix responses.
enum HomePreviewData {

    static let streams: [TwitchStream] = decode(
        """
        [
          {
            "id": "1", "userId": "71092938", "userLogin": "xqc", "userName": "xQc",
            "gameId": "509658", "gameName": "Just Chatting", "type": "live",
            "title": "LIVE 🔴 CLICK HERE 🔴 GAMBA 🔴 REACT 🔴 VIDEOS 🔴",
            "tags": ["English", "Variety"], "viewerCount": 48213,
            "startedAt": "2026-06-12T14:02:11Z", "language": "en",
            "thumbnailUrl": "https://static-cdn.jtvnw.net/previews-ttv/live_user_xqc-{width}x{height}.jpg",
            "isMature": false
          },
          {
            "id": "2", "userId": "22484632", "userLogin": "forsen", "userName": "forsen",
            "gameId": "32982", "gameName": "Grand Theft Auto V", "type": "live",
            "title": "speedrun monday",
            "tags": ["English"], "viewerCount": 12440,
            "startedAt": "2026-06-12T15:30:00Z", "language": "en",
            "thumbnailUrl": "https://static-cdn.jtvnw.net/previews-ttv/live_user_forsen-{width}x{height}.jpg",
            "isMature": false
          },
          {
            "id": "3", "userId": "23161357", "userLogin": "lirik", "userName": "LIRIK",
            "gameId": "263490", "gameName": "Rust", "type": "live",
            "title": "big day big plays | !schedule",
            "tags": ["English", "Variety"], "viewerCount": 9106,
            "startedAt": "2026-06-12T16:00:00Z", "language": "en",
            "thumbnailUrl": "https://static-cdn.jtvnw.net/previews-ttv/live_user_lirik-{width}x{height}.jpg",
            "isMature": false
          },
          {
            "id": "4", "userId": "121059319", "userLogin": "moonmoon", "userName": "MOONMOON",
            "gameId": "490100", "gameName": "Lost Ark", "type": "live",
            "title": "gaming time",
            "tags": ["English"], "viewerCount": 7311,
            "startedAt": "2026-06-12T13:00:00Z", "language": "en",
            "thumbnailUrl": "https://static-cdn.jtvnw.net/previews-ttv/live_user_moonmoon-{width}x{height}.jpg",
            "isMature": true
          }
        ]
        """
    )

    static let openTabs: [ChatTab] = [
        ChatTab(channel: ChannelDescriptor(
            channelId: "71092938", channelLoginName: "xqc",
            channelDisplayName: "xQc", profileImageURL: nil
        )),
        ChatTab(channel: ChannelDescriptor(
            channelId: "22484632", channelLoginName: "forsen",
            channelDisplayName: "forsen", profileImageURL: nil
        )),
    ]

    private static func decode<T: Decodable>(_ json: String) -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(T.self, from: Data(json.utf8))
        } catch {
            fatalError("HomePreviewData JSON is malformed: \(error)")
        }
    }
}

// MARK: - Previews

#Preview("Home — busy") {
    NavigationStack {
        HomeContent(
            liveStreams: HomePreviewData.streams,
            profileImageURLs: [:],
            liveLoadState: .loaded,
            openTabs: HomePreviewData.openTabs,
            onStreamTap: { _ in },
            onResumeChat: { _ in }
        )
        .navigationTitle("Home")
        .toolbarTitleDisplayMode(.inlineLarge)
    }
}

#Preview("Home — nobody live") {
    NavigationStack {
        HomeContent(
            liveStreams: [],
            profileImageURLs: [:],
            liveLoadState: .loaded,
            openTabs: [],
            onStreamTap: { _ in },
            onResumeChat: { _ in }
        )
        .navigationTitle("Home")
        .toolbarTitleDisplayMode(.inlineLarge)
    }
}

#Preview("Home — loading") {
    NavigationStack {
        HomeContent(
            liveStreams: [],
            profileImageURLs: [:],
            liveLoadState: .loading,
            openTabs: HomePreviewData.openTabs,
            onStreamTap: { _ in },
            onResumeChat: { _ in }
        )
        .navigationTitle("Home")
        .toolbarTitleDisplayMode(.inlineLarge)
    }
}
#endif
