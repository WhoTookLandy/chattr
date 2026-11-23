import Foundation
import Core
import os

private let logger = AppLogger.make("EmoteSources.GlobalCatalog")

/// Process-wide, request-coalescing cache of each third-party provider's
/// **global** emote set (7TV / BTTV / FFZ globals).
///
/// ## Why this exists
///
/// Global sets are identical for every channel and every account, yet each
/// `EmoteIndex` (one per account × channel) used to fetch all three of them
/// on its own load and persist them inside its per-channel disk file. Ten
/// open tabs meant thirty identical global fetches and ten copies of the
/// same few thousand emotes on disk. Every index now asks this catalog
/// instead; the per-channel cache holds channel emotes only and the two are
/// merged when the index publishes.
///
/// ## Semantics
///
/// - **Coalescing**: concurrent `globals(for:)` calls for the same provider
///   share one in-flight `Task` — N indexes opening at once cost one fetch.
/// - **Memory + disk**: a successful fetch is kept in memory and written to
///   disk (one file per provider) so a cold launch renders globals without
///   network. Entries carry their own `fetchedAt`, so freshness survives
///   the disk round-trip.
/// - **Failures are never cached**: a thrown fetch leaves the previous entry
///   (if any) in place and the next call retries. Callers that want to
///   render something anyway read the stale value via `cachedGlobals(for:)`.
///
/// Keyed by `EmoteProvider.globalCatalogKey` (the provider's concrete type
/// by default).
public actor GlobalEmoteCatalog {

    /// Shared instance used by every production `EmoteIndex`.
    public static let shared = GlobalEmoteCatalog()

    private struct Entry: Sendable {
        let emotes: [Emote]
        let fetchedAt: Date
    }

    private var entries: [String: Entry] = [:]
    private var inFlight: [String: Task<[Emote], any Error>] = [:]

    /// `nil` = memory only (tests).
    private let cache: JSONDiskCache?
    private let ttl: TimeInterval

    public init(
        cache: JSONDiskCache? = JSONDiskCache(subdirectory: CacheSubdirectory.emoteGlobals),
        ttl: TimeInterval = 24 * 60 * 60
    ) {
        self.cache = cache
        self.ttl = ttl
    }

    /// Whatever this catalog already holds for `provider` — memory first,
    /// then disk — regardless of freshness. Never touches the network.
    /// Used for instant render and as the stale fallback when a refresh
    /// fails. `nil` when nothing was ever cached.
    public func cachedGlobals(for provider: any EmoteProvider) async -> [Emote]? {
        let key = provider.globalCatalogKey
        if let entry = entries[key] { return entry.emotes }
        guard let restored = await restoreFromDisk(key: key) else { return nil }
        // Re-check after the suspension: a concurrent fetch may have landed
        // a newer entry while we were reading the file.
        if let entry = entries[key] { return entry.emotes }
        entries[key] = restored
        return restored.emotes
    }

    /// Fresh global emotes for `provider`: the cached set when it's inside
    /// the TTL, otherwise one coalesced fetch shared by every concurrent
    /// caller. Throws the provider's error on failure (nothing is cached).
    public func globals(for provider: any EmoteProvider) async throws -> [Emote] {
        let key = provider.globalCatalogKey
        if let entry = entries[key], isFresh(entry) { return entry.emotes }
        if let task = inFlight[key] { return try await task.value }

        // Registered before the first suspension, so a reentrant caller for
        // the same key always finds it. The task body hops back onto this
        // actor for the disk read, then fetches off-actor.
        let task = Task<[Emote], any Error> {
            try await self.resolve(provider: provider, key: key)
        }
        inFlight[key] = task
        return try await task.value
    }

    // MARK: - Private

    private func isFresh(_ entry: Entry) -> Bool {
        Date().timeIntervalSince(entry.fetchedAt) < ttl
    }

    /// Disk (if fresh) → network. Runs inside the coalesced task.
    private func resolve(provider: any EmoteProvider, key: String) async throws -> [Emote] {
        // Clear `inFlight[key]` atomically on the actor as `resolve` exits so
        // no concurrent waiter resuming before the initiating caller can
        // observe and replay an already-failed task.
        defer { inFlight[key] = nil }
        if entries[key] == nil, let restored = await restoreFromDisk(key: key) {
            entries[key] = restored
        }
        if let entry = entries[key], isFresh(entry) { return entry.emotes }

        let emotes = try await provider.globalEmotes()
        let entry = Entry(emotes: emotes, fetchedAt: Date())
        entries[key] = entry
        logger.info("Fetched \(emotes.count) global emote(s) for \(key, privacy: .public)")
        await cache?.save(
            key: Self.diskKey(key),
            value: GlobalEmoteCachePayload(providerKey: key, fetchedAt: entry.fetchedAt, emotes: emotes),
            version: GlobalEmoteCachePayload.cacheVersion)
        return emotes
    }

    private func restoreFromDisk(key: String) async -> Entry? {
        guard let cache,
              let hit = await cache.load(
                key: Self.diskKey(key), as: GlobalEmoteCachePayload.self,
                version: GlobalEmoteCachePayload.cacheVersion,
                // Freshness is judged from the payload's own `fetchedAt`;
                // the file-age TTL is irrelevant here.
                ttl: .greatestFiniteMagnitude),
              hit.payload.providerKey == key
        else { return nil }
        return Entry(emotes: hit.payload.emotes, fetchedAt: hit.payload.fetchedAt)
    }

    /// File-name-safe disk key. Provider keys are type names
    /// ("EmoteSources.SevenTVProvider"), so this is effectively identity.
    static func diskKey(_ providerKey: String) -> String {
        let safe = providerKey.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return "thirdparty-globals-" + String(safe)
    }
}

/// On-disk representation of one provider's global emote set.
struct GlobalEmoteCachePayload: Codable, Sendable {
    static let cacheVersion = 1

    /// Validated against the requested key on load.
    let providerKey: String
    /// When the set was fetched — drives freshness across launches.
    let fetchedAt: Date
    let emotes: [Emote]
}
