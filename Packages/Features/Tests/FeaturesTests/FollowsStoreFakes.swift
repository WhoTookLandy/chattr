import Foundation
import os
import TwitchKit
@testable import Features

/// A suspension point the test controls: each `wait()` parks until the test
/// resumes it. Deliberately ignores task cancellation, to model a response
/// that was already on the wire when the cancel landed — the race the
/// stores have to survive.
final class HelixRequestGate<Value: Sendable>: Sendable {
    private struct State: Sendable {
        var waiters: [CheckedContinuation<Value, any Error>] = []
        var entered = 0
        var entryWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// How many times `wait()` has been entered.
    var entered: Int { state.withLock { $0.entered } }

    func wait() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let ready = state.withLock { state -> [CheckedContinuation<Void, Never>] in
                state.waiters.append(continuation)
                state.entered += 1
                let entered = state.entered
                let ready = state.entryWaiters.filter { $0.count <= entered }.map(\.continuation)
                state.entryWaiters.removeAll { $0.count <= entered }
                return ready
            }
            ready.forEach { $0.resume() }
        }
    }

    /// Suspends until `wait()` has been entered at least `count` times.
    func entries(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let already = state.withLock { state -> Bool in
                if state.entered >= count { return true }
                state.entryWaiters.append((count, continuation))
                return false
            }
            if already { continuation.resume() }
        }
    }

    /// Resumes the oldest parked `wait()`.
    func resume(_ result: Result<Value, any Error>) {
        let waiter = state.withLock { state -> CheckedContinuation<Value, any Error>? in
            state.waiters.isEmpty ? nil : state.waiters.removeFirst()
        }
        waiter?.resume(with: result)
    }
}

/// TwitchKit models for the follows tests. They are Decodable-only (or have
/// no public initializer), so each is decoded from JSON shaped like the
/// already-camelCased model.
enum FollowsFixtures {
    struct RequestFailed: Error {}

    private static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(json.utf8))
    }

    static func channel(_ id: String) throws -> FollowedChannel {
        try decode(FollowedChannel.self, """
        {
          "broadcasterId": "\(id)", "broadcasterLogin": "login-\(id)",
          "broadcasterName": "Name-\(id)", "followedAt": "2026-01-02T03:04:05Z"
        }
        """)
    }

    static func channels(_ ids: [String]) throws -> [FollowedChannel] {
        try ids.map { try channel($0) }
    }

    /// A page of `ids`; `next` is the cursor of the page after it, if any.
    static func channelPage(_ ids: [String], next: String? = nil, total: Int? = nil) throws -> HelixPage<FollowedChannel> {
        let data = try channels(ids)
        return HelixPage(data: data, pagination: next.map { Pagination(cursor: $0) }, total: total)
    }

    static func stream(_ userId: String, viewers: Int = 10) throws -> TwitchStream {
        try decode(TwitchStream.self, """
        {
          "id": "stream-\(userId)", "userId": "\(userId)", "userLogin": "login-\(userId)",
          "userName": "Name-\(userId)", "gameId": "509658", "gameName": "Just Chatting",
          "type": "live", "title": "hello", "tags": [], "viewerCount": \(viewers),
          "startedAt": "2026-06-12T14:02:11Z", "language": "en",
          "thumbnailUrl": "https://x/live_user_\(userId)-{width}x{height}.jpg",
          "isMature": false
        }
        """)
    }

    static func streamPage(_ userIds: [String], next: String? = nil) throws -> HelixPage<TwitchStream> {
        let data = try userIds.map { try stream($0) }
        return HelixPage(data: data, pagination: next.map { Pagination(cursor: $0) })
    }

    static func user(_ id: String) throws -> TwitchUser {
        try decode(TwitchUser.self, """
        {
          "id": "\(id)", "login": "login-\(id)", "displayName": "Name-\(id)",
          "profileImageUrl": "\(profileImageURL(id).absoluteString)", "broadcasterType": ""
        }
        """)
    }

    /// The profile image `user(_:)` reports for `id`.
    static func profileImageURL(_ id: String) -> URL {
        URL(string: "https://img.test/\(id).png")!
    }

    /// `ids` in order, each with the profile image `user(_:)` reports.
    static func roster(_ ids: [String]) throws -> FollowsRoster {
        let followed = try channels(ids)
        let images = Dictionary(uniqueKeysWithValues: ids.map { ($0, profileImageURL($0)) })
        return FollowsRoster(channels: followed, profileImageURLs: images)
    }
}

/// Scripted Helix and roster cache behind `FollowsStore.Dependencies`.
///
/// A call listed in `gating` parks on its gate until the test resumes it;
/// every other call answers at once from `State`. All calls are recorded.
struct FollowsFakes: Sendable {
    enum Call: Sendable {
        case channelPage, streamPage, rosterLoad
    }

    struct State: Sendable {
        /// The account each channel-page request was for, with its cursor.
        var channelRequests: [String] = []
        var channelCursors: [String?] = []
        var streamRequests: [String] = []
        var userRequests: [[String]] = []
        var rosterLoads: [String] = []
        /// (accountUserId, roster) per save, oldest first.
        var rosterSaves: [SavedRoster] = []

        /// Ungated answers, by account: one page holding all of it.
        var channels: [String: [FollowedChannel]] = [:]
        var streams: [String: [TwitchStream]] = [:]
        var rosters: [String: FollowsRoster] = [:]

        var now: ContinuousClock.Instant = .now
    }

    struct SavedRoster: Sendable, Equatable {
        var accountUserId: String
        var roster: FollowsRoster
    }

    let channelPages = HelixRequestGate<HelixPage<FollowedChannel>>()
    let streamPages = HelixRequestGate<HelixPage<TwitchStream>>()
    let rosterLoads = HelixRequestGate<FollowsRoster?>()
    let state = OSAllocatedUnfairLock(initialState: State())

    func dependencies(gating: Set<Call> = []) -> FollowsStore.Dependencies {
        FollowsStore.Dependencies(
            followedChannelsPage: { accountUserId, cursor in
                state.withLock {
                    $0.channelRequests.append(accountUserId)
                    $0.channelCursors.append(cursor)
                }
                if gating.contains(.channelPage) { return try await channelPages.wait() }
                let channels = state.withLock { $0.channels[accountUserId] ?? [] }
                return HelixPage(data: channels, total: channels.count)
            },
            followedStreamsPage: { accountUserId, _ in
                state.withLock { $0.streamRequests.append(accountUserId) }
                if gating.contains(.streamPage) { return try await streamPages.wait() }
                let streams = state.withLock { $0.streams[accountUserId] ?? [] }
                return HelixPage(data: streams)
            },
            users: { _, ids in
                state.withLock { $0.userRequests.append(ids) }
                return try ids.map { try FollowsFixtures.user($0) }
            },
            loadRoster: { accountUserId in
                state.withLock { $0.rosterLoads.append(accountUserId) }
                if gating.contains(.rosterLoad) { return try? await rosterLoads.wait() }
                return state.withLock { $0.rosters[accountUserId] }
            },
            saveRoster: { accountUserId, roster in
                state.withLock {
                    $0.rosterSaves.append(SavedRoster(accountUserId: accountUserId, roster: roster))
                }
            },
            now: { state.withLock { $0.now } }
        )
    }

    /// What ungated calls answer for `accountUserId`.
    func script(channels ids: [String], for accountUserId: String) throws {
        let channels = try FollowsFixtures.channels(ids)
        state.withLock { $0.channels[accountUserId] = channels }
    }

    func script(streams userIds: [String], for accountUserId: String) throws {
        let streams = try userIds.map { try FollowsFixtures.stream($0) }
        state.withLock { $0.streams[accountUserId] = streams }
    }

    func script(roster ids: [String], for accountUserId: String) throws {
        let roster = try FollowsFixtures.roster(ids)
        state.withLock { $0.rosters[accountUserId] = roster }
    }

    /// Moves the injected clock forward.
    func advanceClock(by duration: Duration) {
        state.withLock { $0.now = $0.now.advanced(by: duration) }
    }

    func snapshot() -> State {
        state.withLock { $0 }
    }
}
