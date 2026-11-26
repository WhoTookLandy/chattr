import Foundation

/// On-disk representation of a channel's **channel-only** third-party emote
/// set (7TV/BTTV/FFZ channel emotes, already merged among themselves).
///
/// Global emotes are deliberately NOT stored here — they live once in
/// `GlobalEmoteCatalog` and are merged in when `EmoteIndex` publishes, so
/// N channels no longer persist N copies of the same global sets.
struct ChannelEmoteCachePayload: Codable, Sendable {
    /// Envelope version — bump when `Emote`'s shape changes incompatibly,
    /// or when a new field should be backfilled promptly. v2 added
    /// `aspectRatio`; v3 switched the payload from the merged
    /// global+channel table to channel-only (v2 files would otherwise
    /// resurrect stale globals as if they were channel emotes); v4 backfills
    /// 7TV's `static_name` still URLs (`Emote.staticURLs`) so the picker
    /// avoids downloading full animated WebPs.
    static let cacheVersion = 4

    /// The broadcaster this snapshot belongs to; validated against the cache
    /// filename on load to guard against a mismatched/renamed file.
    let broadcasterId: String

    /// Channel emotes keyed by display name (channel-scope precedence
    /// already applied: 7TV > BTTV > FFZ).
    let byName: [String: Emote]

    /// Which providers answered to build `byName` (see
    /// `EmoteIndex.sourceSignature(of:)`). A file written for a different
    /// set can't stand in for a fetch: a provider enabled since then is
    /// missing from it. Optional so files from before the field existed
    /// still decode; they read as "set unknown" and are refetched.
    let sources: [String]?

    /// When the set was fetched — the age `EmoteIndex` revalidates on.
    /// Optional for the same reason as `sources`.
    let fetchedAt: Date?

    init(broadcasterId: String, byName: [String: Emote], sources: [String]? = nil, fetchedAt: Date? = nil) {
        self.broadcasterId = broadcasterId
        self.byName = byName
        self.sources = sources
        self.fetchedAt = fetchedAt
    }
}
