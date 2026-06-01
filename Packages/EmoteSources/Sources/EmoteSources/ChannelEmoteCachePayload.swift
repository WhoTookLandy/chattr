import Foundation

/// On-disk representation of a channel's merged third-party emote set.
///
/// We persist the *post-merge* snapshot (`EmoteIndex.byName`) directly, so a
/// disk restore needs no re-merge — `Emote` already carries `source` and
/// `ownerChannelId` if a future re-merge ever wants them.
struct ChannelEmoteCachePayload: Codable, Sendable {
    /// Envelope version — bump when `Emote`'s shape changes incompatibly.
    static let cacheVersion = 1

    /// The broadcaster this snapshot belongs to; validated against the cache
    /// filename on load to guard against a mismatched/renamed file.
    let broadcasterId: String

    /// Resolved emotes keyed by display name (the merged `EmoteIndex` map).
    let byName: [String: Emote]
}
