import Foundation
import os
import Testing
import Core
@testable import EmoteSources

/// Fake provider that counts how many times each fetch ran, so tests can
/// assert whether the network path was taken. `globalCatalogKey` is
/// per-instance so a shared `GlobalEmoteCatalog` never confuses two fakes.
final class CountingProvider: EmoteProvider {
    let globalCalls = OSAllocatedUnfairLock(initialState: 0)
    let channelCalls = OSAllocatedUnfairLock(initialState: 0)
    private let globals: [Emote]
    private let channel: [Emote]
    let globalCatalogKey = "counting-\(UUID().uuidString)"

    init(returning globals: [Emote], channel: [Emote] = []) {
        self.globals = globals
        self.channel = channel
    }

    func globalEmotes() async throws -> [Emote] {
        globalCalls.withLock { $0 += 1 }
        return globals
    }
    func channelEmotes(broadcasterId: String, broadcasterLogin: String) async throws -> [Emote] {
        channelCalls.withLock { $0 += 1 }
        return channel
    }
    var globalCallCount: Int { globalCalls.withLock { $0 } }
    var channelCallCount: Int { channelCalls.withLock { $0 } }
}

/// Provider whose fetches throw for the first `failures` calls of each kind,
/// then succeed — models a transient 5xx / 429.
final class FlakyProvider: EmoteProvider {
    private let globalFailuresLeft: OSAllocatedUnfairLock<Int>
    private let channelFailuresLeft: OSAllocatedUnfairLock<Int>
    let globalCalls = OSAllocatedUnfairLock(initialState: 0)
    private let globals: [Emote]
    private let channel: [Emote]
    let globalCatalogKey = "flaky-\(UUID().uuidString)"

    init(globals: [Emote], channel: [Emote] = [], globalFailures: Int = 0, channelFailures: Int = 0) {
        self.globals = globals
        self.channel = channel
        self.globalFailuresLeft = OSAllocatedUnfairLock(initialState: globalFailures)
        self.channelFailuresLeft = OSAllocatedUnfairLock(initialState: channelFailures)
    }

    func globalEmotes() async throws -> [Emote] {
        globalCalls.withLock { $0 += 1 }
        let fail = globalFailuresLeft.withLock { (left: inout Int) -> Bool in
            guard left > 0 else { return false }
            left -= 1
            return true
        }
        if fail { throw EmoteProviderError.httpStatus(503) }
        return globals
    }

    func channelEmotes(broadcasterId: String, broadcasterLogin: String) async throws -> [Emote] {
        let fail = channelFailuresLeft.withLock { (left: inout Int) -> Bool in
            guard left > 0 else { return false }
            left -= 1
            return true
        }
        if fail { throw EmoteProviderError.httpStatus(429) }
        return channel
    }
    var globalCallCount: Int { globalCalls.withLock { $0 } }
}

@Suite("EmoteIndex disk cache")
struct EmoteIndexCacheTests {

    private func tempBase() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("emoteindex-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func sampleEmote(_ name: String, owner: String? = nil, source: Emote.Source = .sevenTV) -> Emote {
        Emote(id: "\(source):\(name)", name: name,
              urls: [.x1: URL(string: "https://cdn/\(name)")!],
              isAnimated: false, isZeroWidth: false, source: source, ownerChannelId: owner)
    }

    private func loadPayload(_ cache: JSONDiskCache, key: String) async -> CacheHit<ChannelEmoteCachePayload>? {
        await cache.load(key: key, as: ChannelEmoteCachePayload.self,
                         version: ChannelEmoteCachePayload.cacheVersion, ttl: 24 * 3600)
    }

    @Test("fresh channel disk hit renders without refetching channel emotes")
    func freshHitSkipsChannelNetwork() async throws {
        let base = tempBase()
        let cache = JSONDiskCache(subdirectory: "ch", baseDirectory: base)
        let provider = CountingProvider(returning: [sampleEmote("GLOBAL")], channel: [sampleEmote("OTHER", owner: "555")])
        // Seed a fresh channel-only entry for channel "555", written by this
        // same provider set just now — the only kind that skips the fetch.
        await cache.save(
            key: "555",
            value: ChannelEmoteCachePayload(
                broadcasterId: "555",
                byName: ["Kappa": sampleEmote("Kappa", owner: "555")],
                sources: EmoteIndex.sourceSignature(of: [provider]),
                fetchedAt: Date()),
            version: ChannelEmoteCachePayload.cacheVersion)

        let index = EmoteIndex(providers: [provider], cache: cache)

        await index.load(broadcasterId: "555", broadcasterLogin: "x")

        #expect(provider.channelCallCount == 0)                // channel network skipped
        #expect(index.snapshot()["Kappa"] != nil)              // disk channel data rendered
        #expect(index.snapshot()["OTHER"] == nil)
        #expect(index.snapshot()["GLOBAL"] != nil)             // globals merged in from the catalog
    }

    @Test("stale disk hit triggers network and overwrites cache with channel-only data")
    func staleHitRefetches() async throws {
        let base = tempBase()
        let cache = JSONDiskCache(subdirectory: "ch", baseDirectory: base)
        await cache.save(
            key: "777",
            value: ChannelEmoteCachePayload(broadcasterId: "777", byName: ["OldEmote": sampleEmote("OldEmote", owner: "777")]),
            version: ChannelEmoteCachePayload.cacheVersion)

        // Backdate the file to 2 days ago so it is past the 24h TTL.
        let url = base.appendingPathComponent("ch", isDirectory: true)
            .appendingPathComponent("777.json")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-2 * 24 * 3600)],
            ofItemAtPath: url.path)

        let provider = CountingProvider(
            returning: [sampleEmote("GlobalEmote")],
            channel: [sampleEmote("FreshEmote", owner: "777")])
        let index = EmoteIndex(providers: [provider], cache: cache)

        await index.load(broadcasterId: "777", broadcasterLogin: "x")

        #expect(provider.channelCallCount == 1)                // network ran
        #expect(index.snapshot()["FreshEmote"] != nil)         // fresh data published
        #expect(index.snapshot()["OldEmote"] == nil)
        // Cache overwritten with fresh channel data (and now fresh again);
        // globals are NOT persisted per channel.
        let hit = await loadPayload(cache, key: "777")
        #expect(hit?.isFresh == true)
        #expect(hit?.payload.byName["FreshEmote"] != nil)
        #expect(hit?.payload.byName["GlobalEmote"] == nil)
    }

    @Test("no cache + providers return nothing leaves snapshot empty and does not write")
    func emptyResultNoWrite() async throws {
        let base = tempBase()
        let cache = JSONDiskCache(subdirectory: "ch", baseDirectory: base)
        let provider = CountingProvider(returning: [])
        let index = EmoteIndex(providers: [provider], cache: cache)

        await index.load(broadcasterId: "888", broadcasterLogin: "x")

        #expect(index.snapshot().isEmpty)
        #expect(index.generation == 0)                         // nothing published
        #expect(await loadPayload(cache, key: "888") == nil)
    }

    @Test("concurrent loads for the same channel fetch providers once")
    func concurrentLoadsCoalesce() async throws {
        let base = tempBase()
        let cache = JSONDiskCache(subdirectory: "ch", baseDirectory: base)
        // No seeded cache → both callers miss disk and head for the network.
        let provider = CountingProvider(returning: [sampleEmote("Kappa")])
        let index = EmoteIndex(providers: [provider], cache: cache)

        async let first: Void = index.load(broadcasterId: "999", broadcasterLogin: "x")
        async let second: Void = index.load(broadcasterId: "999", broadcasterLogin: "x")
        _ = await (first, second)

        #expect(provider.globalCallCount == 1)                 // providers ran once, not twice
        #expect(provider.channelCallCount == 1)
        #expect(index.snapshot()["Kappa"] != nil)              // snapshot still published
    }

    @Test("a concurrent caller waits for the in-flight load instead of returning early")
    func concurrentCallerAwaitsInFlightLoad() async throws {
        let provider = ScriptedProvider(
            global: [sampleEmote("Slow")],
            globalDelay: .milliseconds(100))
        let index = EmoteIndex(
            providers: [provider],
            cache: JSONDiskCache(subdirectory: "ch", baseDirectory: tempBase()))

        // Whichever call reaches the actor second must still observe the
        // published snapshot when it returns.
        @Sendable func loadThenCount() async -> Int {
            await index.load(broadcasterId: "42", broadcasterLogin: "x")
            return index.snapshot().count
        }
        async let a = loadThenCount()
        async let b = loadThenCount()
        let (countA, countB) = await (a, b)

        #expect(countA == 1)
        #expect(countB == 1)
    }

    @Test("stale hit + empty refetch keeps disk-restored snapshot")
    func staleHitEmptyRefetchKeepsDiskData() async throws {
        let base = tempBase()
        let cache = JSONDiskCache(subdirectory: "ch", baseDirectory: base)
        await cache.save(
            key: "321",
            value: ChannelEmoteCachePayload(broadcasterId: "321", byName: ["DiskEmote": sampleEmote("DiskEmote", owner: "321")]),
            version: ChannelEmoteCachePayload.cacheVersion)

        // Backdate past the 24h TTL so the disk hit is stale → triggers refetch.
        let url = base.appendingPathComponent("ch", isDirectory: true)
            .appendingPathComponent("321.json")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-2 * 24 * 3600)],
            ofItemAtPath: url.path)

        // Providers return nothing (simulating a transient network failure).
        let provider = CountingProvider(returning: [])
        let index = EmoteIndex(providers: [provider], cache: cache)

        await index.load(broadcasterId: "321", broadcasterLogin: "x")

        #expect(provider.channelCallCount == 1)                // it did try the network
        #expect(index.snapshot()["DiskEmote"] != nil)          // stale disk data preserved, not clobbered
    }

    // MARK: - Shared global catalog

    @Test("indexes sharing a catalog fetch each provider's globals once")
    func sharedCatalogFetchesGlobalsOnce() async throws {
        let base = tempBase()
        let cache = JSONDiskCache(subdirectory: "ch", baseDirectory: base)
        let catalog = GlobalEmoteCatalog(cache: nil)
        let provider = CountingProvider(
            returning: [sampleEmote("Global")],
            channel: [sampleEmote("Chan", owner: "x")])

        let a = EmoteIndex(providers: [provider], globalCatalog: catalog, cache: cache)
        let b = EmoteIndex(providers: [provider], globalCatalog: catalog, cache: cache)
        let c = EmoteIndex(providers: [provider], globalCatalog: catalog, cache: cache)
        async let la: Void = a.load(broadcasterId: "1", broadcasterLogin: "one")
        async let lb: Void = b.load(broadcasterId: "2", broadcasterLogin: "two")
        _ = await (la, lb)
        await c.load(broadcasterId: "3", broadcasterLogin: "three")

        #expect(provider.globalCallCount == 1)                 // coalesced + memory-cached
        #expect(provider.channelCallCount == 3)                // channel sets stay per channel
        #expect(a.snapshot()["Global"] != nil)
        #expect(c.snapshot()["Global"] != nil)
    }

    @Test("catalog persists globals to disk and restores them without network")
    func catalogDiskRoundTrip() async throws {
        let globalsCache = JSONDiskCache(subdirectory: "globals", baseDirectory: tempBase())
        let provider = CountingProvider(returning: [sampleEmote("Persisted")])

        let first = GlobalEmoteCatalog(cache: globalsCache)
        _ = try await first.globals(for: provider)
        #expect(provider.globalCallCount == 1)

        // A new catalog (cold launch) over the same disk serves the fresh
        // entry without hitting the provider.
        let second = GlobalEmoteCatalog(cache: globalsCache)
        let restored = try await second.globals(for: provider)
        #expect(provider.globalCallCount == 1)
        #expect(restored.map(\.name) == ["Persisted"])
    }

    // MARK: - Partial failure

    @Test("a failed global fetch is not marked loaded and retries on the next load")
    func partialGlobalFailureRetries() async throws {
        let base = tempBase()
        let cache = JSONDiskCache(subdirectory: "ch", baseDirectory: base)
        let healthy = CountingProvider(returning: [sampleEmote("Healthy", source: .bttv)])
        let flaky = FlakyProvider(globals: [sampleEmote("Flaky", source: .ffz)], globalFailures: 1)
        let index = EmoteIndex(providers: [healthy, flaky], cache: cache)

        await index.load(broadcasterId: "600", broadcasterLogin: "x")
        #expect(index.snapshot()["Healthy"] != nil)            // partial result still rendered
        #expect(index.snapshot()["Flaky"] == nil)

        await index.load(broadcasterId: "600", broadcasterLogin: "x")
        #expect(flaky.globalCallCount == 2)                    // retried — not stuck as "loaded"
        #expect(healthy.globalCallCount == 1)                  // the healthy one is served from the catalog
        #expect(index.snapshot()["Flaky"] != nil)

        // Fully loaded now: a third call is a no-op.
        await index.load(broadcasterId: "600", broadcasterLogin: "x")
        #expect(flaky.globalCallCount == 2)
    }

    @Test("a failed channel fetch is neither persisted nor marked loaded")
    func partialChannelFailureNotPersisted() async throws {
        let base = tempBase()
        let cache = JSONDiskCache(subdirectory: "ch", baseDirectory: base)
        let healthy = CountingProvider(
            returning: [sampleEmote("G", source: .bttv)],
            channel: [sampleEmote("HealthyChan", owner: "700", source: .bttv)])
        let flaky = FlakyProvider(
            globals: [],
            channel: [sampleEmote("FlakyChan", owner: "700", source: .ffz)],
            channelFailures: 1)
        let index = EmoteIndex(providers: [healthy, flaky], cache: cache)

        await index.load(broadcasterId: "700", broadcasterLogin: "x")
        #expect(index.snapshot()["HealthyChan"] != nil)
        #expect(await loadPayload(cache, key: "700") == nil)   // partial channel set not cached

        await index.load(broadcasterId: "700", broadcasterLogin: "x")
        #expect(healthy.channelCallCount == 2)                 // retried
        #expect(index.snapshot()["FlakyChan"] != nil)
        let hit = await loadPayload(cache, key: "700")
        #expect(hit?.payload.byName.keys.sorted() == ["FlakyChan", "HealthyChan"])
    }

    // MARK: - Generation

    @Test("generation starts at 0 and increases on every publish")
    func generationBumpsOnPublish() async throws {
        let provider = CountingProvider(returning: [sampleEmote("A")])
        let index = EmoteIndex(
            providers: [provider],
            cache: JSONDiskCache(subdirectory: "ch", baseDirectory: tempBase()))
        #expect(index.generation == 0)

        await index.load(broadcasterId: "1", broadcasterLogin: "x")
        let afterLoad = index.snapshotWithGeneration()
        #expect(afterLoad.generation > 0)
        #expect(afterLoad.emotes["A"] != nil)

        // Generations are process-wide unique: a second index's first
        // publish never reuses the first index's number.
        let other = EmoteIndex(
            providers: [CountingProvider(returning: [sampleEmote("B")])],
            cache: JSONDiskCache(subdirectory: "ch", baseDirectory: tempBase()))
        await other.load(broadcasterId: "2", broadcasterLogin: "y")
        #expect(other.generation != afterLoad.generation)
    }
}
