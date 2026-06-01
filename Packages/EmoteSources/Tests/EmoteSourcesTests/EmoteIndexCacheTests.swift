import Foundation
import os
import Testing
import Core
@testable import EmoteSources

/// Fake provider that counts how many times its global fetch ran, so tests
/// can assert whether the network path was taken.
final class CountingProvider: EmoteProvider, @unchecked Sendable {
    let globalCalls = OSAllocatedUnfairLock(initialState: 0)
    private let emotes: [Emote]

    init(returning emotes: [Emote]) { self.emotes = emotes }

    func globalEmotes() async throws -> [Emote] {
        globalCalls.withLock { $0 += 1 }
        return emotes
    }
    func channelEmotes(broadcasterId: String, broadcasterLogin: String) async throws -> [Emote] {
        []
    }
    var globalCallCount: Int { globalCalls.withLock { $0 } }
}

@Suite("EmoteIndex disk cache")
struct EmoteIndexCacheTests {

    private func tempBase() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("emoteindex-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func sampleEmote(_ name: String) -> Emote {
        Emote(id: "7tv:\(name)", name: name,
              urls: [.x1: URL(string: "https://cdn/\(name)")!],
              isAnimated: false, isZeroWidth: false, source: .sevenTV, ownerChannelId: nil)
    }

    @Test("fresh disk hit renders without calling providers")
    func freshHitSkipsNetwork() async throws {
        let base = tempBase()
        let cache = JSONDiskCache(subdirectory: "ch", baseDirectory: base)
        // Seed a fresh cache entry for channel "555".
        await cache.save(
            key: "555",
            value: ChannelEmoteCachePayload(broadcasterId: "555", byName: ["Kappa": sampleEmote("Kappa")]),
            version: ChannelEmoteCachePayload.cacheVersion)

        let provider = CountingProvider(returning: [sampleEmote("OTHER")])
        let index = EmoteIndex(providers: [provider], cache: cache)

        await index.load(broadcasterId: "555", broadcasterLogin: "x")

        #expect(provider.globalCallCount == 0)                 // network skipped
        #expect(index.snapshot()["Kappa"] != nil)              // disk data rendered
    }

    @Test("stale disk hit triggers network and overwrites cache")
    func staleHitRefetches() async throws {
        let base = tempBase()
        let cache = JSONDiskCache(subdirectory: "ch", baseDirectory: base)
        await cache.save(
            key: "777",
            value: ChannelEmoteCachePayload(broadcasterId: "777", byName: ["OldEmote": sampleEmote("OldEmote")]),
            version: ChannelEmoteCachePayload.cacheVersion)

        // Backdate the file to 2 days ago so it is past the 24h TTL.
        let url = base.appendingPathComponent("ch", isDirectory: true)
            .appendingPathComponent("777.json")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-2 * 24 * 3600)],
            ofItemAtPath: url.path)

        let provider = CountingProvider(returning: [sampleEmote("FreshEmote")])
        let index = EmoteIndex(providers: [provider], cache: cache)

        await index.load(broadcasterId: "777", broadcasterLogin: "x")

        #expect(provider.globalCallCount == 1)                 // network ran
        #expect(index.snapshot()["FreshEmote"] != nil)         // fresh data published
        // Cache overwritten with fresh data (and now fresh again).
        let hit = await cache.load(key: "777", as: ChannelEmoteCachePayload.self,
                                   version: ChannelEmoteCachePayload.cacheVersion, ttl: 24 * 3600)
        #expect(hit?.isFresh == true)
        #expect(hit?.payload.byName["FreshEmote"] != nil)
    }

    @Test("no cache + providers return nothing leaves snapshot empty and does not write")
    func emptyResultNoWrite() async throws {
        let base = tempBase()
        let cache = JSONDiskCache(subdirectory: "ch", baseDirectory: base)
        let provider = CountingProvider(returning: [])
        let index = EmoteIndex(providers: [provider], cache: cache)

        await index.load(broadcasterId: "888", broadcasterLogin: "x")

        #expect(index.snapshot().isEmpty)
        #expect(await cache.load(key: "888", as: ChannelEmoteCachePayload.self,
                                 version: ChannelEmoteCachePayload.cacheVersion, ttl: 24 * 3600) == nil)
    }

    @Test("stale hit + empty refetch keeps disk-restored snapshot")
    func staleHitEmptyRefetchKeepsDiskData() async throws {
        let base = tempBase()
        let cache = JSONDiskCache(subdirectory: "ch", baseDirectory: base)
        await cache.save(
            key: "321",
            value: ChannelEmoteCachePayload(broadcasterId: "321", byName: ["DiskEmote": sampleEmote("DiskEmote")]),
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

        #expect(provider.globalCallCount == 1)                 // it did try the network
        #expect(index.snapshot()["DiskEmote"] != nil)          // stale disk data preserved, not clobbered
    }
}
