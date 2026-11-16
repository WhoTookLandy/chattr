import Foundation
import Core
import os

private let logger = AppLogger.make("EmoteSources.Index")

/// Per-channel emote resolver. Owns the merged result of:
///   - 7TV global + channel
///   - BTTV global + channel
///   - FFZ global + channel
///
/// ## Resolution semantics
///
/// On name collision (same `name` from multiple providers/scopes), the
/// precedence is:
///
///   1. **Channel emotes > global emotes** — broadcasters configure
///      channel-specific emotes intentionally, so they should always
///      win against a global of the same name.
///   2. **Within the same scope**: 7TV > BTTV > FFZ. This matches
///      community convention (7TV has the deepest catalog and is most
///      likely to be the user's expected source for a given name).
///
/// ## Where the data comes from
///
/// - **Globals** come from the shared `GlobalEmoteCatalog`, which fetches
///   each provider's global set once per process (coalescing concurrent
///   requests) instead of once per channel per account.
/// - **Channel emotes** are fetched per channel and persisted per
///   broadcaster (`ChannelEmoteCachePayload`, channel-only).
/// - The two are merged at publish time (`compose`), so precedence is
///   applied in exactly one place.
///
/// ## Isolation
///
/// `actor` — the merged map is mutated during async refresh and must be
/// protected from concurrent writes. Reads happen on the hot chat
/// message path (every incoming message tokenizes against the index),
/// so a lock-protected mirror backs the nonisolated `snapshot()` for
/// cross-actor access without an `await` on every lookup.
///
/// ## Per-provider failure handling
///
/// Global and channel fetches for every provider run in one task group.
/// Per-provider failures are logged and tolerated — 7TV could be down and
/// we still render BTTV+FFZ emotes. But a partial result is NOT treated as
/// loaded: the index stays retryable (the next `load` call tries again)
/// and a partial channel set is never persisted, so one transient 5xx can't
/// pin a channel to an incomplete emote set for the 24h cache TTL.
public actor EmoteIndex {

    /// Resolved emotes keyed by `name`. Exact-case match — Twitch native
    /// emotes are case-sensitive ("Kappa" ≠ "kappa") and all three
    /// providers follow the same convention.
    private var byName: [String: Emote] = [:]

    /// Idempotency key: the `broadcasterId` we most recently loaded for
    /// *completely* (every provider succeeded). If `load(...)` is called
    /// again with the same id, it's a no-op. This is what makes the index
    /// registry-friendly — multiple view mounts of the same channel call
    /// `load(...)` but the network work happens once.
    private var loadedBroadcasterId: String?

    /// The load currently running, if any. Concurrent callers for the same
    /// broadcaster await this task instead of returning early, so every
    /// `load` caller observes the published snapshot when it returns.
    private struct InFlightLoad {
        let broadcasterId: String
        let token: UInt64
        let task: Task<Void, Never>
    }
    private var inFlightLoad: InFlightLoad?
    private var nextLoadToken: UInt64 = 0

    private let providers: [any EmoteProvider]

    /// Shared source of global emotes.
    private let globalCatalog: GlobalEmoteCatalog

    /// Disk cache for this channel's channel-only emote set. Keyed by
    /// broadcasterId.
    private let cache: JSONDiskCache

    /// Cross-launch freshness window for the channel set. In-session
    /// refetch is already prevented by `loadedBroadcasterId`; this TTL
    /// governs only disk-restored data.
    private static let cacheTTL: TimeInterval = 24 * 60 * 60

    /// What nonisolated readers see: the merged map plus the generation it
    /// was published under, swapped together so they can never disagree.
    private struct Published: Sendable {
        var byName: [String: Emote]
        var generation: Int
    }

    /// Lock-protected mirror of `byName` for nonisolated reads. Renderer
    /// code reads this on the hot path and shouldn't have to cross the
    /// actor boundary for each emote lookup.
    ///
    /// Why `OSAllocatedUnfairLock` (not `nonisolated(unsafe)`): Swift 6
    /// strict-concurrency rejects `nonisolated(unsafe)` mutable
    /// dictionaries even though dictionary copy-on-write makes the read
    /// safe in practice. The lock costs us a single atomic op per
    /// lookup but keeps the compiler happy and the semantics
    /// provably-correct.
    private let publishedLock = OSAllocatedUnfairLock<Published>(
        initialState: Published(byName: [:], generation: 0))

    /// Process-wide generation source. Generations are unique across ALL
    /// indexes (not just per instance), so a consumer that outlives one
    /// index and later sees a rebuilt one for the same channel can never
    /// mistake the new table for the old one.
    private static let generationSource = OSAllocatedUnfairLock<Int>(initialState: 0)

    /// Snapshot accessor for consumers (e.g., `Normalizer`).
    /// Read-only by design — only `EmoteIndex.load(...)` writes back.
    public nonisolated func snapshot() -> [String: Emote] {
        publishedLock.withLock { $0.byName }
    }

    /// Monotonically increasing version of the published table: 0 before
    /// anything is published, bumped on every publish. Unlike the entry
    /// count, it changes whenever the table does — two tables of equal
    /// size still get different generations.
    public nonisolated var generation: Int {
        publishedLock.withLock { $0.generation }
    }

    /// The snapshot and its generation read atomically — use this when the
    /// generation stamps something derived from the snapshot (e.g. a
    /// normalization cache), so the stamp can't belong to a newer table.
    public nonisolated func snapshotWithGeneration() -> (emotes: [String: Emote], generation: Int) {
        publishedLock.withLock { (emotes: $0.byName, generation: $0.generation) }
    }

    /// Default initializer: stands up all three providers and uses the
    /// process-wide `GlobalEmoteCatalog.shared`.
    public init(
        globalCatalog: GlobalEmoteCatalog = .shared,
        cache: JSONDiskCache = JSONDiskCache(subdirectory: CacheSubdirectory.emoteChannels)
    ) {
        self.providers = [SevenTVProvider(), BTTVProvider(), FFZProvider()]
        self.globalCatalog = globalCatalog
        self.cache = cache
    }

    /// Inject-providers initializer. Production passes
    /// `GlobalEmoteCatalog.shared`; the default is a fresh memory-only
    /// catalog so tests stay isolated from each other and from disk.
    public init(
        providers: [any EmoteProvider],
        globalCatalog: GlobalEmoteCatalog = GlobalEmoteCatalog(cache: nil),
        cache: JSONDiskCache = JSONDiskCache(subdirectory: CacheSubdirectory.emoteChannels)
    ) {
        self.providers = providers
        self.globalCatalog = globalCatalog
        self.cache = cache
    }

    /// Loads global + per-channel emotes for the given (id, login) pair.
    ///
    /// **Idempotent**: calling with the same `broadcasterId` we already
    /// fully loaded for is a no-op. Concurrent calls for the same
    /// broadcaster share one load and all return after it has finished
    /// (and published, if it produced anything).
    ///
    /// The load runs in a task owned by the index, so a caller's
    /// cancellation (e.g. a `.task` torn down by a tab swipe) neither
    /// cancels the shared work nor leaves a half-published table — the
    /// registry-owned index finishes loading for the next mount.
    public func load(broadcasterId: String, broadcasterLogin: String) async {
        if loadedBroadcasterId == broadcasterId {
            // Already loaded for this channel — re-mounts get the existing
            // snapshot for free.
            return
        }
        if let inFlight = inFlightLoad, inFlight.broadcasterId == broadcasterId {
            await inFlight.task.value
            return
        }

        nextLoadToken &+= 1
        let token = nextLoadToken
        // `performLoad` is isolated to this actor, so it can't start before
        // `inFlightLoad` is assigned below (we hold the actor until the
        // `await`).
        let task = Task {
            await self.performLoad(
                broadcasterId: broadcasterId, broadcasterLogin: broadcasterLogin, token: token)
        }
        inFlightLoad = InFlightLoad(broadcasterId: broadcasterId, token: token, task: task)
        await task.value
    }

    /// O(1) lookup. Returns nil if the name isn't a known emote.
    /// Prefer the nonisolated `snapshot()` for high-frequency renderer
    /// lookups (avoids actor-hop cost per message token).
    public func resolve(name: String) -> Emote? {
        byName[name]
    }

    // MARK: - Private

    /// One provider's contribution to a load. `succeeded == false` means
    /// the fetch threw; `emotes` is then the stale fallback (globals) or
    /// empty (channel).
    private enum FetchOutcome: Sendable {
        case global(providerIndex: Int, emotes: [Emote], succeeded: Bool)
        case channel(providerIndex: Int, emotes: [Emote], succeeded: Bool)
    }

    private func performLoad(broadcasterId: String, broadcasterLogin: String, token: UInt64) async {
        // Clear the in-flight marker on every exit path — but only if it's
        // still ours (a load for a different broadcaster may have replaced
        // it). Runs on the actor as the task completes, so a caller arriving
        // afterwards starts a fresh load (retry) rather than re-awaiting a
        // finished partial one.
        defer {
            if inFlightLoad?.token == token { inFlightLoad = nil }
        }

        // 1. Disk: the channel-only set for this broadcaster, if any.
        var diskChannel: [String: Emote]?
        var diskChannelIsFresh = false
        if let hit = await cache.load(
            key: broadcasterId, as: ChannelEmoteCachePayload.self,
            version: ChannelEmoteCachePayload.cacheVersion, ttl: Self.cacheTTL
        ), hit.payload.broadcasterId == broadcasterId {
            diskChannel = hit.payload.byName
            diskChannelIsFresh = hit.isFresh
        }
        let diskChannelSets: [[Emote]] = diskChannel.map { [Array($0.values)] } ?? []

        // 2. Instant render: whatever globals the catalog already holds
        //    (memory/disk, any freshness) + the disk channel set. Only when
        //    nothing is showing yet — never regress a fuller table from an
        //    earlier (partial) load to older cached data.
        if byName.isEmpty {
            var cachedGlobals: [[Emote]] = []
            for provider in providers {
                if let globals = await globalCatalog.cachedGlobals(for: provider) {
                    cachedGlobals.append(globals)
                }
            }
            let restored = Self.compose(globals: cachedGlobals, channel: diskChannelSets)
            if !restored.isEmpty && byName.isEmpty {
                publish(restored)
                logger.info("EmoteIndex restored \(restored.count) cached emote(s) for \(broadcasterLogin, privacy: .public)")
            }
        }

        // 3. Network: globals via the shared catalog (usually a memory hit),
        //    channel sets per provider unless the disk copy is still fresh.
        let fetchChannel = !diskChannelIsFresh
        let fetchProviders = self.providers
        let catalog = self.globalCatalog
        var globalsByProvider = [[Emote]](repeating: [], count: fetchProviders.count)
        var channelByProvider = [[Emote]](repeating: [], count: fetchProviders.count)
        var allGlobalsSucceeded = true
        var allChannelsSucceeded = true

        await withTaskGroup(of: FetchOutcome.self) { group in
            for (index, provider) in fetchProviders.enumerated() {
                let providerName = String(describing: type(of: provider))
                group.addTask {
                    do {
                        let emotes = try await catalog.globals(for: provider)
                        return .global(providerIndex: index, emotes: emotes, succeeded: true)
                    } catch {
                        logger.error("Global emotes failed for \(providerName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        // Keep rendering the last good set while we retry later.
                        let stale = await catalog.cachedGlobals(for: provider) ?? []
                        return .global(providerIndex: index, emotes: stale, succeeded: false)
                    }
                }
                guard fetchChannel else { continue }
                group.addTask {
                    do {
                        let emotes = try await provider.channelEmotes(
                            broadcasterId: broadcasterId, broadcasterLogin: broadcasterLogin)
                        return .channel(providerIndex: index, emotes: emotes, succeeded: true)
                    } catch {
                        logger.error("Channel emotes failed for \(providerName, privacy: .public) (\(broadcasterLogin, privacy: .public)): \(error.localizedDescription, privacy: .public)")
                        return .channel(providerIndex: index, emotes: [], succeeded: false)
                    }
                }
            }
            for await outcome in group {
                switch outcome {
                case let .global(index, emotes, succeeded):
                    globalsByProvider[index] = emotes
                    if !succeeded { allGlobalsSucceeded = false }
                case let .channel(index, emotes, succeeded):
                    channelByProvider[index] = emotes
                    if !succeeded { allChannelsSucceeded = false }
                }
            }
        }

        let channelSets = fetchChannel ? channelByProvider : diskChannelSets
        let finalSnapshot = Self.compose(globals: globalsByProvider, channel: channelSets)

        // All providers failed or returned nothing. Don't clobber a
        // disk-restored snapshot (or a prior load) with emptiness, and don't
        // mark loaded — let the next mount retry.
        guard !finalSnapshot.isEmpty else {
            logger.info("EmoteIndex produced no emotes for \(broadcasterLogin, privacy: .public); keeping existing snapshot")
            return
        }
        publish(finalSnapshot)

        if allGlobalsSucceeded && allChannelsSucceeded {
            // Mark loaded before the async cache write so a re-entrant
            // `load()` arriving during the save suspension short-circuits.
            loadedBroadcasterId = broadcasterId
        } else {
            logger.warning("EmoteIndex partial load for \(broadcasterLogin, privacy: .public) (globals ok: \(allGlobalsSucceeded), channel ok: \(allChannelsSucceeded)); will retry on next load")
        }

        // Persist the channel set only when it came from the network and
        // every provider answered — a partial set must not be served as
        // fresh for 24h. (Global failures don't affect the channel-only file.)
        if fetchChannel && allChannelsSucceeded {
            await cache.save(
                key: broadcasterId,
                value: ChannelEmoteCachePayload(
                    broadcasterId: broadcasterId,
                    byName: Self.compose(globals: [], channel: channelByProvider)),
                version: ChannelEmoteCachePayload.cacheVersion)
        }
        logger.info("EmoteIndex loaded for \(broadcasterLogin, privacy: .public): \(finalSnapshot.count) emote(s)")
    }

    /// Atomically publish a resolved snapshot: actor-isolated `byName` plus
    /// the lock-protected mirror (with a new generation) used by
    /// nonisolated readers.
    private func publish(_ snapshot: [String: Emote]) {
        self.byName = snapshot
        let generation = Self.generationSource.withLock { (value: inout Int) -> Int in
            value += 1
            return value
        }
        publishedLock.withLock { $0 = Published(byName: snapshot, generation: generation) }
    }

    /// Merge global and channel sets into one table. Order-independent:
    /// precedence is data-driven (scope from the list a set came from,
    /// source rank from `priority(of:)`), identical to the pre-catalog
    /// single-pass merge.
    static func compose(globals: [[Emote]], channel: [[Emote]]) -> [String: Emote] {
        var merged: [String: Emote] = [:]
        for set in globals {
            for emote in set { merge(into: &merged, emote: emote, isChannelLevel: false) }
        }
        for set in channel {
            for emote in set { merge(into: &merged, emote: emote, isChannelLevel: true) }
        }
        return merged
    }

    /// Merge with precedence: channel > global; 7TV > BTTV > FFZ.
    private static func merge(
        into map: inout [String: Emote],
        emote: Emote,
        isChannelLevel: Bool
    ) {
        if let existing = map[emote.name] {
            let existingIsChannel = existing.ownerChannelId != nil

            // Scope precedence wins first.
            if !existingIsChannel && isChannelLevel {
                map[emote.name] = emote
                return
            }
            if existingIsChannel && !isChannelLevel {
                return  // Keep existing — channel beats global.
            }

            // Same scope — apply source precedence (7TV > BTTV > FFZ).
            if priority(of: emote.source) < priority(of: existing.source) {
                map[emote.name] = emote
            }
        } else {
            map[emote.name] = emote
        }
    }

    private static func priority(of source: Emote.Source) -> Int {
        switch source {
        case .sevenTV: return 0
        case .bttv:    return 1
        case .ffz:     return 2
        }
    }
}
