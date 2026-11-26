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

    /// Monotonically bumped whenever `globalEmotes` changes, giving the emote
    /// picker an O(1) cache key instead of element-by-element dictionary checks.
    public private(set) var emoteVersion: Int = 0

    /// True once BOTH globals are current — fetched from the network, or
    /// restored fresh from disk. Subsequent triggers from `.task(id:)` no-op so
    /// we don't refetch on every account swap. A failed (or half-failed) load
    /// leaves it false, so the next trigger retries instead of the catalog
    /// staying empty for the rest of the process.
    public private(set) var hasLoaded: Bool = false

    /// Network attempts per `load` before giving up until the next trigger,
    /// and the base backoff between them (doubled each retry).
    private static let maxAttempts = 3
    private static let retryBaseDelay: Duration = .seconds(2)

    /// Disk cache for the single global metadata blob.
    private let cache: JSONDiskCache

    private static let cacheKey = "global"
    private static let cacheTTL: TimeInterval = 24 * 60 * 60

    /// Coalesces overlapping `load(...)` callers (e.g. rapid account changes)
    /// so duplicate disk reads, Helix requests, and disk writes never overlap.
    @ObservationIgnored private var inFlightLoad: Task<Void, Never>?

    public init(cache: JSONDiskCache = JSONDiskCache(subdirectory: CacheSubdirectory.emoteGlobals)) {
        self.cache = cache
    }

    /// Fetches global badges + global emotes and caches them.
    /// Errors are logged but non-fatal — the per-channel ChatBadgeStore will
    /// fall back to its own fetch if the catalog stays empty.
    ///
    /// Idempotent via `hasLoaded` — safe to call from `.task(id:)` which
    /// re-fires on account changes.
    public func load(account: Account, accountStore: AccountStore) async {
        guard !hasLoaded else { return }
        if let existing = inFlightLoad {
            await existing.value
            return
        }
        let task = Task { @MainActor in
            await self.performLoad(account: account, accountStore: accountStore)
        }
        inFlightLoad = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if inFlightLoad == task { inFlightLoad = nil }
    }

    private func performLoad(account: Account, accountStore: AccountStore) async {
        defer { inFlightLoad = nil }
        guard !hasLoaded else { return }

        // Disk: render instantly if present. If fresh, skip the network.
        if let hit = await cache.load(
            key: Self.cacheKey, as: GlobalsCachePayload.self,
            version: GlobalsCachePayload.cacheVersion, ttl: Self.cacheTTL
        ) {
            globalBadges = hit.payload.badgeDictionary
            if globalEmotes != hit.payload.emotes {
                globalEmotes = hit.payload.emotes
                emoteVersion &+= 1
            }
            if hit.isFresh {
                hasLoaded = true
                logger.info("GlobalCatalog restored fresh from disk: \(self.globalBadges.count) badges, \(self.globalEmotes.count) emotes")
                return
            }
        }

        let client = accountStore.client(for: account)

        // Sequential is fine — Account is non-Sendable so async let trips
        // Swift 6's sending check, and the total cost is sub-second on a
        // background load that doesn't block first paint. `nil` = that fetch
        // FAILED (distinct from a successful empty result); only failed
        // halves are retried, with a short backoff.
        var badges: [ChatBadgeKey: ChatBadgeEntry]?
        var emotes: [String: TwitchEmote]?
        for attempt in 0..<Self.maxAttempts {
            if attempt > 0 {
                try? await Task.sleep(for: Self.retryBaseDelay * (1 << (attempt - 1)))
                if Task.isCancelled { break }
            }
            if badges == nil && emotes == nil {
                // Both halves needed (first launch, or a stale disk entry):
                // run the two Helix requests concurrently, saving a full
                // round trip before the first chat has global badges and
                // emotes. Main-actor tasks rather than `async let`, which
                // trips the sending check on the non-Sendable `Account`.
                let badgeFetch = Task { await self.fetchBadges(client: client, accountStore: accountStore, account: account) }
                let emoteFetch = Task { await self.fetchEmotes(client: client, accountStore: accountStore, account: account) }
                (badges, emotes) = await withTaskCancellationHandler {
                    (await badgeFetch.value, await emoteFetch.value)
                } onCancel: {
                    badgeFetch.cancel()
                    emoteFetch.cancel()
                }
            } else {
                if badges == nil {
                    badges = await fetchBadges(client: client, accountStore: accountStore, account: account)
                }
                if emotes == nil {
                    emotes = await fetchEmotes(client: client, accountStore: accountStore, account: account)
                }
            }
            if badges != nil, emotes != nil { break }
        }

        // Both fetches failed (network down / unauthorized). Keep whatever we
        // restored from disk rather than overwriting memory + cache with
        // empties, and leave `hasLoaded` false so the next trigger retries.
        guard badges != nil || emotes != nil else {
            logger.info("GlobalCatalog fetch failed; keeping existing globals and retrying on the next load")
            return
        }

        // Badges and emotes are independent fetches: one can succeed while the
        // other fails. Carry forward the existing value (disk-restored or
        // previously-loaded) for the failed half so a partial failure never
        // clobbers good data — in memory or on disk — and only call the
        // catalog loaded once both halves are current.
        let mergedBadges = badges ?? globalBadges
        let mergedEmotes = emotes ?? globalEmotes

        globalBadges = mergedBadges
        if globalEmotes != mergedEmotes {
            globalEmotes = mergedEmotes
            emoteVersion &+= 1
        }
        hasLoaded = badges != nil && emotes != nil

        // Persist only a complete result. The disk entry has ONE freshness
        // stamp for both halves, so saving after a partial failure would let
        // the next launch (within the TTL) restore the stale half as fresh
        // and skip refetching it.
        guard hasLoaded else {
            logger.warning("GlobalCatalog partial load (badges ok: \(badges != nil), emotes ok: \(emotes != nil)); not caching, will retry on the next load")
            return
        }
        await cache.save(
            key: Self.cacheKey,
            value: GlobalsCachePayload(badges: mergedBadges, emotes: mergedEmotes),
            version: GlobalsCachePayload.cacheVersion)

        logger.info("GlobalCatalog loaded: \(mergedBadges.count) badges, \(mergedEmotes.count) emotes")
    }

    // MARK: - Private fetch helpers

    private func fetchBadges(
        client: TwitchClient,
        accountStore: AccountStore,
        account: Account
    ) async -> [ChatBadgeKey: ChatBadgeEntry]? {
        do {
            let sets = try await accountStore.withTokenRefresh(for: account) {
                try await client.api.fetchGlobalBadges()
            }
            return ChatBadgeStore.flatten(sets: sets)
        } catch {
            logger.error("GlobalCatalog badge fetch failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func fetchEmotes(
        client: TwitchClient,
        accountStore: AccountStore,
        account: Account
    ) async -> [String: TwitchEmote]? {
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
            logger.error("GlobalCatalog emote fetch failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

// MARK: - Environment plumbing

public extension EnvironmentValues {
    /// App-wide global Twitch catalog. Injected by RootView once an Account
    /// becomes active. `nil` when read outside a RootView ancestor chain
    /// (e.g. SwiftUI previews) — callers should treat absence as "no cached
    /// data, fetch yourself if needed."
    ///
    /// Default is nil because `GlobalCatalog()` is `@MainActor`-isolated (the
    /// class is) and the entry's default value is evaluated in a nonisolated
    /// context. Constructing a `@MainActor` instance there trips Swift 6's
    /// actor-isolation check. The Optional shape is the idiomatic SwiftUI
    /// workaround:
    ///   - RootView always provides a real catalog via `.environment(\.globalCatalog, …)`.
    ///   - Previews / detached views read nil and fall back gracefully.
    @Entry var globalCatalog: GlobalCatalog? = nil
}
