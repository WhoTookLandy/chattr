import Testing
import Foundation
import Observation
import os
import TwitchKit
@testable import Features

// MARK: - Test doubles

/// Scripted Helix behind `ChannelStatusStore.Dependencies`. A call listed in
/// `gating` parks on its gate until the test resumes it; the others answer
/// at once. All calls are recorded.
private struct ChannelStatusFakes: Sendable {
    enum Call: Sendable {
        case streamsPage, latestArchivePage
    }

    struct State: Sendable {
        /// The channel ids of each request, sorted (the store asks for a set).
        var streamRequests: [[String]] = []
        var infoRequests: [[String]] = []
        var archiveRequests: [String] = []
        /// Which channels an ungated `/streams` call reports live.
        var liveChannelIds: Set<String> = []
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    let streamPages = HelixRequestGate<HelixPage<TwitchStream>>()
    let archivePages = HelixRequestGate<HelixPage<TwitchVideo>>()
    let state = OSAllocatedUnfairLock(initialState: State())

    func dependencies(gating: Set<Call> = []) -> ChannelStatusStore.Dependencies {
        ChannelStatusStore.Dependencies(
            streamsPage: { _, channelIds in
                state.withLock { $0.streamRequests.append(channelIds.sorted()) }
                if gating.contains(.streamsPage) { return try await streamPages.wait() }
                let live = state.withLock { $0.liveChannelIds }
                return try FollowsFixtures.streamPage(channelIds.filter { live.contains($0) })
            },
            channelsInfo: { _, channelIds in
                state.withLock { $0.infoRequests.append(channelIds.sorted()) }
                return try channelIds.map { try Self.channelInfo($0) }
            },
            latestArchivePage: { _, channelId in
                state.withLock { $0.archiveRequests.append(channelId) }
                if gating.contains(.latestArchivePage) { return try await archivePages.wait() }
                return HelixPage(data: [])
            },
            now: { state.withLock { $0.now } }
        )
    }

    func advanceClock(by seconds: TimeInterval) {
        state.withLock { $0.now = $0.now.addingTimeInterval(seconds) }
    }

    func snapshot() -> State {
        state.withLock { $0 }
    }

    var now: Date { state.withLock { $0.now } }

    private static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(json.utf8))
    }

    /// `TwitchChannel` from JSON shaped like the already-camelCased model.
    static func channelInfo(_ id: String) throws -> TwitchChannel {
        try decode(TwitchChannel.self, """
        {
          "broadcasterId": "\(id)", "broadcasterLogin": "login-\(id)",
          "broadcasterName": "Name-\(id)", "title": "Title \(id)",
          "gameName": "Chess", "gameId": "743", "tags": [],
          "broadcasterLanguage": "en"
        }
        """)
    }

    /// An archived broadcast of `channelId` that started at `createdAt`
    /// (ISO 8601) and ran for `duration` (Twitch's "1h30m0s" form).
    static func archivePage(channelId: String, createdAt: String, duration: String) throws -> HelixPage<TwitchVideo> {
        let video = try decode(TwitchVideo.self, """
        {
          "id": "v1", "userId": "\(channelId)", "userLogin": "login-\(channelId)",
          "userName": "Name-\(channelId)", "title": "vod", "description": "",
          "createdAt": "\(createdAt)", "publishedAt": "\(createdAt)",
          "url": "https://www.twitch.tv/videos/1", "thumbnailUrl": "https://x/thumb-%{width}x%{height}.jpg",
          "viewable": "public", "viewCount": 3, "language": "en",
          "type": "archive", "duration": "\(duration)"
        }
        """)
        return HelixPage(data: [video])
    }
}

// MARK: - Tests

/// `ChannelStatusStore` driven through its `Dependencies` seam.
///
/// The limit is a hang guard, and it counts time spent queued for the main
/// actor. The whole target runs in parallel on one simulator, and on CI that
/// wait has run to about 90 seconds before these tests get their turn.
@MainActor
@Suite("ChannelStatusStore", .timeLimit(.minutes(5)))
struct ChannelStatusStoreTests {

    /// Runs `trigger`, then suspends until `store.statuses` next changes.
    private func statusesChange(of store: ChannelStatusStore, after trigger: () -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            withObservationTracking {
                _ = store.statuses
            } onChange: {
                continuation.resume()
            }
            trigger()
        }
    }

    @Test("A refresh records live channels as live and offline ones with their channel info")
    func refreshFillsStatuses() async throws {
        let fakes = ChannelStatusFakes()
        fakes.state.withLock { $0.liveChannelIds = ["live1"] }
        let store = ChannelStatusStore()

        await store.refresh(
            channelIds: ["live1", "off1"], accountUserId: "a",
            dependencies: fakes.dependencies(), includeLastLive: false
        )

        #expect(store.statuses["live1"]?.stream?.userId == "live1")
        #expect(store.statuses["live1"]?.channelInfo == nil)
        #expect(store.statuses["live1"]?.fetchedAt == fakes.now)
        #expect(store.statuses["off1"]?.isLive == false)
        #expect(store.statuses["off1"]?.channelInfo?.title == "Title off1")
        let calls = fakes.snapshot()
        #expect(calls.streamRequests == [["live1", "off1"]])
        #expect(calls.infoRequests == [["off1"]])
        #expect(calls.archiveRequests.isEmpty)
    }

    @Test("Stream state younger than 60 seconds is not refetched unless forced")
    func refreshIsThrottledPerChannel() async throws {
        let fakes = ChannelStatusFakes()
        let dependencies = fakes.dependencies()
        let store = ChannelStatusStore()

        await store.refresh(channelIds: ["c1"], accountUserId: "a", dependencies: dependencies, includeLastLive: false)
        fakes.advanceClock(by: 59)
        // Only the channel with no state yet is due.
        await store.refresh(channelIds: ["c1", "c2"], accountUserId: "a", dependencies: dependencies, includeLastLive: false)
        #expect(fakes.snapshot().streamRequests == [["c1"], ["c2"]])

        // c1 is now 60 seconds old; c2 one second.
        fakes.advanceClock(by: 1)
        await store.refresh(channelIds: ["c1", "c2"], accountUserId: "a", dependencies: dependencies, includeLastLive: false)
        #expect(fakes.snapshot().streamRequests == [["c1"], ["c2"], ["c1"]])

        await store.refresh(
            channelIds: ["c1", "c2"], accountUserId: "a", dependencies: dependencies,
            includeLastLive: false, force: true
        )
        #expect(fakes.snapshot().streamRequests == [["c1"], ["c2"], ["c1"], ["c1", "c2"]])
    }

    @Test("A refresh that replaces a cancelled one fetches its channels at once, and the cancelled one writes nothing")
    func cancelledRefreshReleasesItsClaim() async throws {
        let fakes = ChannelStatusFakes()
        let gated = fakes.dependencies(gating: [.streamsPage])
        let store = ChannelStatusStore()

        let first = Task {
            await store.refresh(channelIds: ["c1"], accountUserId: "a", dependencies: gated, includeLastLive: false)
        }
        await fakes.streamPages.entries(1)

        // While that one is in flight its channel is claimed.
        await store.refresh(channelIds: ["c1"], accountUserId: "a", dependencies: gated, includeLastLive: false)
        #expect(fakes.streamPages.entered == 1)

        // Cancelled (the open set changed): the claim goes with it, before
        // the request has unwound.
        first.cancel()
        let second = Task {
            await store.refresh(channelIds: ["c1"], accountUserId: "a", dependencies: gated, includeLastLive: false)
        }
        await fakes.streamPages.entries(2)

        let livePage = try FollowsFixtures.streamPage(["c1"])
        fakes.streamPages.resume(.success(livePage))
        await first.value
        #expect(store.statuses["c1"] == nil)

        let offlinePage = try FollowsFixtures.streamPage([])
        fakes.streamPages.resume(.success(offlinePage))
        await second.value
        #expect(store.statuses["c1"]?.isLive == false)
        #expect(store.statuses["c1"]?.channelInfo?.title == "Title c1")
    }

    @Test("A last-live lookup records when the latest broadcast ended, and isn't repeated for 30 minutes")
    func lastLiveLookup() async throws {
        let fakes = ChannelStatusFakes()
        let gated = fakes.dependencies(gating: [.latestArchivePage])
        let store = ChannelStatusStore()

        store.ensureLastLive(channelId: "off1", accountUserId: "a", dependencies: gated)
        await fakes.archivePages.entries(1)

        let page = try ChannelStatusFakes.archivePage(
            channelId: "off1", createdAt: "2026-06-12T14:00:00Z", duration: "1h30m0s"
        )
        await statusesChange(of: store) {
            fakes.archivePages.resume(.success(page))
        }
        let started = try #require(page.data.first?.createdAt)
        #expect(store.statuses["off1"]?.lastLiveAt == started.addingTimeInterval(90 * 60))
        #expect(store.statuses["off1"]?.lastLiveTitle == "vod")
        #expect(store.statuses["off1"]?.lastLiveThumbnailURL == "https://x/thumb-%{width}x%{height}.jpg")
        #expect(store.statuses["off1"]?.isLive == false)
        // The stream state is still unknown, so the next `refresh` fetches it.
        #expect(store.statuses["off1"]?.fetchedAt == Date.distantPast)

        // Asked again at once, and just short of 30 minutes later: no lookup.
        store.ensureLastLive(channelId: "off1", accountUserId: "a", dependencies: gated)
        fakes.advanceClock(by: 30 * 60 - 1)
        store.ensureLastLive(channelId: "off1", accountUserId: "a", dependencies: gated)
        for _ in 0..<50 { await Task.yield() }
        #expect(fakes.archivePages.entered == 1)

        fakes.advanceClock(by: 1)
        store.ensureLastLive(channelId: "off1", accountUserId: "a", dependencies: gated)
        await fakes.archivePages.entries(2)
        #expect(fakes.snapshot().archiveRequests == ["off1", "off1"])
        fakes.archivePages.resume(.success(page))
    }

    @Test("A channel known to be live is not looked up")
    func liveChannelIsNotLookedUp() async throws {
        let fakes = ChannelStatusFakes()
        fakes.state.withLock { $0.liveChannelIds = ["live1"] }
        let gated = fakes.dependencies(gating: [.latestArchivePage])
        let store = ChannelStatusStore()

        // Offline channels of a refresh are looked up; live ones are not.
        await store.refresh(channelIds: ["live1", "off1"], accountUserId: "a", dependencies: gated)
        await fakes.archivePages.entries(1)
        store.ensureLastLive(channelId: "live1", accountUserId: "a", dependencies: gated)
        for _ in 0..<50 { await Task.yield() }

        #expect(fakes.snapshot().archiveRequests == ["off1"])
        let empty: HelixPage<TwitchVideo> = HelixPage(data: [])
        fakes.archivePages.resume(.success(empty))
    }
}
