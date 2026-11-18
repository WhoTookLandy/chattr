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
///   broadcaster (`ChannelEmoteCachePayload`, channel-only), stamped with
///   the provider set that produced them.
/// - The two are merged at publish time (`compose`), so precedence is
///   applied in exactly one place.
///
/// ## Freshness
///
/// A loaded table keeps being served; once its channel data is older than
/// `revalidateAfter`, the next `load` refetches behind it and publishes the
/// result when it lands. `reload` forces that pass (rate-limited). Passes
/// that keep failing back off (`retryDelay(afterFailures:)`) rather than
/// hitting the providers on every mount.
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
/// Global and channel fetches for every provider run in one task group,
/// and the table is republished as each one lands (a provider still out
/// keeps its last good set meanwhile), so one slow provider doesn't hold
/// back the others' emotes.
/// Per-provider failures are logged and tolerated — 7TV could be down and
/// we still render BTTV+FFZ emotes. But a partial result is NOT treated as
/// loaded: the index stays retryable (a later `load` call tries again)
/// and a partial channel set is never persisted, so one transient 5xx can't
/// pin a channel to an incomplete emote set for the 24h cache TTL.
public actor EmoteIndex {

    /// Resolved emotes keyed by `name`. Exact-case match — Twitch native
    /// emotes are case-sensitive ("Kappa" ≠ "kappa") and all three
    /// providers follow the same convention.
    private var byName: [String: Emote] = [:]

    /// Idempotency key: the `broadcasterId` we most recently loaded for
    /// *completely* (every provider succeeded). If `load(...)` is called
    /// again with the same id, it returns at once (at most starting a
    /// background revalidation). This is what makes the index
    /// registry-friendly — multiple view mounts of the same channel call
    /// `load(...)` but the network work happens once.
    private var loadedBroadcasterId: String?

    /// When the channel data now being served was fetched from the
    /// providers (this session, or the disk copy's own stamp), and for
    /// which broadcaster. `fetchedAt == nil` = unknown age.
    private var channelData: (broadcasterId: String, fetchedAt: Date?)?

    /// Start of the most recent pass that asked the providers for channel
    /// emotes. Spaces out `reload`.
    private var lastChannelFetch: (broadcasterId: String, startedAt: Date)?

    /// Consecutive passes that ended with a provider failure, and the
    /// earliest time `load` may try again.
    private var failures: (broadcasterId: String, count: Int, retryNotBefore: Date)?

    /// Wall clock. Injected so tests can age the data and step past backoff.
    private let now: @Sendable () -> Date

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

    /// See `setPublishObserver`.
    private var publishObserver: (@Sendable () -> Void)?

    private let providers: [any EmoteProvider]

    /// Each provider's most recent SUCCESSFUL channel result this session
    /// (keyed by provider index, empty results included), for the
    /// broadcaster it was fetched for. After a partial load the disk copy
    /// isn't rewritten, so a provider that succeeded then and fails on the
    /// retry must fall back to THIS, not to the older disk data — and a
    /// successful empty result must keep removed emotes removed.
    private var lastChannelResults: (broadcasterId: String, byProvider: [Int: [Emote]])?

    /// Shared source of global emotes.
    private let globalCatalog: GlobalEmoteCatalog

    /// Disk cache for this channel's channel-only emote set. Keyed by
    /// broadcasterId.
    private let cache: JSONDiskCache

    /// How long a disk-restored channel set may open a channel without
    /// waiting on the network. Past `revalidateAfter` it is still refreshed,
    /// just behind the caller.
    private static let cacheTTL: TimeInterval = 24 * 60 * 60

    /// Age at which served channel data is refetched in the background.
    static let revalidateAfter: TimeInterval = 60 * 60

    /// `reload` won't hit the providers again sooner than this after the
    /// previous channel fetch.
    static let minimumReloadInterval: TimeInterval = 60

    /// Backoff after repeated failed passes: none after the first (the next
    /// mount retries, which is what clears a one-off 5xx), then 30 s
    /// doubling up to 15 min.
    static func retryDelay(afterFailures count: Int) -> TimeInterval {
        guard count > 1 else { return 0 }
        return min(30 * Double(1 << min(count - 2, 10)), 15 * 60)
    }

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
        self.now = { Date() }
    }

    /// Inject-providers initializer. Production passes
    /// `GlobalEmoteCatalog.shared`; the default is a fresh memory-only
    /// catalog so tests stay isolated from each other and from disk.
    public init(
        providers: [any EmoteProvider],
        globalCatalog: GlobalEmoteCatalog = GlobalEmoteCatalog(cache: nil),
        cache: JSONDiskCache = JSONDiskCache(subdirectory: CacheSubdirectory.emoteChannels),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.providers = providers
        self.globalCatalog = globalCatalog
        self.cache = cache
        self.now = now
    }

    /// Loads global + per-channel emotes for the given (id, login) pair.
    ///
    /// **Idempotent**: calling with the same `broadcasterId` we already
    /// fully loaded for returns at once with the table as it stands; if the
    /// channel data has aged past `revalidateAfter`, a refetch starts
    /// behind the caller and publishes when it lands. Concurrent calls for
    /// the same broadcaster share one load and all return after it has
    /// finished (and published, if it produced anything).
    ///
    /// The load runs in a task owned by the index, so a caller's
    /// cancellation (e.g. a `.task` torn down by a tab swipe) neither
    /// cancels the shared work nor leaves a half-published table — the
    /// registry-owned index finishes loading for the next mount.
    public func load(broadcasterId: String, broadcasterLogin: String) async {
        if loadedBroadcasterId == broadcasterId {
            revalidateIfDue(broadcasterId: broadcasterId, broadcasterLogin: broadcasterLogin)
            return
        }
        if let inFlight = inFlightLoad, inFlight.broadcasterId == broadcasterId {
            await inFlight.task.value
            return
        }
        // Still failing after a retry: serve what's published until the
        // backoff runs out instead of hitting the providers on every mount.
        if isBackingOff(broadcasterId) { return }

        await startPass(
            broadcasterId: broadcasterId, broadcasterLogin: broadcasterLogin, forceChannelFetch: false
        ).value
        // A disk copy inside its TTL loads without the network; if it is
        // already old enough to revalidate, do that now, behind the caller.
        if loadedBroadcasterId == broadcasterId {
            revalidateIfDue(broadcasterId: broadcasterId, broadcasterLogin: broadcasterLogin)
        }
    }

    /// Refetches the channel's emotes from the providers now, whatever the
    /// age of the data being served, and returns once the new table is
    /// published. The current table keeps being served meanwhile, and stays
    /// if the fetch fails.
    ///
    /// Returns `false` without fetching when the providers were already
    /// asked less than `minimumReloadInterval` ago. A pass already running
    /// for this broadcaster is joined rather than doubled.
    @discardableResult
    public func reload(broadcasterId: String, broadcasterLogin: String) async -> Bool {
        if let inFlight = inFlightLoad, inFlight.broadcasterId == broadcasterId {
            await inFlight.task.value
            return true
        }
        if let last = lastChannelFetch, last.broadcasterId == broadcasterId,
           now().timeIntervalSince(last.startedAt) < Self.minimumReloadInterval {
            return false
        }
        await startPass(
            broadcasterId: broadcasterId, broadcasterLogin: broadcasterLogin, forceChannelFetch: true
        ).value
        return true
    }

    /// O(1) lookup. Returns nil if the name isn't a known emote.
    /// Prefer the nonisolated `snapshot()` for high-frequency renderer
    /// lookups (avoids actor-hop cost per message token).
    public func resolve(name: String) -> Emote? {
        byName[name]
    }

    // MARK: - Private

    /// Starts a pass in a task owned by the index and registers it as the
    /// one in flight. `performLoad` is isolated to this actor, so it can't
    /// start before `inFlightLoad` is assigned (the caller holds the actor
    /// until its next `await`).
    @discardableResult
    private func startPass(
        broadcasterId: String, broadcasterLogin: String, forceChannelFetch: Bool
    ) -> Task<Void, Never> {
        nextLoadToken &+= 1
        let token = nextLoadToken
        let task = Task {
            await self.performLoad(
                broadcasterId: broadcasterId, broadcasterLogin: broadcasterLogin,
                token: token, forceChannelFetch: forceChannelFetch)
        }
        inFlightLoad = InFlightLoad(broadcasterId: broadcasterId, token: token, task: task)
        return task
    }

    /// Stale-while-revalidate: once the served channel data is older than
    /// `revalidateAfter` (or of unknown age), refetch it without making the
    /// caller wait. The published table stays until the new one lands.
    private func revalidateIfDue(broadcasterId: String, broadcasterLogin: String) {
        guard inFlightLoad == nil, !isBackingOff(broadcasterId) else { return }
        if let data = channelData, data.broadcasterId == broadcasterId, let fetchedAt = data.fetchedAt,
           now().timeIntervalSince(fetchedAt) < Self.revalidateAfter {
            return
        }
        startPass(broadcasterId: broadcasterId, broadcasterLogin: broadcasterLogin, forceChannelFetch: true)
    }

    private func isBackingOff(_ broadcasterId: String) -> Bool {
        guard let failures, failures.broadcasterId == broadcasterId else { return false }
        return now() < failures.retryNotBefore
    }

    private func recordFailure(for broadcasterId: String) {
        var count = 1
        if let failures, failures.broadcasterId == broadcasterId {
            count = failures.count + 1
        }
        failures = (
            broadcasterId: broadcasterId,
            count: count,
            retryNotBefore: now().addingTimeInterval(Self.retryDelay(afterFailures: count)))
    }

    /// One provider's contribution to a load. `succeeded == false` means
    /// the fetch threw; `emotes` is then the stale fallback (globals) or
    /// empty (channel).
    private enum FetchOutcome: Sendable {
        case global(providerIndex: Int, emotes: [Emote], succeeded: Bool)
        case channel(providerIndex: Int, emotes: [Emote], succeeded: Bool)
    }

    private func performLoad(
        broadcasterId: String, broadcasterLogin: String, token: UInt64, forceChannelFetch: Bool
    ) async {
        // Clear the in-flight marker on every exit path — but only if it's
        // still ours (a load for a different broadcaster may have replaced
        // it). Runs on the actor as the task completes, so a caller arriving
        // afterwards starts a fresh load (retry) rather than re-awaiting a
        // finished partial one.
        defer {
            if inFlightLoad?.token == token { inFlightLoad = nil }
        }

        let fetchProviders = self.providers
        let signature = Self.sourceSignature(of: fetchProviders)
        let enabledSources = Self.declaredSources(of: fetchProviders)

        // 1. Disk: the channel-only set for this broadcaster, if any.
        var diskChannel: [String: Emote]?
        var diskChannelIsFresh = false
        var diskFetchedAt: Date?
        if let hit = await cache.load(
            key: broadcasterId, as: ChannelEmoteCachePayload.self,
            version: ChannelEmoteCachePayload.cacheVersion, ttl: Self.cacheTTL
        ), hit.payload.broadcasterId == broadcasterId {
            // Only the enabled sources' entries: a provider switched off
            // since the file was written must not keep rendering from it.
            if let enabledSources {
                diskChannel = hit.payload.byName.filter { enabledSources.contains($0.value.source) }
            } else {
                diskChannel = hit.payload.byName
            }
            // Written for another provider set (or before the set was
            // recorded): good enough to render, not to skip the fetch.
            diskChannelIsFresh = hit.isFresh && hit.payload.sources == signature
            diskFetchedAt = hit.payload.fetchedAt
        }
        let diskChannelSets: [[Emote]] = diskChannel.map { [Array($0.values)] } ?? []

        // 2. Instant render: whatever globals the catalog already holds
        //    (memory/disk, any freshness) + the disk channel set. Only when
        //    nothing is showing yet — never regress a fuller table from an
        //    earlier (partial) load to older cached data.
        var cachedGlobals = [[Emote]](repeating: [], count: fetchProviders.count)
        for (index, provider) in fetchProviders.enumerated() {
            cachedGlobals[index] = await globalCatalog.cachedGlobals(for: provider) ?? []
        }
        if byName.isEmpty {
            let restored = Self.compose(globals: cachedGlobals, channel: diskChannelSets)
            if !restored.isEmpty {
                publish(restored)
                logger.info("EmoteIndex restored \(restored.count) cached emote(s) for \(broadcasterLogin, privacy: .public)")
            }
        }

        // 3. Network: globals via the shared catalog (usually a memory hit),
        //    channel sets per provider unless the disk copy is still fresh.
        let fetchChannel = forceChannelFetch || !diskChannelIsFresh
        let passStartedAt = now()
        if fetchChannel {
            lastChannelFetch = (broadcasterId: broadcasterId, startedAt: passStartedAt)
        }
        let catalog = self.globalCatalog
        // Each provider's last successful channel result this session.
        let remembered: [Int: [Emote]]
        if let last = lastChannelResults, last.broadcasterId == broadcasterId {
            remembered = last.byProvider
        } else {
            remembered = [:]
        }
        // Until a provider's globals land it keeps the set the catalog
        // already holds, so a table published part-way doesn't drop them.
        var globalsByProvider = cachedGlobals
        var channelByProvider = [[Emote]](repeating: [], count: fetchProviders.count)
        var allGlobalsSucceeded = true
        var allChannelsSucceeded = true
        var failedChannelProviders: Set<Int> = []
        var pendingChannelProviders: Set<Int> = fetchChannel ? Set(fetchProviders.indices) : []

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
                    pendingChannelProviders.remove(index)
                    if !succeeded {
                        allChannelsSucceeded = false
                        failedChannelProviders.insert(index)
                    }
                }
                // Publish what has landed instead of waiting for the slowest
                // provider. Nothing here marks the load complete or touches
                // the disk copy — that stays with the full result below.
                var landedChannelSets: [[Emote]]? = diskChannelSets
                if fetchChannel {
                    landedChannelSets = Self.interimChannelSets(
                        fetched: channelByProvider,
                        pending: pendingChannelProviders,
                        failed: failedChannelProviders,
                        providers: fetchProviders,
                        remembered: remembered,
                        stale: diskChannel)
                }
                if let landedChannelSets {
                    self.publishIfChanged(Self.compose(globals: globalsByProvider, channel: landedChannelSets))
                }
            }
        }

        var channelSets = diskChannelSets
        if fetchChannel {
            channelSets = Self.channelSetsWithFallback(
                fetched: channelByProvider,
                failed: failedChannelProviders,
                providers: fetchProviders,
                remembered: remembered,
                stale: diskChannel)
            var results = remembered
            for index in channelByProvider.indices where !failedChannelProviders.contains(index) {
                results[index] = channelByProvider[index]
            }
            lastChannelResults = (broadcasterId: broadcasterId, byProvider: results)
        }
        let finalSnapshot = Self.compose(globals: globalsByProvider, channel: channelSets)
        let succeeded = allGlobalsSucceeded && allChannelsSucceeded

        // All providers failed or returned nothing. Don't clobber a
        // disk-restored snapshot (or a prior load) with emptiness, and don't
        // mark loaded — let a later mount retry.
        guard !finalSnapshot.isEmpty else {
            if !succeeded { recordFailure(for: broadcasterId) }
            logger.info("EmoteIndex produced no emotes for \(broadcasterLogin, privacy: .public); keeping existing snapshot")
            return
        }
        publishIfChanged(finalSnapshot)

        // The age revalidation runs on: a channel fetch every provider
        // answered is current as of this pass; a disk copy served without a
        // fetch is as old as its own stamp.
        if !fetchChannel {
            channelData = (broadcasterId: broadcasterId, fetchedAt: diskFetchedAt)
        } else if allChannelsSucceeded {
            channelData = (broadcasterId: broadcasterId, fetchedAt: passStartedAt)
        }

        if succeeded {
            // Mark loaded before the async cache write so a re-entrant
            // `load()` arriving during the save suspension short-circuits.
            loadedBroadcasterId = broadcasterId
            failures = nil
        } else {
            recordFailure(for: broadcasterId)
            logger.warning("EmoteIndex partial load for \(broadcasterLogin, privacy: .public) (globals ok: \(allGlobalsSucceeded), channel ok: \(allChannelsSucceeded)); will retry on a later load")
        }

        // Persist the channel set only when it came from the network and
        // every provider answered — a partial set must not be served as
        // fresh for 24h. (Global failures don't affect the channel-only file.)
        if fetchChannel && allChannelsSucceeded {
            await cache.save(
                key: broadcasterId,
                value: ChannelEmoteCachePayload(
                    broadcasterId: broadcasterId,
                    byName: Self.compose(globals: [], channel: channelByProvider),
                    sources: signature,
                    fetchedAt: passStartedAt),
                version: ChannelEmoteCachePayload.cacheVersion)
        }
        logger.info("EmoteIndex loaded for \(broadcasterLogin, privacy: .public): \(finalSnapshot.count) emote(s)")
    }

    /// Identifies the provider set a channel payload was built from: each
    /// provider's source, or its catalog key when it doesn't declare one.
    /// Sorted, so the order providers are listed in doesn't matter.
    static func sourceSignature(of providers: [any EmoteProvider]) -> [String] {
        providers.map { $0.emoteSource?.rawValue ?? $0.globalCatalogKey }.sorted()
    }

    /// The sources the given providers issue, or `nil` when one of them
    /// doesn't declare its source — entries can't be attributed then, so
    /// nothing is filtered by source.
    static func declaredSources(of providers: [any EmoteProvider]) -> Set<Emote.Source>? {
        var sources: Set<Emote.Source> = []
        for provider in providers {
            guard let source = provider.emoteSource else { return nil }
            sources.insert(source)
        }
        return sources
    }

    /// The channel sets for a table published while some channel fetches
    /// are still out. A provider that hasn't answered is treated like one
    /// that failed — it keeps its last good set (see
    /// `channelSetsWithFallback`) — so a part-way table never drops emotes
    /// the rest of the pass would put straight back.
    ///
    /// `nil` = hold off publishing: a pending provider has entries in the
    /// stale disk copy that can't be told apart from the others' (it
    /// declares no `emoteSource` and has no result from this session).
    static func interimChannelSets(
        fetched: [[Emote]],
        pending: Set<Int>,
        failed: Set<Int>,
        providers: [any EmoteProvider],
        remembered: [Int: [Emote]] = [:],
        stale: [String: Emote]?
    ) -> [[Emote]]? {
        if stale != nil {
            for index in pending where remembered[index] == nil {
                guard providers.indices.contains(index), providers[index].emoteSource != nil else { return nil }
            }
        }
        return channelSetsWithFallback(
            fetched: fetched,
            failed: failed.union(pending),
            providers: providers,
            remembered: remembered,
            stale: stale)
    }

    /// The channel sets to publish after a network pass: each provider's
    /// fresh result, except that a provider whose fetch FAILED contributes
    /// its last good set instead of nothing — preferably its most recent
    /// successful result this session (`remembered`), else its own entries
    /// from the stale disk copy. Without this, a stale cache + one provider's
    /// outage published a snapshot missing that provider's channel emotes
    /// entirely (the snapshot is non-empty as long as anything else loaded,
    /// so it replaced the disk-restored one). For the disk fallback,
    /// providers with an unknown `emoteSource` keep the old behavior:
    /// nothing to attribute stale entries to.
    static func channelSetsWithFallback(
        fetched: [[Emote]],
        failed: Set<Int>,
        providers: [any EmoteProvider],
        remembered: [Int: [Emote]] = [:],
        stale: [String: Emote]?
    ) -> [[Emote]] {
        guard !failed.isEmpty else { return fetched }
        var sets = fetched
        for index in failed where sets.indices.contains(index) {
            if let last = remembered[index] {
                sets[index] = last
            } else if let stale,
                      providers.indices.contains(index),
                      let source = providers[index].emoteSource {
                sets[index] = stale.values.filter { $0.source == source }
            }
        }
        return sets
    }

    /// Publishes `snapshot` unless it is empty or already the table being
    /// served — a pass republishes as providers land, and most of those
    /// tables (and the final one) match what is already out. Skipping them
    /// keeps `generation` from moving when nothing changed.
    private func publishIfChanged(_ snapshot: [String: Emote]) {
        guard !snapshot.isEmpty, snapshot != byName else { return }
        publish(snapshot)
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
        publishObserver?()
    }

    /// Called after every published table: each provider's interim result,
    /// the final merge, and a background revalidation that lands long after
    /// `load` returned. Lets the owner re-render rows built against the
    /// previous table. One observer; `nil` clears it.
    public func setPublishObserver(_ observer: (@Sendable () -> Void)?) {
        publishObserver = observer
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
