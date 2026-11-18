import Foundation
import TwitchKit

/// What `FollowsStore` keeps on disk between launches: the full follow list
/// in Twitch's order, and the profile image of each channel in it. Enough to
/// draw the Following roster before the network has answered.
struct FollowsRoster: Sendable, Equatable {
    var channels: [FollowedChannel]
    /// broadcasterId → profile image URL.
    var profileImageURLs: [String: URL]
}

extension FollowsRoster: Codable {
    private enum CodingKeys: String, CodingKey {
        case channels
        case profileImageURLs
    }

    /// `FollowedChannel` is Decodable-only, so it is written through this
    /// mirror: the same keys its synthesized decoder reads.
    private struct ChannelRecord: Encodable {
        let broadcasterId: String
        let broadcasterLogin: String
        let broadcasterName: String
        let followedAt: Date
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        channels = try container.decode([FollowedChannel].self, forKey: .channels)
        profileImageURLs = try container.decode([String: URL].self, forKey: .profileImageURLs)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let records = channels.map {
            ChannelRecord(
                broadcasterId: $0.broadcasterId,
                broadcasterLogin: $0.broadcasterLogin,
                broadcasterName: $0.broadcasterName,
                followedAt: $0.followedAt
            )
        }
        try container.encode(records, forKey: .channels)
        try container.encode(profileImageURLs, forKey: .profileImageURLs)
    }
}
