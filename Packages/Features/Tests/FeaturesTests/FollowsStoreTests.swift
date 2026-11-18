import Testing
import Foundation
import TwitchKit
@testable import Features

/// `FollowsStore` driven through its `Dependencies` seam: the account-switch
/// interleavings its entry points fence against, and the refresh rules
/// (swap once, progressive first load, coalescing, the live throttle).
///
/// Requests park on gates the test resumes, so every interleaving is driven
/// in order rather than by timing. Where two calls must land in the gap
/// between a load being queued and starting, they are queued back to back:
/// tasks created from the main actor start in creation order.
///
/// The limit is a hang guard, and it counts time spent queued for the main
/// actor. The whole target runs in parallel on one simulator, and on CI that
/// wait has run to about 90 seconds before these tests get their turn.
@MainActor
@Suite("FollowsStore (account switches, refresh, throttle)", .timeLimit(.minutes(5)))
struct FollowsStoreTests {

    // MARK: - Account switches

    @Test("A cancelled caller never switches the store's account")
    func cancelledCallerDoesNotSwitchAccounts() async throws {
        let fakes = FollowsFakes()
        try fakes.script(channels: ["a1", "a2"], for: "a")
        try fakes.script(channels: ["b1"], for: "b")
        let dependencies = fakes.dependencies()
        let store = FollowsStore()
        await store.loadAllIfNeeded(accountUserId: "a", dependencies: dependencies)
        #expect(store.channels.map(\.broadcasterId) == ["a1", "a2"])

        // A torn-down `.task` handing over another account: cancelled before
        // it gets to run.
        let caller = Task { await store.loadAllIfNeeded(accountUserId: "b", dependencies: dependencies) }
        caller.cancel()
        await caller.value

        #expect(store.channels.map(\.broadcasterId) == ["a1", "a2"])
        #expect(store.allLoadState == .loaded)
        #expect(fakes.snapshot().channelRequests == ["a"])
    }

    @Test("A full load cancelled before it starts never runs the account switch")
    func loadCancelledBeforeStartDoesNotSwitchBack() async throws {
        let fakes = FollowsFakes()
        try fakes.script(channels: ["a1"], for: "a")
        let dependencies = fakes.dependencies(gating: [.streamPage])
        let store = FollowsStore()

        // The load switches to A and queues its task; the live refresh then
        // switches to B, cancelling that task before it has run.
        let loadA = Task { await store.loadAllIfNeeded(accountUserId: "a", dependencies: dependencies) }
        let liveB = Task { await store.refreshLive(accountUserId: "b", dependencies: dependencies) }
        await fakes.streamPages.entries(1)
        await loadA.value

        // Had A's task switched the store back, it would have cancelled B's
        // refresh, reset its state and fetched A's list.
        let page = try FollowsFixtures.streamPage(["b-live"])
        fakes.streamPages.resume(.success(page))
        await liveB.value

        #expect(store.liveStreamsOrdered.map(\.userId) == ["b-live"])
        #expect(store.liveLoadState == .loaded)
        #expect(store.channels.isEmpty)
        #expect(fakes.snapshot().channelRequests.isEmpty)
    }

    @Test("Account switches invalidate in-flight full loads: an A → B → A round trip can neither commit the old load nor be joined to it")
    func accountSwitchInvalidatesInFlightLoad() async throws {
        let fakes = FollowsFakes()
        let dependencies = fakes.dependencies(gating: [.channelPage])
        let store = FollowsStore()

        let first = Task { await store.loadAllIfNeeded(accountUserId: "a", dependencies: dependencies) }
        await fakes.channelPages.entries(1)

        // Switched away and back by the live path while A's page is on the wire.
        await store.refreshLive(accountUserId: "b", dependencies: dependencies)
        await store.refreshLive(accountUserId: "a", dependencies: dependencies)

        // A new caller starts A afresh instead of joining the dead load.
        let second = Task { await store.loadAllIfNeeded(accountUserId: "a", dependencies: dependencies) }
        await fakes.channelPages.entries(2)

        // The dead load's response lands late and must not commit.
        let stale = try FollowsFixtures.channelPage(["stale"])
        fakes.channelPages.resume(.success(stale))
        await first.value
        #expect(store.channels.isEmpty)
        #expect(store.allLoadState == .loading)

        let fresh = try FollowsFixtures.channelPage(["fresh"])
        fakes.channelPages.resume(.success(fresh))
        await second.value
        #expect(store.channels.map(\.broadcasterId) == ["fresh"])
        #expect(store.allLoadState == .loaded)
    }

    @Test("A queued full load switches accounts synchronously, so a live refresh in the gap cancels it instead of being undone by it")
    func queuedLoadSwitchesAccountsSynchronously() async throws {
        let fakes = FollowsFakes()
        try fakes.script(streams: ["a-live"], for: "a")
        try fakes.script(channels: ["b1"], for: "b")
        let dependencies = fakes.dependencies()
        let store = FollowsStore()
        await store.refreshLive(accountUserId: "a", dependencies: dependencies)

        // B's load is queued; before its task starts, A asks for a refresh.
        // The store already belongs to B, so that is a switch back to A and
        // B's queued load is dropped. Had the switch to B waited for the
        // task, the refresh would have seen nothing to do and B's load would
        // then have wiped it.
        let loadB = Task { await store.loadAllIfNeeded(accountUserId: "b", dependencies: dependencies) }
        let liveA = Task { await store.refreshLive(accountUserId: "a", dependencies: dependencies, force: true) }
        await loadB.value
        await liveA.value

        #expect(store.liveStreamsOrdered.map(\.userId) == ["a-live"])
        #expect(store.liveLoadState == .loaded)
        #expect(store.channels.isEmpty)
        #expect(fakes.snapshot().channelRequests.isEmpty)
    }

    @Test("A stale live refresh cannot write into the account that replaced it")
    func staleLiveRefreshCannotWrite() async throws {
        let fakes = FollowsFakes()
        let dependencies = fakes.dependencies(gating: [.streamPage])
        let store = FollowsStore()

        let stale = Task { await store.refreshLive(accountUserId: "a", dependencies: dependencies) }
        await fakes.streamPages.entries(1)

        // Account switch while A's page is on the wire.
        let current = Task { await store.refreshLive(accountUserId: "b", dependencies: dependencies) }
        await fakes.streamPages.entries(2)

        let stalePage = try FollowsFixtures.streamPage(["a-live"])
        fakes.streamPages.resume(.success(stalePage))
        await stale.value
        #expect(store.liveStreamsOrdered.isEmpty)
        #expect(store.liveStreams.isEmpty)
        // Still B's refresh to finish.
        #expect(store.liveLoadState == .loading)

        let currentPage = try FollowsFixtures.streamPage(["b-live"])
        fakes.streamPages.resume(.success(currentPage))
        await current.value
        #expect(store.liveStreamsOrdered.map(\.userId) == ["b-live"])
        #expect(store.liveLoadState == .loaded)
        #expect(!fakes.snapshot().userRequests.contains(["a-live"]))
    }

    // MARK: - Refreshing a list that has rows

    @Test("A refresh keeps the existing list visible until it finishes and swaps once")
    func refreshSwapsOnce() async throws {
        let fakes = FollowsFakes()
        let dependencies = fakes.dependencies(gating: [.channelPage])
        let store = FollowsStore()

        let load = Task { await store.loadAllIfNeeded(accountUserId: "a", dependencies: dependencies) }
        await fakes.channelPages.entries(1)
        let initial = try FollowsFixtures.channelPage(["c1", "c2", "c3"], total: 3)
        fakes.channelPages.resume(.success(initial))
        await load.value
        #expect(store.channels.map(\.broadcasterId) == ["c1", "c2", "c3"])

        let refresh = Task { await store.refreshAll(accountUserId: "a", dependencies: dependencies) }
        await fakes.channelPages.entries(2)
        #expect(store.allLoadState == .loading)
        let firstPage = try FollowsFixtures.channelPage(["n1"], next: "p2", total: 4)
        fakes.channelPages.resume(.success(firstPage))
        await fakes.channelPages.entries(3)

        // One page in: counted, but the list has not shrunk to it.
        #expect(store.channels.map(\.broadcasterId) == ["c1", "c2", "c3"])
        #expect(store.sortedAllChannels.map(\.broadcasterId) == ["c1", "c2", "c3"])
        #expect(store.allLoadProgress == 1)

        let lastPage = try FollowsFixtures.channelPage(["n2", "n3", "n4"], total: 4)
        fakes.channelPages.resume(.success(lastPage))
        await refresh.value
        #expect(store.channels.map(\.broadcasterId) == ["n1", "n2", "n3", "n4"])
        #expect(store.sortedAllChannels.map(\.broadcasterId) == ["n1", "n2", "n3", "n4"])
        #expect(store.followedChannelIds == Set(["n1", "n2", "n3", "n4"]))
        #expect(store.allLoadState == .loaded)
        // The first load's one request, then the refresh's two.
        let cursors: [String?] = [nil, nil, "p2"]
        #expect(fakes.snapshot().channelCursors == cursors)
    }

    @Test("A live refresh keeps the existing streams until it finishes and swaps once")
    func liveRefreshSwapsOnce() async throws {
        let fakes = FollowsFakes()
        let dependencies = fakes.dependencies(gating: [.streamPage])
        let store = FollowsStore()

        let load = Task { await store.refreshLive(accountUserId: "a", dependencies: dependencies) }
        await fakes.streamPages.entries(1)
        let initial = try FollowsFixtures.streamPage(["s1", "s2"])
        fakes.streamPages.resume(.success(initial))
        await load.value
        #expect(store.liveStreamsOrdered.map(\.userId) == ["s1", "s2"])

        let refresh = Task { await store.refreshLive(accountUserId: "a", dependencies: dependencies, force: true) }
        await fakes.streamPages.entries(2)
        let firstPage = try FollowsFixtures.streamPage(["s3"], next: "p2")
        fakes.streamPages.resume(.success(firstPage))
        await fakes.streamPages.entries(3)
        #expect(store.liveStreamsOrdered.map(\.userId) == ["s1", "s2"])
        #expect(store.liveStreams.keys.sorted() == ["s1", "s2"])

        let lastPage = try FollowsFixtures.streamPage(["s1"])
        fakes.streamPages.resume(.success(lastPage))
        await refresh.value
        #expect(store.liveStreamsOrdered.map(\.userId) == ["s3", "s1"])
        #expect(store.liveStreams.keys.sorted() == ["s1", "s3"])
        #expect(store.liveStreamSearchKeys.keys.sorted() == ["s1", "s3"])
        #expect(store.liveLoadState == .loaded)
    }

    @Test("A failed refresh keeps the previous list and reports the failure")
    func failedRefreshKeepsList() async throws {
        let fakes = FollowsFakes()
        try fakes.script(channels: ["c1", "c2"], for: "a")
        let store = FollowsStore()
        await store.loadAllIfNeeded(accountUserId: "a", dependencies: fakes.dependencies())

        let gated = fakes.dependencies(gating: [.channelPage])
        let refresh = Task { await store.refreshAll(accountUserId: "a", dependencies: gated) }
        await fakes.channelPages.entries(1)
        fakes.channelPages.resume(.failure(FollowsFixtures.RequestFailed()))
        await refresh.value

        #expect(store.channels.map(\.broadcasterId) == ["c1", "c2"])
        #expect(store.sortedAllChannels.map(\.broadcasterId) == ["c1", "c2"])
        #expect(store.allLoadState == .failed)
        #expect(store.allErrorMessage != nil)
    }

    @Test("A cancelled refresh puts back the previous list and load state")
    func cancelledRefreshRestoresLoadState() async throws {
        let fakes = FollowsFakes()
        try fakes.script(channels: ["c1", "c2"], for: "a")
        let store = FollowsStore()
        await store.loadAllIfNeeded(accountUserId: "a", dependencies: fakes.dependencies())
        #expect(store.totalFollowed == 2)

        // Pull-to-refresh torn down mid-request.
        let gated = fakes.dependencies(gating: [.channelPage])
        let refresh = Task { await store.refreshAll(accountUserId: "a", dependencies: gated) }
        await fakes.channelPages.entries(1)
        #expect(store.allLoadState == .loading)
        refresh.cancel()
        fakes.channelPages.resume(.failure(CancellationError()))
        await refresh.value

        #expect(store.channels.map(\.broadcasterId) == ["c1", "c2"])
        #expect(store.allLoadState == .loaded)
        #expect(store.allErrorMessage == nil)
        #expect(store.totalFollowed == 2)
        #expect(store.allLoadProgress == 2)
    }

    @Test("A refresh cancelled while a page request is out does not commit that page when it answers")
    func cancelledRefreshIgnoresLateSuccess() async throws {
        let fakes = FollowsFakes()
        try fakes.script(channels: ["c1", "c2"], for: "a")
        let store = FollowsStore()
        await store.loadAllIfNeeded(accountUserId: "a", dependencies: fakes.dependencies())
        let requestsBefore = fakes.snapshot().channelRequests.count

        let gated = fakes.dependencies(gating: [.channelPage])
        let refresh = Task { await store.refreshAll(accountUserId: "a", dependencies: gated) }
        await fakes.channelPages.entries(1)
        refresh.cancel()
        // The request was already out and answers anyway, with more to come.
        fakes.channelPages.resume(.success(try FollowsFixtures.channelPage(["c9"], next: "more")))
        await refresh.value

        #expect(store.channels.map(\.broadcasterId) == ["c1", "c2"])
        #expect(store.allLoadState == .loaded)
        #expect(store.allErrorMessage == nil)
        // No second page was asked for, and the cancelled result was not saved.
        #expect(fakes.snapshot().channelRequests.count == requestsBefore + 1)
        let savedLateResult = fakes.snapshot().rosterSaves.contains { saved in
            saved.roster.channels.contains { $0.broadcasterId == "c9" }
        }
        #expect(!savedLateResult)
    }

    @Test("A failed live refresh keeps the previous streams; a cancelled one also keeps the load state")
    func failedOrCancelledLiveRefreshKeepsStreams() async throws {
        let fakes = FollowsFakes()
        try fakes.script(streams: ["s1"], for: "a")
        let store = FollowsStore()
        await store.refreshLive(accountUserId: "a", dependencies: fakes.dependencies())
        let gated = fakes.dependencies(gating: [.streamPage])

        let cancelled = Task { await store.refreshLive(accountUserId: "a", dependencies: gated, force: true) }
        await fakes.streamPages.entries(1)
        fakes.streamPages.resume(.failure(CancellationError()))
        await cancelled.value
        #expect(store.liveStreamsOrdered.map(\.userId) == ["s1"])
        #expect(store.liveLoadState == .loaded)

        let failed = Task { await store.refreshLive(accountUserId: "a", dependencies: gated, force: true) }
        await fakes.streamPages.entries(2)
        fakes.streamPages.resume(.failure(FollowsFixtures.RequestFailed()))
        await failed.value
        #expect(store.liveStreamsOrdered.map(\.userId) == ["s1"])
        #expect(store.liveLoadState == .failed)
        #expect(store.liveErrorMessage != nil)
    }

    // MARK: - First load

    @Test("The first load into an empty store appears progressively: first page at once, then at most one commit per interval, then the last page")
    func firstLoadCommitsProgressively() async throws {
        let fakes = FollowsFakes()
        let dependencies = fakes.dependencies(gating: [.channelPage])
        let store = FollowsStore()

        let load = Task { await store.loadAllIfNeeded(accountUserId: "a", dependencies: dependencies) }
        await fakes.channelPages.entries(1)
        let page1 = try FollowsFixtures.channelPage(["c1"], next: "p2", total: 4)
        fakes.channelPages.resume(.success(page1))
        await fakes.channelPages.entries(2)
        #expect(store.channels.map(\.broadcasterId) == ["c1"])
        #expect(store.totalFollowed == 4)

        // Inside the commit interval: counted, not shown yet.
        let page2 = try FollowsFixtures.channelPage(["c2"], next: "p3", total: 4)
        fakes.channelPages.resume(.success(page2))
        await fakes.channelPages.entries(3)
        #expect(store.channels.map(\.broadcasterId) == ["c1"])
        #expect(store.allLoadProgress == 2)

        // Past it: the next page commits everything fetched so far.
        fakes.advanceClock(by: .seconds(1))
        let page3 = try FollowsFixtures.channelPage(["c3"], next: "p4", total: 4)
        fakes.channelPages.resume(.success(page3))
        await fakes.channelPages.entries(4)
        #expect(store.channels.map(\.broadcasterId) == ["c1", "c2", "c3"])
        #expect(store.allLoadState == .loading)

        let page4 = try FollowsFixtures.channelPage(["c4"], total: 4)
        fakes.channelPages.resume(.success(page4))
        await load.value
        #expect(store.channels.map(\.broadcasterId) == ["c1", "c2", "c3", "c4"])
        #expect(store.allLoadState == .loaded)
        let cursors: [String?] = [nil, "p2", "p3", "p4"]
        #expect(fakes.snapshot().channelCursors == cursors)
    }

    @Test("The first live load shows each page as it arrives")
    func firstLiveLoadCommitsProgressively() async throws {
        let fakes = FollowsFakes()
        let dependencies = fakes.dependencies(gating: [.streamPage])
        let store = FollowsStore()

        let load = Task { await store.refreshLive(accountUserId: "a", dependencies: dependencies) }
        await fakes.streamPages.entries(1)
        let page1 = try FollowsFixtures.streamPage(["s1"], next: "p2")
        fakes.streamPages.resume(.success(page1))
        await fakes.streamPages.entries(2)
        #expect(store.liveStreamsOrdered.map(\.userId) == ["s1"])
        #expect(store.liveLoadState == .loading)

        let page2 = try FollowsFixtures.streamPage(["s2"])
        fakes.streamPages.resume(.success(page2))
        await load.value
        #expect(store.liveStreamsOrdered.map(\.userId) == ["s1", "s2"])
        #expect(store.liveLoadState == .loaded)
        #expect(store.liveRefreshedAt != nil)
    }

    @Test("A first load that fails part-way keeps the pages it fetched")
    func failedFirstLoadKeepsFetchedPages() async throws {
        let fakes = FollowsFakes()
        let dependencies = fakes.dependencies(gating: [.channelPage])
        let store = FollowsStore()

        let load = Task { await store.loadAllIfNeeded(accountUserId: "a", dependencies: dependencies) }
        await fakes.channelPages.entries(1)
        let page1 = try FollowsFixtures.channelPage(["c1"], next: "p2")
        fakes.channelPages.resume(.success(page1))
        await fakes.channelPages.entries(2)
        // Inside the commit interval, so this page is only in the local list
        // when the next request fails.
        let page2 = try FollowsFixtures.channelPage(["c2"], next: "p3")
        fakes.channelPages.resume(.success(page2))
        await fakes.channelPages.entries(3)
        fakes.channelPages.resume(.failure(FollowsFixtures.RequestFailed()))
        await load.value

        #expect(store.channels.map(\.broadcasterId) == ["c1", "c2"])
        #expect(store.allLoadState == .failed)
    }

    // MARK: - Coalescing and the throttle

    @Test("Concurrent full-load callers share one paginated fetch")
    func fullLoadCallersCoalesce() async throws {
        let fakes = FollowsFakes()
        let dependencies = fakes.dependencies(gating: [.channelPage])
        let store = FollowsStore()

        let first = Task { await store.loadAllIfNeeded(accountUserId: "a", dependencies: dependencies) }
        await fakes.channelPages.entries(1)

        // Answered only once this second caller is parked: a main-actor task
        // can't run before the call below suspends.
        let page = try FollowsFixtures.channelPage(["c1"])
        Task { fakes.channelPages.resume(.success(page)) }
        await store.loadAllIfNeeded(accountUserId: "a", dependencies: dependencies)
        await first.value

        #expect(fakes.snapshot().channelRequests == ["a"])
        #expect(store.channels.map(\.broadcasterId) == ["c1"])

        // Loaded: a later caller doesn't fetch again.
        await store.loadAllIfNeeded(accountUserId: "a", dependencies: dependencies)
        #expect(fakes.snapshot().channelRequests == ["a"])
    }

    @Test("Concurrent live-refresh callers share one fetch, even a forced one")
    func liveRefreshCallersCoalesce() async throws {
        let fakes = FollowsFakes()
        let dependencies = fakes.dependencies(gating: [.streamPage])
        let store = FollowsStore()

        let first = Task { await store.refreshLive(accountUserId: "a", dependencies: dependencies) }
        await fakes.streamPages.entries(1)

        let page = try FollowsFixtures.streamPage(["s1"])
        Task { fakes.streamPages.resume(.success(page)) }
        await store.refreshLive(accountUserId: "a", dependencies: dependencies, force: true)
        await first.value

        #expect(fakes.snapshot().streamRequests == ["a"])
        #expect(store.liveStreamsOrdered.map(\.userId) == ["s1"])
    }

    @Test("A live refresh within 60 seconds of the last one is skipped unless forced")
    func liveRefreshIsThrottled() async throws {
        let fakes = FollowsFakes()
        try fakes.script(streams: ["s1"], for: "a")
        let dependencies = fakes.dependencies()
        let store = FollowsStore()

        await store.refreshLive(accountUserId: "a", dependencies: dependencies)
        #expect(fakes.snapshot().streamRequests.count == 1)

        fakes.advanceClock(by: .seconds(59))
        await store.refreshLive(accountUserId: "a", dependencies: dependencies)
        #expect(fakes.snapshot().streamRequests.count == 1)

        // Explicit user intent bypasses the throttle, and restarts it.
        await store.refreshLive(accountUserId: "a", dependencies: dependencies, force: true)
        #expect(fakes.snapshot().streamRequests.count == 2)

        fakes.advanceClock(by: .seconds(59))
        await store.refreshLive(accountUserId: "a", dependencies: dependencies)
        #expect(fakes.snapshot().streamRequests.count == 2)

        fakes.advanceClock(by: .seconds(1))
        await store.refreshLive(accountUserId: "a", dependencies: dependencies)
        #expect(fakes.snapshot().streamRequests.count == 3)
    }

    @Test("A failed live refresh is not throttled: the next visit retries")
    func failedLiveRefreshIsRetried() async throws {
        let fakes = FollowsFakes()
        let gated = fakes.dependencies(gating: [.streamPage])
        let store = FollowsStore()

        let failed = Task { await store.refreshLive(accountUserId: "a", dependencies: gated) }
        await fakes.streamPages.entries(1)
        fakes.streamPages.resume(.failure(FollowsFixtures.RequestFailed()))
        await failed.value
        #expect(store.liveLoadState == .failed)

        await store.refreshLive(accountUserId: "a", dependencies: fakes.dependencies())
        #expect(fakes.snapshot().streamRequests.count == 2)
        #expect(store.liveLoadState == .loaded)
    }

    // MARK: - Derived state

    @Test("The All list sorts live channels first, busiest first, the rest in follow order")
    func sortedAllChannelsPutsLiveFirst() async throws {
        let fakes = FollowsFakes()
        try fakes.script(channels: ["c1", "c2", "c3", "c4"], for: "a")
        let quiet = try FollowsFixtures.stream("c2", viewers: 5)
        let busy = try FollowsFixtures.stream("c4", viewers: 50)
        fakes.state.withLock { $0.streams["a"] = [busy, quiet] }
        let dependencies = fakes.dependencies()
        let store = FollowsStore()

        await store.loadAllIfNeeded(accountUserId: "a", dependencies: dependencies)
        await store.refreshLive(accountUserId: "a", dependencies: dependencies)

        #expect(store.sortedAllChannels.map(\.broadcasterId) == ["c4", "c2", "c1", "c3"])
        #expect(store.sortedAllChannelSearchKeys.first == "name-c4\nlogin-c4")

        // Profile batches land after the load itself.
        await store.rosterSaveTask?.value
        #expect(store.profileImageURLs["c1"] == FollowsFixtures.profileImageURL("c1"))
    }
}
