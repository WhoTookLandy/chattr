import Foundation
import TwitchKit

/// Disk-storable form of a single global badge entry. `[ChatBadgeKey: ChatBadgeEntry]`
/// can't JSON-encode a struct key, so we flatten to an array and rebuild on load.
struct BadgeDTO: Codable, Sendable {
    let setId: String
    let id: String
    let url: URL
    let title: String?
}

/// On-disk representation of `GlobalCatalog`'s global badges + global emotes.
struct GlobalsCachePayload: Codable, Sendable {
    /// Envelope version — bump when the badge/emote shape changes incompatibly.
    static let cacheVersion = 1

    let badges: [BadgeDTO]
    let emotes: [String: TwitchEmote]

    /// Build from the in-memory shapes `GlobalCatalog` holds.
    init(badges: [ChatBadgeKey: ChatBadgeEntry], emotes: [String: TwitchEmote]) {
        self.badges = badges.map {
            BadgeDTO(setId: $0.key.setId, id: $0.key.id, url: $0.value.url, title: $0.value.title)
        }
        self.emotes = emotes
    }

    /// Rebuild the keyed dictionary `GlobalCatalog` renders from.
    var badgeDictionary: [ChatBadgeKey: ChatBadgeEntry] {
        var result: [ChatBadgeKey: ChatBadgeEntry] = [:]
        for dto in badges {
            result[ChatBadgeKey(setId: dto.setId, id: dto.id)] =
                ChatBadgeEntry(url: dto.url, title: dto.title)
        }
        return result
    }
}
