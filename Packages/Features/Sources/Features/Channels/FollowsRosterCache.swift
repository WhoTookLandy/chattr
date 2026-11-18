import Foundation
import Core

/// The follow roster on disk, one file per account.
///
/// The files sit beside the per-channel emote tables
/// (`CacheSubdirectory.emoteChannels`) under a key no broadcaster id can
/// collide with, so what already bounds that directory covers them: the
/// launch sweep drops a roster not rewritten for a week (an account no
/// longer in use), and Settings → Storage → Clear Cache removes them all.
///
/// Reads never fail: an absent, unreadable, outdated or too-old file is a
/// miss, and the caller loads from the network as if there were no cache.
struct FollowsRosterCache: Sendable {
    /// Bump when `FollowsRoster`'s coded shape changes incompatibly.
    static let version = 1

    /// A roster older than this is not shown: it is the lifetime the launch
    /// sweep gives the file anyway.
    static let maxAge: TimeInterval = 7 * 24 * 60 * 60

    /// The cache the app uses.
    static let shared = FollowsRosterCache()

    private let cache: JSONDiskCache

    init(cache: JSONDiskCache = JSONDiskCache(subdirectory: CacheSubdirectory.emoteChannels)) {
        self.cache = cache
    }

    static func key(forAccountUserId accountUserId: String) -> String {
        "follows-\(accountUserId)"
    }

    func load(forAccountUserId accountUserId: String) async -> FollowsRoster? {
        let hit = await cache.load(
            key: Self.key(forAccountUserId: accountUserId), as: FollowsRoster.self,
            version: Self.version, ttl: Self.maxAge
        )
        guard let hit, hit.isFresh else { return nil }
        return hit.payload
    }

    func save(_ roster: FollowsRoster, forAccountUserId accountUserId: String) async {
        await cache.save(
            key: Self.key(forAccountUserId: accountUserId), value: roster,
            version: Self.version
        )
    }
}
