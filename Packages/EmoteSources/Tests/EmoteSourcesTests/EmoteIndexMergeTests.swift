import Foundation
import Testing
import Core
@testable import EmoteSources

/// Provider stub with independently scripted global/channel results and an
/// optional per-scope delay, used to force completion order in
/// merge-precedence tests. With the single 6-task fetch group, results merge
/// in completion order — these tests pin down that precedence is data-driven
/// (channel > global; 7TV > BTTV > FFZ) regardless of which fetch lands first.
final class ScriptedProvider: EmoteProvider {
    private let global: [Emote]
    private let channel: [Emote]
    private let globalDelay: Duration?
    private let channelDelay: Duration?
    /// Per-instance so several `ScriptedProvider`s standing in for different
    /// providers don't share one `GlobalEmoteCatalog` entry.
    let globalCatalogKey = "scripted-\(UUID().uuidString)"

    init(
        global: [Emote] = [],
        channel: [Emote] = [],
        globalDelay: Duration? = nil,
        channelDelay: Duration? = nil
    ) {
        self.global = global
        self.channel = channel
        self.globalDelay = globalDelay
        self.channelDelay = channelDelay
    }

    func globalEmotes() async throws -> [Emote] {
        if let globalDelay { try await Task.sleep(for: globalDelay) }
        return global
    }

    func channelEmotes(broadcasterId: String, broadcasterLogin: String) async throws -> [Emote] {
        if let channelDelay { try await Task.sleep(for: channelDelay) }
        return channel
    }
}

@Suite("EmoteIndex merge precedence")
struct EmoteIndexMergeTests {

    private func tempCache() -> JSONDiskCache {
        JSONDiskCache(
            subdirectory: "ch",
            baseDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("emoteindex-merge-tests-\(UUID().uuidString)", isDirectory: true))
    }

    private func emote(
        _ name: String,
        source: Emote.Source,
        ownerChannelId: String? = nil
    ) -> Emote {
        Emote(
            id: "\(source):\(name):\(ownerChannelId ?? "global")",
            name: name,
            urls: [.x1: URL(string: "https://cdn/\(name)")!],
            isAnimated: false, isZeroWidth: false,
            source: source, ownerChannelId: ownerChannelId)
    }

    @Test("channel emote beats same-name global even when the channel result arrives first")
    func channelBeatsGlobalRegardlessOfArrivalOrder() async throws {
        // Channel FFZ emote vs global 7TV emote of the same name. Scope must
        // beat source rank (FFZ is the lowest-priority source, 7TV the
        // highest). The global fetch is delayed so the channel result is
        // merged first — the late-arriving global must NOT displace it.
        let provider = ScriptedProvider(
            global: [emote("Clash", source: .sevenTV)],
            channel: [emote("Clash", source: .ffz, ownerChannelId: "123")],
            globalDelay: .milliseconds(50))
        let index = EmoteIndex(providers: [provider], cache: tempCache())

        await index.load(broadcasterId: "123", broadcasterLogin: "x")

        let winner = try #require(index.snapshot()["Clash"])
        #expect(winner.ownerChannelId == "123")
        #expect(winner.source == .ffz)
    }

    @Test("global emote does not displace an earlier-loaded channel emote, and vice versa")
    func globalNeverDisplacesChannel() async throws {
        // Mirror case: channel fetch is the slow one, so the global merges
        // first and the channel emote must replace it on arrival.
        let provider = ScriptedProvider(
            global: [emote("Clash", source: .sevenTV)],
            channel: [emote("Clash", source: .ffz, ownerChannelId: "456")],
            channelDelay: .milliseconds(50))
        let index = EmoteIndex(providers: [provider], cache: tempCache())

        await index.load(broadcasterId: "456", broadcasterLogin: "x")

        let winner = try #require(index.snapshot()["Clash"])
        #expect(winner.ownerChannelId == "456")
    }

    @Test("within the same scope, source precedence is 7TV > BTTV > FFZ regardless of arrival order")
    func sourcePrecedenceWithinScope() async throws {
        // FFZ's global arrives first (7TV delayed); the late 7TV emote must
        // replace it. BTTV sits between to cover the full ordering.
        let sevenTV = ScriptedProvider(
            global: [emote("Rank", source: .sevenTV)],
            globalDelay: .milliseconds(50))
        let bttv = ScriptedProvider(
            global: [emote("Rank", source: .bttv)],
            globalDelay: .milliseconds(25))
        let ffz = ScriptedProvider(global: [emote("Rank", source: .ffz)])
        let index = EmoteIndex(providers: [sevenTV, bttv, ffz], cache: tempCache())

        await index.load(broadcasterId: "789", broadcasterLogin: "x")

        let winner = try #require(index.snapshot()["Rank"])
        #expect(winner.source == .sevenTV)
    }

    @Test("non-colliding global and channel emotes all land in the snapshot")
    func disjointEmotesAllPresent() async throws {
        let provider = ScriptedProvider(
            global: [emote("GlobalOnly", source: .bttv)],
            channel: [emote("ChannelOnly", source: .bttv, ownerChannelId: "321")])
        let index = EmoteIndex(providers: [provider], cache: tempCache())

        await index.load(broadcasterId: "321", broadcasterLogin: "x")

        #expect(index.snapshot()["GlobalOnly"] != nil)
        #expect(index.snapshot()["ChannelOnly"] != nil)
    }
}

@Suite("EmoteIndex compose (publish-time merge)")
struct EmoteIndexComposeTests {

    private func emote(_ name: String, source: Emote.Source, owner: String? = nil) -> Emote {
        Emote(
            id: "\(source):\(name):\(owner ?? "global")",
            name: name,
            urls: [.x1: URL(string: "https://cdn/\(name)")!],
            isAnimated: false, isZeroWidth: false,
            source: source, ownerChannelId: owner)
    }

    @Test("compose applies channel > global, then 7TV > BTTV > FFZ, independent of set order")
    func composePrecedence() {
        let globals: [[Emote]] = [
            [emote("A", source: .ffz), emote("B", source: .ffz)],
            [emote("A", source: .sevenTV)],
            [emote("C", source: .sevenTV)],
        ]
        let channel: [[Emote]] = [
            [emote("C", source: .ffz, owner: "1")],
            [emote("B", source: .bttv, owner: "1"), emote("B", source: .sevenTV, owner: "1")],
        ]
        let orders: [([[Emote]], [[Emote]])] = [
            (globals, channel),
            (Array(globals.reversed()), Array(channel.reversed())),
        ]
        for (g, c) in orders {
            let merged = EmoteIndex.compose(globals: g, channel: c)
            #expect(merged["A"]?.source == .sevenTV)              // same scope: 7TV wins
            #expect(merged["B"]?.source == .sevenTV)              // channel 7TV beats channel BTTV + global FFZ
            #expect(merged["B"]?.ownerChannelId == "1")
            #expect(merged["C"]?.source == .ffz)                  // channel FFZ beats global 7TV
        }
    }
}

@Suite("EmoteIndex channel fallback on provider failure")
struct EmoteIndexChannelFallbackTests {

    private func emote(_ name: String, source: Emote.Source) -> Emote {
        Emote(
            id: "\(source):\(name)",
            name: name,
            urls: [.x1: URL(string: "https://cdn/\(name)")!],
            isAnimated: false, isZeroWidth: false,
            source: source, ownerChannelId: "123")
    }

    @Test("A failed provider keeps its own stale channel emotes; others use fresh results")
    func failedProviderFallsBackToItsStaleEntries() {
        let providers: [any EmoteProvider] = [SevenTVProvider(), BTTVProvider(), FFZProvider()]
        let stale: [String: Emote] = [
            "OldSeven": emote("OldSeven", source: .sevenTV),
            "OldBttv": emote("OldBttv", source: .bttv),
            "OldFfz": emote("OldFfz", source: .ffz),
        ]
        // 7TV answered, BTTV failed, FFZ answered with nothing.
        let fetched: [[Emote]] = [[emote("NewSeven", source: .sevenTV)], [], []]

        let sets = EmoteIndex.channelSetsWithFallback(
            fetched: fetched, failed: [1], providers: providers, stale: stale)
        let merged = EmoteIndex.compose(globals: [], channel: sets)

        #expect(merged["NewSeven"] != nil)
        #expect(merged["OldSeven"] == nil, "a successful provider's fresh set replaces its stale one")
        #expect(merged["OldBttv"] != nil, "the failed provider keeps its cached channel emotes")
        #expect(merged["OldFfz"] == nil, "a successful empty result is authoritative")
    }

    @Test("A provider's last successful result this session beats the older disk copy")
    func rememberedResultBeatsStaleDisk() {
        let providers: [any EmoteProvider] = [BTTVProvider(), FFZProvider()]
        let stale: [String: Emote] = [
            "OldBttv": emote("OldBttv", source: .bttv),
            "OldFfz": emote("OldFfz", source: .ffz),
        ]
        // Earlier pass this session: BTTV returned NewBttv, FFZ returned
        // nothing (its emotes were removed). Now both fail.
        let remembered: [Int: [Emote]] = [0: [emote("NewBttv", source: .bttv)], 1: []]

        let sets = EmoteIndex.channelSetsWithFallback(
            fetched: [[], []], failed: [0, 1], providers: providers,
            remembered: remembered, stale: stale)
        let merged = EmoteIndex.compose(globals: [], channel: sets)

        #expect(merged["NewBttv"] != nil)
        #expect(merged["OldBttv"] == nil)
        #expect(merged["OldFfz"] == nil, "a remembered empty result keeps removals removed")
    }

    @Test("No failures or no stale copy leaves the fetched sets untouched")
    func noFallbackWhenNotNeeded() {
        let providers: [any EmoteProvider] = [SevenTVProvider()]
        let fetched: [[Emote]] = [[emote("A", source: .sevenTV)]]
        #expect(EmoteIndex.channelSetsWithFallback(
            fetched: fetched, failed: [], providers: providers,
            stale: ["B": emote("B", source: .sevenTV)]) == fetched)
        #expect(EmoteIndex.channelSetsWithFallback(
            fetched: [[]], failed: [0], providers: providers, stale: nil) == [[]])
    }
}
