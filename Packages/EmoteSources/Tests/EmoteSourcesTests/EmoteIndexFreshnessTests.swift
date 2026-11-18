import Foundation
import os
import Testing
import Core
@testable import EmoteSources

/// Provider with a declared `emoteSource` whose channel fetch plays back a
/// script: call N gets `channelResults[N]`, and the last entry repeats.
final class StagedProvider: EmoteProvider {
    struct State: Sendable {
        var channelResults: [Result<[Emote], EmoteProviderError>]
        var channelCalls = 0
    }

    let emoteSource: Emote.Source?
    let globalCatalogKey = "staged-\(UUID().uuidString)"
    private let globals: [Emote]
    private let state: OSAllocatedUnfairLock<State>

    init(
        source: Emote.Source?,
        globals: [Emote] = [],
        channelResults: [Result<[Emote], EmoteProviderError>]
    ) {
        self.emoteSource = source
        self.globals = globals
        self.state = OSAllocatedUnfairLock(initialState: State(channelResults: channelResults))
    }

    func globalEmotes() async throws -> [Emote] { globals }

    func channelEmotes(broadcasterId: String, broadcasterLogin: String) async throws -> [Emote] {
        let result = state.withLock { (state: inout State) -> Result<[Emote], EmoteProviderError> in
            let index = min(state.channelCalls, state.channelResults.count - 1)
            state.channelCalls += 1
            return state.channelResults[index]
        }
        return try result.get()
    }

    var channelCallCount: Int { state.withLock { $0.channelCalls } }
}

/// Provider whose channel fetch doesn't return until the test opens it.
final class GatedProvider: EmoteProvider {
    private actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            for waiter in waiters { waiter.resume() }
            waiters = []
        }
    }

    let globalCatalogKey = "gated-\(UUID().uuidString)"
    private let channel: [Emote]
    private let gate = Gate()

    init(channel: [Emote]) {
        self.channel = channel
    }

    func open() async { await gate.open() }

    func globalEmotes() async throws -> [Emote] { [] }

    func channelEmotes(broadcasterId: String, broadcasterLogin: String) async throws -> [Emote] {
        await gate.wait()
        return channel
    }
}

/// A clock the test moves by hand.
final class ManualClock: Sendable {
    private let current = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_700_000_000))

    var now: Date { current.withLock { $0 } }

    func advance(by interval: TimeInterval) {
        current.withLock { $0 = $0.addingTimeInterval(interval) }
    }
}

private func tempCache() -> JSONDiskCache {
    JSONDiskCache(
        subdirectory: "ch",
        baseDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("emoteindex-freshness-tests-\(UUID().uuidString)", isDirectory: true))
}

private func emote(_ name: String, source: Emote.Source = .sevenTV, owner: String? = nil) -> Emote {
    Emote(
        id: "\(source):\(name)", name: name,
        urls: [.x1: URL(string: "https://cdn/\(name)")!],
        isAnimated: false, isZeroWidth: false, source: source, ownerChannelId: owner)
}

private func loadPayload(_ cache: JSONDiskCache, key: String) async -> CacheHit<ChannelEmoteCachePayload>? {
    await cache.load(
        key: key, as: ChannelEmoteCachePayload.self,
        version: ChannelEmoteCachePayload.cacheVersion, ttl: 24 * 3600)
}

@Suite("EmoteIndex enabled-source set")
struct EmoteIndexSourceSetTests {

    @Test("the signature names each provider's source, in a stable order")
    func signatureIsOrderIndependent() {
        let forward: [any EmoteProvider] = [SevenTVProvider(), BTTVProvider(), FFZProvider()]
        let backward: [any EmoteProvider] = [FFZProvider(), BTTVProvider(), SevenTVProvider()]
        #expect(EmoteIndex.sourceSignature(of: forward) == ["bttv", "ffz", "sevenTV"])
        #expect(EmoteIndex.sourceSignature(of: backward) == EmoteIndex.sourceSignature(of: forward))
        #expect(EmoteIndex.sourceSignature(of: [BTTVProvider()]) != EmoteIndex.sourceSignature(of: forward))
    }

    @Test("a fresh file written for a different provider set is refetched")
    func sourceMismatchRefetches() async throws {
        let cache = tempCache()
        let provider = CountingProvider(returning: [], channel: [emote("Fetched", owner: "1")])
        await cache.save(
            key: "1",
            value: ChannelEmoteCachePayload(
                broadcasterId: "1",
                byName: ["Cached": emote("Cached", owner: "1")],
                sources: ["some-other-set"],
                fetchedAt: Date()),
            version: ChannelEmoteCachePayload.cacheVersion)
        let index = EmoteIndex(providers: [provider], cache: cache)

        await index.load(broadcasterId: "1", broadcasterLogin: "x")

        #expect(provider.channelCallCount == 1)
        #expect(index.snapshot()["Fetched"] != nil)
        #expect(index.snapshot()["Cached"] == nil)
        // Rewritten under the set that produced it, so the next open skips the fetch.
        let hit = await loadPayload(cache, key: "1")
        #expect(hit?.payload.sources == EmoteIndex.sourceSignature(of: [provider]))
    }

    @Test("a fresh file without a recorded provider set is rendered but refetched")
    func legacyPayloadIsStale() async throws {
        let cache = tempCache()
        await cache.save(
            key: "2",
            value: ChannelEmoteCachePayload(broadcasterId: "2", byName: ["Legacy": emote("Legacy", owner: "2")]),
            version: ChannelEmoteCachePayload.cacheVersion)
        // The refetch comes back empty, so what stays published is the file's contents.
        let provider = CountingProvider(returning: [])
        let index = EmoteIndex(providers: [provider], cache: cache)

        await index.load(broadcasterId: "2", broadcasterLogin: "x")

        #expect(provider.channelCallCount == 1)
        #expect(index.snapshot()["Legacy"] != nil)
    }

    @Test("emotes from a source that is no longer enabled are not restored")
    func disabledSourceNotRestored() async throws {
        let cache = tempCache()
        await cache.save(
            key: "3",
            value: ChannelEmoteCachePayload(
                broadcasterId: "3",
                byName: [
                    "Seven": emote("Seven", source: .sevenTV, owner: "3"),
                    "Bttv": emote("Bttv", source: .bttv, owner: "3"),
                ],
                sources: ["bttv", "sevenTV"],
                fetchedAt: Date()),
            version: ChannelEmoteCachePayload.cacheVersion)
        // Only BTTV is enabled now, and its fetch fails — so everything
        // published comes from the file.
        let bttv = StagedProvider(source: .bttv, channelResults: [.failure(.httpStatus(503))])
        let index = EmoteIndex(providers: [bttv], cache: cache)

        await index.load(broadcasterId: "3", broadcasterLogin: "x")

        #expect(bttv.channelCallCount == 1, "the provider set changed, so the file doesn't stand in for a fetch")
        #expect(index.snapshot()["Bttv"] != nil)
        #expect(index.snapshot()["Seven"] == nil)
    }
}

@Suite("EmoteIndex revalidation, reload and backoff")
struct EmoteIndexRefreshTests {

    @Test("a loaded index refetches channel emotes once they are an hour old")
    func revalidatesAfterAnHour() async throws {
        let clock = ManualClock()
        let provider = StagedProvider(
            source: .sevenTV,
            channelResults: [.success([emote("Old", owner: "1")]), .success([emote("New", owner: "1")])])
        let index = EmoteIndex(providers: [provider], cache: tempCache(), now: { clock.now })

        await index.load(broadcasterId: "1", broadcasterLogin: "x")
        #expect(index.snapshot()["Old"] != nil)

        clock.advance(by: 30 * 60)
        await index.load(broadcasterId: "1", broadcasterLogin: "x")
        #expect(provider.channelCallCount == 1, "still inside the revalidation age")

        clock.advance(by: 31 * 60)
        // Returns at once; the refetch runs behind it.
        await index.load(broadcasterId: "1", broadcasterLogin: "x")
        // Joins that refetch if it is still running; otherwise the minimum
        // interval makes this a no-op. Either way it has landed afterwards.
        await index.reload(broadcasterId: "1", broadcasterLogin: "x")

        #expect(provider.channelCallCount == 2)
        #expect(index.snapshot()["New"] != nil)
        #expect(index.snapshot()["Old"] == nil)

        await index.load(broadcasterId: "1", broadcasterLogin: "x")
        #expect(provider.channelCallCount == 2, "fresh again after the revalidation")
    }

    @Test("a failed revalidation keeps the table that was being served")
    func failedRevalidationKeepsTable() async throws {
        let clock = ManualClock()
        let provider = StagedProvider(
            source: .sevenTV,
            channelResults: [.success([emote("Kept", owner: "1")]), .failure(.httpStatus(503))])
        let index = EmoteIndex(providers: [provider], cache: tempCache(), now: { clock.now })

        await index.load(broadcasterId: "1", broadcasterLogin: "x")
        clock.advance(by: 2 * 60 * 60)
        await index.load(broadcasterId: "1", broadcasterLogin: "x")
        await index.reload(broadcasterId: "1", broadcasterLogin: "x")

        #expect(provider.channelCallCount == 2)
        #expect(index.snapshot()["Kept"] != nil)
    }

    @Test("reload fetches now, but not twice within the minimum interval")
    func reloadRespectsMinimumInterval() async throws {
        let clock = ManualClock()
        let provider = StagedProvider(
            source: .sevenTV,
            channelResults: [.success([emote("First", owner: "1")]), .success([emote("Second", owner: "1")])])
        let index = EmoteIndex(providers: [provider], cache: tempCache(), now: { clock.now })

        await index.load(broadcasterId: "1", broadcasterLogin: "x")
        #expect(provider.channelCallCount == 1)

        let tooSoon = await index.reload(broadcasterId: "1", broadcasterLogin: "x")
        #expect(tooSoon == false)
        #expect(provider.channelCallCount == 1)

        clock.advance(by: EmoteIndex.minimumReloadInterval + 1)
        let reloaded = await index.reload(broadcasterId: "1", broadcasterLogin: "x")
        #expect(reloaded == true)
        #expect(provider.channelCallCount == 2)
        #expect(index.snapshot()["Second"] != nil)
        #expect(index.snapshot()["First"] == nil)
    }

    @Test("the first failure retries on the next load; repeated failures back off")
    func repeatedFailuresBackOff() async throws {
        let clock = ManualClock()
        let provider = StagedProvider(
            source: .sevenTV,
            globals: [emote("Global")],
            channelResults: [.failure(.httpStatus(503))])
        let index = EmoteIndex(providers: [provider], cache: tempCache(), now: { clock.now })

        await index.load(broadcasterId: "1", broadcasterLogin: "x")
        #expect(provider.channelCallCount == 1)
        #expect(index.snapshot()["Global"] != nil)

        await index.load(broadcasterId: "1", broadcasterLogin: "x")
        #expect(provider.channelCallCount == 2, "one failure doesn't delay the retry")

        await index.load(broadcasterId: "1", broadcasterLogin: "x")
        #expect(provider.channelCallCount == 2, "a second failure in a row does")

        clock.advance(by: EmoteIndex.retryDelay(afterFailures: 2) + 1)
        await index.load(broadcasterId: "1", broadcasterLogin: "x")
        #expect(provider.channelCallCount == 3)

        // The delay doubled, so the same wait isn't enough any more.
        clock.advance(by: EmoteIndex.retryDelay(afterFailures: 2) + 1)
        await index.load(broadcasterId: "1", broadcasterLogin: "x")
        #expect(provider.channelCallCount == 3)
    }

    @Test("backoff starts at the second failure, doubles, and is capped")
    func retryDelaySchedule() {
        #expect(EmoteIndex.retryDelay(afterFailures: 1) == 0)
        #expect(EmoteIndex.retryDelay(afterFailures: 2) == 30)
        #expect(EmoteIndex.retryDelay(afterFailures: 3) == 60)
        #expect(EmoteIndex.retryDelay(afterFailures: 4) == 120)
        #expect(EmoteIndex.retryDelay(afterFailures: 100) == 15 * 60)
    }
}

@Suite("EmoteIndex incremental publish")
struct EmoteIndexIncrementalPublishTests {

    @Test("a provider that has landed is published while another is still out, and nothing partial is persisted")
    func publishesAsProvidersLand() async throws {
        let cache = tempCache()
        let fast = CountingProvider(returning: [], channel: [emote("Fast", owner: "1")])
        let slow = GatedProvider(channel: [emote("Slow", owner: "1")])
        let index = EmoteIndex(providers: [fast, slow], cache: cache)

        let load = Task { await index.load(broadcasterId: "1", broadcasterLogin: "x") }

        var fastLanded = false
        for _ in 0..<500 {
            if index.snapshot()["Fast"] != nil {
                fastLanded = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(fastLanded, "the fast provider's emotes didn't wait for the slow one")
        #expect(index.snapshot()["Slow"] == nil)
        #expect(await loadPayload(cache, key: "1") == nil, "a partial channel set is never written")

        await slow.open()
        await load.value

        #expect(index.snapshot()["Fast"] != nil)
        #expect(index.snapshot()["Slow"] != nil)
        let hit = await loadPayload(cache, key: "1")
        #expect(hit?.payload.byName.keys.sorted() == ["Fast", "Slow"])
    }

    @Test("a provider still out keeps its cached channel emotes in a part-way table")
    func pendingProviderKeepsItsStaleEntries() {
        let providers: [any EmoteProvider] = [SevenTVProvider(), BTTVProvider()]
        let stale: [String: Emote] = [
            "OldSeven": emote("OldSeven", source: .sevenTV, owner: "1"),
            "OldBttv": emote("OldBttv", source: .bttv, owner: "1"),
        ]
        // 7TV has answered; BTTV hasn't yet.
        let sets = EmoteIndex.interimChannelSets(
            fetched: [[emote("NewSeven", source: .sevenTV, owner: "1")], []],
            pending: [1], failed: [], providers: providers, stale: stale)
        let merged = EmoteIndex.compose(globals: [], channel: sets ?? [])

        #expect(merged["NewSeven"] != nil)
        #expect(merged["OldSeven"] == nil, "the answer replaces that provider's cached set")
        #expect(merged["OldBttv"] != nil, "the provider still out keeps its cached set")
    }

    @Test("a part-way table is held back when cached entries can't be attributed to the provider still out")
    func unattributablePendingProviderHoldsPublish() {
        let providers: [any EmoteProvider] = [CountingProvider(returning: []), CountingProvider(returning: [])]
        let stale: [String: Emote] = ["Old": emote("Old", owner: "1")]

        #expect(EmoteIndex.interimChannelSets(
            fetched: [[emote("New", owner: "1")], []],
            pending: [1], failed: [], providers: providers, stale: stale) == nil)
        // Nothing cached to lose, or nothing still out: publish.
        #expect(EmoteIndex.interimChannelSets(
            fetched: [[emote("New", owner: "1")], []],
            pending: [1], failed: [], providers: providers, stale: nil) != nil)
        #expect(EmoteIndex.interimChannelSets(
            fetched: [[emote("New", owner: "1")], []],
            pending: [], failed: [], providers: providers, stale: stale) != nil)
    }
}
