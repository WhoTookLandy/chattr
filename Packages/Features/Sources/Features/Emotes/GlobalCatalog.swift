import Foundation
import SwiftUI
import Accounts
import Channels
import TwitchKit
import Core
import os

private let logger = AppLogger.make("Features.GlobalCatalog")

/// App-wide cache of Twitch's *global* chat data: global badges (moderator,
/// VIP, prime, turbo, etc.) and global emotes (Kappa, LUL, PogChamp, etc.).
///
/// "Global" means: identical across channels, identical across accounts.
/// Re-fetching this data per-channel is wasted bandwidth. We load it once on
/// first sign-in via RootView's `.task(id:)` and keep it in memory for the
/// rest of the session.
///
/// - Per-channel data (subscriber tiers, channel emotes, founder badges)
///   still loads per-channel — `ChatBadgeStore` merges channel data on top
///   of this catalog's global slice.
/// - We don't persist across launches. Disk caching can come later; the
///   network cost is one cold-launch fetch of ~10KB total.
@MainActor
@Observable
public final class GlobalCatalog {

    /// Global chat badges keyed by (setId, id). Empty until `load` completes.
    public private(set) var globalBadges: [ChatBadgeKey: ChatBadgeEntry] = [:]

    /// Global emotes (Kappa, LUL, PogChamp, etc.) keyed by emote ID. Currently
    /// unused for inline chat rendering — chat fragments come pre-resolved with
    /// emote IDs and we hit the CDN directly. Cached now for the future emote
    /// picker / name-to-ID resolution when sending messages.
    public private(set) var globalEmotes: [String: TwitchEmote] = [:]

    /// True once a load attempt has *completed* (success or failure). Subsequent
    /// triggers from `.task(id:)` no-op so we don't refetch on every account swap.
    public private(set) var hasLoaded: Bool = false

    /// Disk cache for the single global metadata blob.
    private let cache: JSONDiskCache

    private static let cacheKey = "global"
    private static let cacheTTL: TimeInterval = 24 * 60 * 60

    public init(cache: JSONDiskCache = JSONDiskCache(subdirectory: CacheSubdirectory.emoteGlobals)) {
        self.cache = cache
    }

    /// Fetches global badges + global emotes sequentially and caches them.
    /// Errors are logged but non-fatal — the per-channel ChatBadgeStore will
    /// fall back to its own fetch if the catalog stays empty.
    ///
    /// Idempotent via `hasLoaded` — safe to call from `.task(id:)` which
    /// re-fires on account changes.
    public func load(account: Account, accountStore: AccountStore) async {
        guard !hasLoaded else { return }

        // Disk: render instantly if present. If fresh, skip the network.
        if let hit = await cache.load(
            key: Self.cacheKey, as: GlobalsCachePayload.self,
            version: GlobalsCachePayload.cacheVersion, ttl: Self.cacheTTL
        ) {
            globalBadges = hit.payload.badgeDictionary
            globalEmotes = hit.payload.emotes
            if hit.isFresh {
                hasLoaded = true
                logger.info("GlobalCatalog restored fresh from disk: \(self.globalBadges.count) badges, \(self.globalEmotes.count) emotes")
                return
            }
        }

        let client = accountStore.client(for: account)

        // Sequential is fine — Account is non-Sendable so async let trips
        // Swift 6's sending check, and the total cost is sub-second on a
        // background load that doesn't block first paint.
        let badges = await fetchBadges(client: client, accountStore: accountStore, account: account)
        let emotes = await fetchEmotes(client: client, accountStore: accountStore, account: account)

        // Both fetches failed (network down / unauthorized). Keep whatever we
        // restored from disk rather than overwriting memory + cache with empties.
        guard !badges.isEmpty || !emotes.isEmpty else {
            hasLoaded = true
            logger.info("GlobalCatalog fetch returned nothing; keeping disk/empty state")
            return
        }

        globalBadges = badges
        globalEmotes = emotes
        hasLoaded = true

        await cache.save(
            key: Self.cacheKey,
            value: GlobalsCachePayload(badges: badges, emotes: emotes),
            version: GlobalsCachePayload.cacheVersion)

        logger.info("GlobalCatalog loaded: \(badges.count) badges, \(emotes.count) emotes")
    }

    // MARK: - Private fetch helpers

    private func fetchBadges(
        client: TwitchClient,
        accountStore: AccountStore,
        account: Account
    ) async -> [ChatBadgeKey: ChatBadgeEntry] {
        do {
            let sets = try await accountStore.withTokenRefresh(for: account) {
                try await client.api.fetchGlobalBadges()
            }
            return ChatBadgeStore.flatten(sets: sets)
        } catch {
            logger.error("GlobalCatalog badge fetch failed: \(error.localizedDescription)")
            return [:]
        }
    }

    private func fetchEmotes(
        client: TwitchClient,
        accountStore: AccountStore,
        account: Account
    ) async -> [String: TwitchEmote] {
        do {
            let list = try await accountStore.withTokenRefresh(for: account) {
                try await client.api.fetchGlobalEmotes()
            }
            // Reduce to (id → emote) so future emote-picker lookups are O(1).
            // Use `reduce(into:)` (last-wins) rather than `Dictionary(uniqueKeysWithValues:)`
            // which traps on duplicate keys — Twitch shouldn't return duplicate emote
            // IDs but the trap is a runtime crash that we'd rather not eat on a
            // malformed-API regression.
            return list.reduce(into: [:]) { $0[$1.id] = $1 }
        } catch {
            logger.error("GlobalCatalog emote fetch failed: \(error.localizedDescription)")
            return [:]
        }
    }
}

// MARK: - Environment plumbing

/// Default is nil because `GlobalCatalog()` is `@MainActor`-isolated (the class
/// is) and `EnvironmentKey.defaultValue` is evaluated in a nonisolated context.
/// Constructing a `@MainActor` instance there trips Swift 6's actor-isolation
/// check. The Optional shape is the idiomatic SwiftUI workaround:
///   - RootView always provides a real catalog via `.environment(\.globalCatalog, …)`.
///   - Previews / detached views read nil and fall back gracefully.
private struct GlobalCatalogKey: EnvironmentKey {
    static let defaultValue: GlobalCatalog? = nil
}

public extension EnvironmentValues {
    /// App-wide global Twitch catalog. Injected by RootView once an Account
    /// becomes active. `nil` when read outside a RootView ancestor chain
    /// (e.g. SwiftUI previews) — callers should treat absence as "no cached
    /// data, fetch yourself if needed."
    var globalCatalog: GlobalCatalog? {
        get { self[GlobalCatalogKey.self] }
        set { self[GlobalCatalogKey.self] = newValue }
    }
}
