import Testing
import Foundation
import TwitchKit
import Core
@testable import Channels

/// Lifecycle races in `ChannelSessionRegistry`'s acquire / release paths.
///
/// The registry is driven through its internal `Dependencies` seam: sessions
/// are real (never-connected) `ChannelSession`s, but `start()` / `stop()` are
/// replaced by `FakeLifecycle`, whose calls block until the test resolves
/// them. That makes "release while start is in flight" and "re-acquire while
/// stop is in flight" deterministic instead of timing-dependent.
///
/// `SessionActivitySignal` clamps at zero, so tests that care about activity
/// bookkeeping keep a second channel open — a double decrement then shows up
/// as `hasActiveSessions` flipping false too early. The registry marks
/// activity per account, so that second channel is on the same account
/// unless the test is about accounts not affecting each other.
@Suite("ChannelSessionRegistry acquire/release lifecycle", .timeLimit(.minutes(1)))
@MainActor
struct ChannelSessionRegistryLifecycleTests {

    // MARK: - Fixtures

    private struct StartFailure: Error {}

    private struct NullTokenStore: TwitchTokenStore {
        func loadToken() async throws -> OAuthToken? { nil }
        func saveToken(_ token: OAuthToken) async throws {}
        func deleteToken() async throws {}
    }

    /// Controllable stand-in for `ChannelSession.start()` / `stop()`.
    /// Every `start` suspends until `resolveStart(_:throwing:)` is called for
    /// its index (in call order). `stop` records and returns immediately
    /// unless `gateStops()` is on, in which case it suspends until
    /// `openStops()`.
    private actor FakeLifecycle {
        private var started: [ChannelSession] = []
        private var stopped: [ChannelSession] = []
        private var startGates: [CheckedContinuation<Void, any Error>?] = []
        private var stopsGated = false
        private var stopGates: [CheckedContinuation<Void, Never>] = []
        private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        private var stopWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

        var startCount: Int { started.count }
        var stopCount: Int { stopped.count }

        func startedSession(_ index: Int) -> ChannelSession { started[index] }

        func wasStopped(_ session: ChannelSession) -> Bool {
            stopped.contains { $0 === session }
        }

        func start(_ session: ChannelSession) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                // Same synchronous actor turn: the session is visible to
                // `waitForStarts` only once its gate exists to resolve.
                started.append(session)
                startGates.append(continuation)
                notifyWaiters()
            }
        }

        func stop(_ session: ChannelSession) async {
            stopped.append(session)
            notifyWaiters()
            if stopsGated {
                await withCheckedContinuation { stopGates.append($0) }
            }
        }

        func resolveStart(_ index: Int, throwing error: (any Error)? = nil) {
            guard index < startGates.count, let gate = startGates[index] else {
                Issue.record("start #\(index) is not pending")
                return
            }
            startGates[index] = nil
            if let error {
                gate.resume(throwing: error)
            } else {
                gate.resume()
            }
        }

        func gateStops() { stopsGated = true }

        func openStops() {
            stopsGated = false
            let gates = stopGates
            stopGates = []
            for gate in gates { gate.resume() }
        }

        func waitForStarts(_ count: Int) async {
            guard started.count < count else { return }
            await withCheckedContinuation { startWaiters.append((count, $0)) }
        }

        func waitForStops(_ count: Int) async {
            guard stopped.count < count else { return }
            await withCheckedContinuation { stopWaiters.append((count, $0)) }
        }

        private func notifyWaiters() {
            var pendingStarts: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
            for waiter in startWaiters {
                if started.count >= waiter.count { waiter.continuation.resume() } else { pendingStarts.append(waiter) }
            }
            startWaiters = pendingStarts

            var pendingStops: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
            for waiter in stopWaiters {
                if stopped.count >= waiter.count { waiter.continuation.resume() } else { pendingStops.append(waiter) }
            }
            stopWaiters = pendingStops
        }
    }

    private func makeRegistry(_ fake: FakeLifecycle, activity: SessionActivitySignal) -> ChannelSessionRegistry {
        ChannelSessionRegistry(dependencies: .init(
            // A fresh client per call: each account's dispatcher then owns
            // its own single-consumer event stream (and a restarted
            // dispatcher never re-iterates a terminated one). Never connected.
            client: { _ in TwitchClient(clientId: "test-client", tokenStore: NullTokenStore()) },
            refreshTokens: { _, _ in },
            sessionActivity: activity,
            startSession: { try await fake.start($0) },
            stopSession: { await fake.stop($0) },
            // No emote-provider requests from a lifecycle test.
            loadEmoteIndex: { _, _, _ in }
        ))
    }

    /// `session(...)` alone: builds (or joins) the session without taking a
    /// reference — what a chat page does.
    private func lookUp(
        _ registry: ChannelSessionRegistry,
        account: String = "me",
        channel: String = "1"
    ) -> Task<ChannelSession, any Error> {
        Task { @MainActor in
            try await registry.session(
                accountUserId: account,
                accountLogin: account,
                channelId: channel,
                channelLoginName: "ch\(channel)"
            )
        }
    }

    /// Build `channel`'s session through `session(...)` alone and let its
    /// start succeed: a started session nothing holds.
    private func openUnowned(
        _ registry: ChannelSessionRegistry,
        _ fake: FakeLifecycle,
        channel: String,
        startIndex: Int
    ) async throws -> ChannelSession {
        let task = lookUp(registry, channel: channel)
        await fake.waitForStarts(startIndex + 1)
        await fake.resolveStart(startIndex)
        return try await task.value
    }

    private func acquire(
        _ registry: ChannelSessionRegistry,
        account: String = "me",
        channel: String = "1"
    ) -> Task<ChannelSession, any Error> {
        Task { @MainActor in
            try await registry.acquire(
                accountUserId: account,
                accountLogin: account,
                channelId: channel,
                channelLoginName: "ch\(channel)"
            )
        }
    }

    private func failure<T: Sendable>(of task: Task<T, any Error>) async -> (any Error)? {
        switch await task.result {
        case .success: return nil
        case .failure(let error): return error
        }
    }

    /// Spin the main actor until `condition` holds (bounded by the suite's
    /// time limit). Used only where the registry has no async signal to
    /// await — e.g. "the second acquire has registered its in-flight start".
    private func waitUntil(_ condition: () -> Bool) async {
        while !condition() {
            await Task.yield()
        }
    }

    /// Acquire `channel` and let its start succeed. `startIndex` is the
    /// fake's call index that start will occupy.
    private func openChannel(
        _ registry: ChannelSessionRegistry,
        _ fake: FakeLifecycle,
        account: String = "me",
        channel: String,
        startIndex: Int
    ) async throws -> ChannelSession {
        let task = acquire(registry, account: account, channel: channel)
        await fake.waitForStarts(startIndex + 1)
        await fake.resolveStart(startIndex)
        return try await task.value
    }

    // MARK: - Release during start

    @Test("Release during an in-flight start stops the session instead of installing a zombie")
    func releaseDuringStart() async throws {
        let fake = FakeLifecycle()
        let activity = SessionActivitySignal()
        let registry = makeRegistry(fake, activity: activity)
        // Keep another channel open so activity under-counting is observable.
        let keeper = try await openChannel(registry, fake, channel: "2", startIndex: 0)

        let first = acquire(registry)
        await fake.waitForStarts(2)
        await registry.release(accountUserId: "me", channelId: "1")
        #expect(!registry.isStarting(accountUserId: "me", channelId: "1"))

        // The real start() swallows cancellation (enrichment subscribes,
        // empty backfill) and returns normally — simulate exactly that.
        await fake.resolveStart(1)
        let error = await failure(of: first)
        #expect(error is CancellationError)
        let zombie = await fake.startedSession(1)
        #expect(await fake.wasStopped(zombie))
        // The release already balanced this acquire; the failed acquire must
        // not decrement again (channel 2 is still open).
        #expect(activity.hasActiveSessions)

        // The next open builds and starts a fresh session.
        let reopened = try await openChannel(registry, fake, channel: "1", startIndex: 2)
        #expect(reopened !== zombie)
        let again = try await registry.session(accountUserId: "me", accountLogin: "me", channelId: "1", channelLoginName: "ch1")
        #expect(again === reopened)

        await registry.release(accountUserId: "me", channelId: "1")
        #expect(await fake.wasStopped(reopened))
        #expect(activity.hasActiveSessions)
        await registry.release(accountUserId: "me", channelId: "2")
        #expect(await fake.wasStopped(keeper))
        #expect(!activity.hasActiveSessions)
    }

    // MARK: - Re-acquire during stop

    @Test("Re-acquire during stop gets a new session and keeps its per-channel stores")
    func reacquireDuringStop() async throws {
        let fake = FakeLifecycle()
        let activity = SessionActivitySignal()
        let registry = makeRegistry(fake, activity: activity)
        let old = try await openChannel(registry, fake, channel: "1", startIndex: 0)
        let oldStore = registry.badgeStore(forAccountUserId: "me", channelId: "1")

        await fake.gateStops()
        let releasing = Task { @MainActor in
            await registry.release(accountUserId: "me", channelId: "1")
        }
        // The release has detached everything and is now inside old.stop().
        await fake.waitForStops(1)

        let second = acquire(registry)
        // Must construct a NEW session, not be handed the stopping one.
        await waitUntil { registry.isStarting(accountUserId: "me", channelId: "1") }
        let newStore = registry.badgeStore(forAccountUserId: "me", channelId: "1")
        #expect(newStore !== oldStore)
        // The new start waits for the old stop: no overlapping
        // subscribe/unsubscribe for the same topics.
        #expect(await fake.startCount == 1)

        await fake.openStops()
        await releasing.value
        await fake.waitForStarts(2)
        await fake.resolveStart(1)
        let fresh = try await second.value
        #expect(fresh !== old)

        // The finished release must not have wiped the new holder's state.
        #expect(registry.badgeStore(forAccountUserId: "me", channelId: "1") === newStore)
        let again = try await registry.session(accountUserId: "me", accountLogin: "me", channelId: "1", channelLoginName: "ch1")
        #expect(again === fresh)
        #expect(await fake.startCount == 2)
        #expect(await fake.stopCount == 1)
        #expect(activity.hasActiveSessions)

        await registry.release(accountUserId: "me", channelId: "1")
        #expect(await fake.wasStopped(fresh))
        #expect(!activity.hasActiveSessions)
    }

    // MARK: - Failed start vs newer acquire

    @Test("A stale start that fails doesn't clobber a newer acquire")
    func failedStaleStartDoesNotClobberNewerAcquire() async throws {
        let fake = FakeLifecycle()
        let activity = SessionActivitySignal()
        let registry = makeRegistry(fake, activity: activity)
        _ = try await openChannel(registry, fake, channel: "2", startIndex: 0)

        let first = acquire(registry)
        await fake.waitForStarts(2)
        await registry.release(accountUserId: "me", channelId: "1")
        let second = acquire(registry)
        await waitUntil { registry.isStarting(accountUserId: "me", channelId: "1") }
        // The newer start is queued behind the stale start's teardown.
        #expect(await fake.startCount == 2)

        await fake.resolveStart(1, throwing: StartFailure())
        let error = await failure(of: first)
        #expect(error is StartFailure)
        let stale = await fake.startedSession(1)
        #expect(await fake.wasStopped(stale))

        // The newer acquire's in-flight entry and routing survived the stale
        // failure's cleanup, so its start runs and commits.
        await fake.waitForStarts(3)
        await fake.resolveStart(2)
        let fresh = try await second.value
        #expect(fresh !== stale)
        let again = try await registry.session(accountUserId: "me", accountLogin: "me", channelId: "1", channelLoginName: "ch1")
        #expect(again === fresh)
        #expect(await fake.startCount == 3)

        // The stale acquire's failure must not have rolled back the newer
        // holder's refcount: exactly one release tears `fresh` down…
        await registry.release(accountUserId: "me", channelId: "1")
        #expect(await fake.wasStopped(fresh))
        // …and activity is still exactly 1 (channel 2).
        #expect(activity.hasActiveSessions)
        await registry.release(accountUserId: "me", channelId: "2")
        #expect(!activity.hasActiveSessions)
    }

    @Test("A failed start rolls back the refcount and the next acquire retries cleanly")
    func failedStartRollsBack() async throws {
        let fake = FakeLifecycle()
        let activity = SessionActivitySignal()
        let registry = makeRegistry(fake, activity: activity)

        let first = acquire(registry)
        await fake.waitForStarts(1)
        await fake.resolveStart(0, throwing: StartFailure())
        let error = await failure(of: first)
        #expect(error is StartFailure)
        #expect(!activity.hasActiveSessions)
        #expect(!registry.isStarting(accountUserId: "me", channelId: "1"))

        let retried = try await openChannel(registry, fake, channel: "1", startIndex: 1)
        #expect(await fake.startedSession(1) === retried)
        #expect(activity.hasActiveSessions)

        await registry.release(accountUserId: "me", channelId: "1")
        #expect(await fake.wasStopped(retried))
        #expect(!activity.hasActiveSessions)
    }

    // MARK: - Event routing

    @Test("Routing starts before start() completes and ends with the key's lifetime")
    func routingFollowsLifetime() async throws {
        let fake = FakeLifecycle()
        let activity = SessionActivitySignal()
        let registry = makeRegistry(fake, activity: activity)

        let pending = acquire(registry)
        await fake.waitForStarts(1)
        // Routed while start() is still in flight, so live events arriving
        // during subscribe + backfill are buffered by the session.
        #expect(registry.isRouted(accountUserId: "me", channelId: "1"))
        await fake.resolveStart(0)
        _ = try await pending.value
        #expect(registry.isRouted(accountUserId: "me", channelId: "1"))

        await registry.release(accountUserId: "me", channelId: "1")
        #expect(!registry.isRouted(accountUserId: "me", channelId: "1"))
    }

    @Test("A failed start stops routing to the abandoned session")
    func failedStartUnroutes() async {
        let fake = FakeLifecycle()
        let activity = SessionActivitySignal()
        let registry = makeRegistry(fake, activity: activity)

        let first = acquire(registry)
        await fake.waitForStarts(1)
        await fake.resolveStart(0, throwing: StartFailure())
        _ = await failure(of: first)
        #expect(!registry.isRouted(accountUserId: "me", channelId: "1"))
    }

    // MARK: - releaseAll

    @Test("releaseAll tears down every session for the account and balances activity")
    func releaseAllForAccount() async throws {
        let fake = FakeLifecycle()
        let activity = SessionActivitySignal()
        let registry = makeRegistry(fake, activity: activity)

        let one = try await openChannel(registry, fake, channel: "1", startIndex: 0)
        // Second acquire of the same channel: fast path, no new start.
        let oneAgain = try await registry.acquire(accountUserId: "me", accountLogin: "me", channelId: "1", channelLoginName: "ch1")
        #expect(oneAgain === one)
        let two = try await openChannel(registry, fake, channel: "2", startIndex: 1)
        let otherAccount = try await openChannel(registry, fake, account: "other", channel: "9", startIndex: 2)
        let pending = acquire(registry, channel: "3")
        await fake.waitForStarts(4)

        await registry.releaseAll(forAccountUserId: "me")

        #expect(await fake.wasStopped(one))
        #expect(await fake.wasStopped(two))
        #expect(!(await fake.wasStopped(otherAccount)))
        #expect(!registry.isStarting(accountUserId: "me", channelId: "3"))
        // The other account's channel keeps the signal live.
        #expect(activity.hasActiveSessions)

        // The in-flight start is cancelled and its session stopped once
        // start() returns.
        await fake.resolveStart(3)
        let error = await failure(of: pending)
        #expect(error is CancellationError)
        #expect(await fake.wasStopped(await fake.startedSession(3)))

        // Late releases for released keys are tolerated no-ops.
        await registry.release(accountUserId: "me", channelId: "1")
        #expect(activity.hasActiveSessions)

        // Exactly one activity mark remains — the other account's.
        await registry.release(accountUserId: "other", channelId: "9")
        #expect(await fake.wasStopped(otherAccount))
        #expect(!activity.hasActiveSessions)

        // Reopening a released channel builds a fresh session.
        let reopened = try await openChannel(registry, fake, channel: "1", startIndex: 4)
        #expect(reopened !== one)
        await registry.release(accountUserId: "me", channelId: "1")
        #expect(!activity.hasActiveSessions)
    }

    // MARK: - Unowned sessions (built by session(...) alone)

    @Test("release tears down a session nothing acquired, without touching activity")
    func releaseTearsDownUnownedSession() async throws {
        let fake = FakeLifecycle()
        let activity = SessionActivitySignal()
        let registry = makeRegistry(fake, activity: activity)
        // An acquired channel on the same account: a wrongful decrement for
        // the unowned one would clear the account's only activity mark.
        let keeper = try await openChannel(registry, fake, channel: "2", startIndex: 0)

        let unowned = try await openUnowned(registry, fake, channel: "1", startIndex: 1)
        #expect(registry.isRouted(accountUserId: "me", channelId: "1"))

        await registry.release(accountUserId: "me", channelId: "1")

        #expect(await fake.wasStopped(unowned))
        #expect(!registry.isRouted(accountUserId: "me", channelId: "1"))
        #expect(registry.existingSession(accountUserId: "me", channelId: "1") == nil)
        #expect(!(await fake.wasStopped(keeper)))
        #expect(activity.hasActiveSessions(forAccount: "me"))

        // A second release finds nothing and changes nothing.
        await registry.release(accountUserId: "me", channelId: "1")
        #expect(await fake.stopCount == 1)
        #expect(activity.hasActiveSessions(forAccount: "me"))

        await registry.release(accountUserId: "me", channelId: "2")
        #expect(!activity.hasActiveSessions(forAccount: "me"))
    }

    @Test("releaseUnowned tears down a session nothing acquired")
    func releaseUnownedTearsDownUnownedSession() async throws {
        let fake = FakeLifecycle()
        let activity = SessionActivitySignal()
        let registry = makeRegistry(fake, activity: activity)
        let keeper = try await openChannel(registry, fake, channel: "2", startIndex: 0)

        let unowned = try await openUnowned(registry, fake, channel: "1", startIndex: 1)
        await registry.releaseUnowned(accountUserId: "me", channelId: "1")

        #expect(await fake.wasStopped(unowned))
        #expect(!registry.isRouted(accountUserId: "me", channelId: "1"))
        #expect(!(await fake.wasStopped(keeper)))
        #expect(activity.hasActiveSessions(forAccount: "me"))

        // The next open builds a fresh session.
        let reopened = try await openChannel(registry, fake, channel: "1", startIndex: 2)
        #expect(reopened !== unowned)
    }

    @Test("releaseUnowned leaves an acquired session alone")
    func releaseUnownedIgnoresAcquiredSession() async throws {
        let fake = FakeLifecycle()
        let activity = SessionActivitySignal()
        let registry = makeRegistry(fake, activity: activity)
        let held = try await openChannel(registry, fake, channel: "1", startIndex: 0)

        await registry.releaseUnowned(accountUserId: "me", channelId: "1")

        #expect(await fake.stopCount == 0)
        #expect(registry.existingSession(accountUserId: "me", channelId: "1") === held)
        #expect(registry.isRouted(accountUserId: "me", channelId: "1"))
        #expect(activity.hasActiveSessions(forAccount: "me"))

        // The holder's own release is still the one that ends it.
        await registry.release(accountUserId: "me", channelId: "1")
        #expect(await fake.wasStopped(held))
        #expect(!activity.hasActiveSessions(forAccount: "me"))
    }

    @Test("releaseUnowned cancels an unowned start still in flight")
    func releaseUnownedCancelsUnownedStart() async throws {
        let fake = FakeLifecycle()
        let activity = SessionActivitySignal()
        let registry = makeRegistry(fake, activity: activity)

        let pending = lookUp(registry)
        await fake.waitForStarts(1)
        await registry.releaseUnowned(accountUserId: "me", channelId: "1")
        #expect(!registry.isStarting(accountUserId: "me", channelId: "1"))
        #expect(!registry.isRouted(accountUserId: "me", channelId: "1"))

        // The start returns normally; its session is stopped, never installed.
        await fake.resolveStart(0)
        let error = await failure(of: pending)
        #expect(error is CancellationError)
        #expect(await fake.wasStopped(await fake.startedSession(0)))
        #expect(registry.existingSession(accountUserId: "me", channelId: "1") == nil)
    }

    @Test("releaseAll covers unowned sessions and starts, and later releases are no-ops")
    func releaseAllCoversUnowned() async throws {
        let fake = FakeLifecycle()
        let activity = SessionActivitySignal()
        let registry = makeRegistry(fake, activity: activity)

        let acquired = try await openChannel(registry, fake, channel: "1", startIndex: 0)
        let unowned = try await openUnowned(registry, fake, channel: "2", startIndex: 1)
        let otherAccount = try await openChannel(registry, fake, account: "other", channel: "9", startIndex: 2)
        let pendingUnowned = lookUp(registry, channel: "3")
        await fake.waitForStarts(4)

        await registry.releaseAll(forAccountUserId: "me")

        #expect(await fake.wasStopped(acquired))
        #expect(await fake.wasStopped(unowned))
        #expect(!(await fake.wasStopped(otherAccount)))
        #expect(!registry.isStarting(accountUserId: "me", channelId: "3"))
        // One acquire was outstanding for "me": exactly its mark is gone.
        #expect(!activity.hasActiveSessions(forAccount: "me"))
        #expect(activity.hasActiveSessions(forAccount: "other"))

        await fake.resolveStart(3)
        let error = await failure(of: pendingUnowned)
        #expect(error is CancellationError)
        #expect(await fake.wasStopped(await fake.startedSession(3)))

        // The tabs' own releases landing afterwards find nothing to do and
        // never reach into the other account's mark.
        let stopsBefore = await fake.stopCount
        await registry.release(accountUserId: "me", channelId: "1")
        await registry.release(accountUserId: "me", channelId: "2")
        await registry.releaseUnowned(accountUserId: "me", channelId: "3")
        #expect(await fake.stopCount == stopsBefore)
        #expect(activity.hasActiveSessions(forAccount: "other"))

        await registry.release(accountUserId: "other", channelId: "9")
        #expect(!activity.hasActiveSessions)
    }

    @Test("A release that lands before releaseAll leaves it nothing to double-count")
    func releaseBeforeReleaseAll() async throws {
        let fake = FakeLifecycle()
        let activity = SessionActivitySignal()
        let registry = makeRegistry(fake, activity: activity)

        let one = try await openChannel(registry, fake, channel: "1", startIndex: 0)
        let two = try await openChannel(registry, fake, channel: "2", startIndex: 1)

        await registry.release(accountUserId: "me", channelId: "1")
        #expect(await fake.wasStopped(one))
        #expect(activity.hasActiveSessions(forAccount: "me"))   // channel 2

        await registry.releaseAll(forAccountUserId: "me")
        #expect(await fake.wasStopped(two))
        #expect(await fake.stopCount == 2)
        #expect(!activity.hasActiveSessions(forAccount: "me"))
    }
}
