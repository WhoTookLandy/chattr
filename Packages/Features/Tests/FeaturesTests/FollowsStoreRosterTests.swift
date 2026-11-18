import Testing
import Foundation
import Core
import TwitchKit
@testable import Features

/// The follow roster kept on disk between launches: shown before the network
/// answers, replaced and rewritten by the load that revalidates it, and never
/// shown to another account.
///
/// The limit is a hang guard, and it counts time spent queued for the main
/// actor. The whole target runs in parallel on one simulator, and on CI that
/// wait has run to about 90 seconds before these tests get their turn.
@MainActor
@Suite("FollowsStore roster cache", .timeLimit(.minutes(5)))
struct FollowsStoreRosterTests {

    @Test("The cached roster is shown before the network answers, and stays up until the revalidating load swaps the new list in")
    func cachedRosterShownFirst() async throws {
        let fakes = FollowsFakes()
        try fakes.script(roster: ["c1", "c2"], for: "a")
        let dependencies = fakes.dependencies(gating: [.channelPage])
        let store = FollowsStore()

        let load = Task { await store.loadAllIfNeeded(accountUserId: "a", dependencies: dependencies) }
        await fakes.channelPages.entries(1)

        // Nothing has come back from Helix yet.
        #expect(store.channels.map(\.broadcasterId) == ["c1", "c2"])
        #expect(store.sortedAllChannels.map(\.broadcasterId) == ["c1", "c2"])
        #expect(store.followedChannelIds == Set(["c1", "c2"]))
        #expect(store.profileImageURLs["c1"] == FollowsFixtures.profileImageURL("c1"))
        #expect(store.allLoadState == .loading)

        // Revalidation is a refresh: its first page doesn't replace the roster.
        let firstPage = try FollowsFixtures.channelPage(["c2"], next: "p2", total: 2)
        fakes.channelPages.resume(.success(firstPage))
        await fakes.channelPages.entries(2)
        #expect(store.channels.map(\.broadcasterId) == ["c1", "c2"])

        let lastPage = try FollowsFixtures.channelPage(["c3"], total: 2)
        fakes.channelPages.resume(.success(lastPage))
        await load.value
        #expect(store.channels.map(\.broadcasterId) == ["c2", "c3"])
        #expect(store.allLoadState == .loaded)
    }

    @Test("A successful load replaces the cached roster and rewrites it, with the profile images it fetched")
    func successfulLoadRewritesRoster() async throws {
        let fakes = FollowsFakes()
        try fakes.script(roster: ["c1", "c2"], for: "a")
        try fakes.script(channels: ["c2", "c3"], for: "a")
        let store = FollowsStore()

        await store.loadAllIfNeeded(accountUserId: "a", dependencies: fakes.dependencies())
        await store.rosterSaveTask?.value

        #expect(store.channels.map(\.broadcasterId) == ["c2", "c3"])
        let roster = try FollowsFixtures.roster(["c2", "c3"])
        #expect(fakes.snapshot().rosterSaves == [FollowsFakes.SavedRoster(accountUserId: "a", roster: roster)])
    }

    @Test("A pull-to-refresh rewrites the roster too")
    func refreshRewritesRoster() async throws {
        let fakes = FollowsFakes()
        try fakes.script(channels: ["c1"], for: "a")
        let dependencies = fakes.dependencies()
        let store = FollowsStore()
        await store.loadAllIfNeeded(accountUserId: "a", dependencies: dependencies)
        await store.rosterSaveTask?.value

        try fakes.script(channels: ["c1", "c2"], for: "a")
        await store.refreshAll(accountUserId: "a", dependencies: dependencies)
        await store.rosterSaveTask?.value

        let saved = fakes.snapshot().rosterSaves
        #expect(saved.count == 2)
        #expect(saved.last?.roster.channels.map(\.broadcasterId) == ["c1", "c2"])
        #expect(saved.last?.roster.profileImageURLs.keys.sorted() == ["c1", "c2"])
    }

    @Test("A failed load keeps showing the cached roster, leaves the cache alone, and is retried")
    func failedLoadKeepsCachedRoster() async throws {
        let fakes = FollowsFakes()
        try fakes.script(roster: ["c1", "c2"], for: "a")
        let gated = fakes.dependencies(gating: [.channelPage])
        let store = FollowsStore()

        let load = Task { await store.loadAllIfNeeded(accountUserId: "a", dependencies: gated) }
        await fakes.channelPages.entries(1)
        fakes.channelPages.resume(.failure(FollowsFixtures.RequestFailed()))
        await load.value

        #expect(store.channels.map(\.broadcasterId) == ["c1", "c2"])
        #expect(store.profileImageURLs["c2"] == FollowsFixtures.profileImageURL("c2"))
        #expect(store.allLoadState == .failed)
        #expect(fakes.snapshot().rosterSaves.isEmpty)

        // A cached roster is not a completed load: the next caller fetches.
        try fakes.script(channels: ["c2"], for: "a")
        await store.loadAllIfNeeded(accountUserId: "a", dependencies: fakes.dependencies())
        #expect(fakes.snapshot().channelRequests == ["a", "a"])
        #expect(store.channels.map(\.broadcasterId) == ["c2"])
        #expect(store.allLoadState == .loaded)
    }

    @Test("Each account reads its own roster")
    func rosterIsKeyedByAccount() async throws {
        let fakes = FollowsFakes()
        try fakes.script(roster: ["a1", "a2"], for: "a")
        let dependencies = fakes.dependencies(gating: [.channelPage])
        let store = FollowsStore()

        let load = Task { await store.loadAllIfNeeded(accountUserId: "b", dependencies: dependencies) }
        await fakes.channelPages.entries(1)
        #expect(store.channels.isEmpty)
        #expect(store.profileImageURLs.isEmpty)
        #expect(fakes.snapshot().rosterLoads == ["b"])

        let page = try FollowsFixtures.channelPage([])
        fakes.channelPages.resume(.success(page))
        await load.value
    }

    @Test("Another account's roster is never shown: one read before an account switch is dropped when it arrives")
    func rosterReadBeforeSwitchIsDropped() async throws {
        let fakes = FollowsFakes()
        try fakes.script(channels: ["a1", "a2"], for: "a")
        let gated = fakes.dependencies(gating: [.rosterLoad])
        let store = FollowsStore()

        let loadA = Task { await store.loadAllIfNeeded(accountUserId: "a", dependencies: gated) }
        await fakes.rosterLoads.entries(1)

        // Switched to B while A's roster is being read.
        await store.refreshLive(accountUserId: "b", dependencies: fakes.dependencies())
        let roster = try FollowsFixtures.roster(["a1", "a2"])
        fakes.rosterLoads.resume(.success(roster))
        await loadA.value

        #expect(store.channels.isEmpty)
        #expect(store.sortedAllChannels.isEmpty)
        #expect(store.profileImageURLs.isEmpty)
        #expect(fakes.snapshot().channelRequests.isEmpty)
    }

    @Test("A load that got ahead of the disk read is not overwritten by the roster")
    func rosterDoesNotOverwriteNewerLoad() async throws {
        let fakes = FollowsFakes()
        try fakes.script(channels: ["n1"], for: "a")
        let gated = fakes.dependencies(gating: [.rosterLoad])
        let store = FollowsStore()

        let load = Task { await store.loadAllIfNeeded(accountUserId: "a", dependencies: gated) }
        await fakes.rosterLoads.entries(1)

        await store.refreshAll(accountUserId: "a", dependencies: fakes.dependencies())
        #expect(store.channels.map(\.broadcasterId) == ["n1"])

        let roster = try FollowsFixtures.roster(["old1", "old2"])
        fakes.rosterLoads.resume(.success(roster))
        await load.value
        #expect(store.channels.map(\.broadcasterId) == ["n1"])
        #expect(store.profileImageURLs["old1"] == nil)
    }
}

/// `FollowsRoster` through the real `JSONDiskCache`, in a temp directory.
@Suite("FollowsRosterCache")
struct FollowsRosterCacheTests {

    /// Fresh unique temp directory per test — never touches the real Caches dir.
    private func tempBase() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("follows-roster-tests-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("A saved roster reads back equal, for its own account only")
    func roundTrip() async throws {
        let cache = FollowsRosterCache(cache: JSONDiskCache(subdirectory: "t", baseDirectory: tempBase()))
        let roster = try FollowsFixtures.roster(["c1", "c2"])
        await cache.save(roster, forAccountUserId: "a")

        let own = await cache.load(forAccountUserId: "a")
        let other = await cache.load(forAccountUserId: "b")
        #expect(own == roster)
        #expect(other == nil)
    }

    @Test("A roster past its maximum age is a miss")
    func tooOldIsAMiss() async throws {
        let base = tempBase()
        let cache = FollowsRosterCache(cache: JSONDiskCache(subdirectory: "t", baseDirectory: base))
        let roster = try FollowsFixtures.roster(["c1"])
        await cache.save(roster, forAccountUserId: "a")

        let url = base.appendingPathComponent("t", isDirectory: true)
            .appendingPathComponent(FollowsRosterCache.key(forAccountUserId: "a"))
            .appendingPathExtension("json")
        let old = Date().addingTimeInterval(-(FollowsRosterCache.maxAge + 3600))
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)

        let hit = await cache.load(forAccountUserId: "a")
        #expect(hit == nil)
    }

    @Test("An unreadable file is a miss")
    func corruptIsAMiss() async throws {
        let base = tempBase()
        let cache = FollowsRosterCache(cache: JSONDiskCache(subdirectory: "t", baseDirectory: base))
        let directory = base.appendingPathComponent("t", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory
            .appendingPathComponent(FollowsRosterCache.key(forAccountUserId: "a"))
            .appendingPathExtension("json")
        try Data("not json".utf8).write(to: url)

        let hit = await cache.load(forAccountUserId: "a")
        #expect(hit == nil)
    }
}
