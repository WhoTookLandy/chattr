import Testing
import Foundation
import Core
import TwitchKit
@testable import Accounts

/// Parks the fake refresh until the test opens it, so every caller is
/// guaranteed to arrive while the refresh is still in flight.
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
        waiters.removeAll()
    }
}

/// How many times the fake refresh actually ran.
@MainActor
private final class CallCounter {
    var count = 0
}

private struct RefreshFailed: Error {}

/// A clock the test moves by hand.
@MainActor
private final class TestClock {
    var now = Date(timeIntervalSince1970: 1_700_000_000)

    func advance(by seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}

/// Stands in for an account's client lifecycle.
private final class ScopeToken: Sendable {}

@Suite("TokenRefresher (single-flight refresh)")
@MainActor
struct TokenRefresherTests {

    private static func token(_ access: String) -> OAuthToken {
        OAuthToken(
            accessToken: access,
            refreshToken: "refresh-\(access)",
            expiresIn: 3600,
            scope: nil,
            tokenType: "bearer"
        )
    }

    /// Yields until `condition` holds, with a bound so a regression fails the
    /// test instead of hanging it.
    private static func spin(until condition: () -> Bool) async {
        var spins = 0
        while !condition() && spins < 10_000 {
            await Task.yield()
            spins += 1
        }
    }

    @Test("Concurrent callers for one account share a single refresh")
    func concurrentCallersCoalesce() async throws {
        let refresher = TokenRefresher()
        let counter = CallCounter()
        let gate = Gate()
        let fresh = Self.token("fresh")
        let operation: @MainActor @Sendable () async throws -> OAuthToken = {
            counter.count += 1
            await gate.wait()
            return fresh
        }
        let callers = 6

        let results = try await withThrowingTaskGroup(of: OAuthToken.self) { group in
            for _ in 0..<callers {
                group.addTask { try await refresher.refresh(userId: "1", operation: operation) }
            }
            // Hold the refresh open until every other caller has joined it.
            await Self.spin { refresher.coalescedCount == callers - 1 }
            await gate.open()
            var tokens: [OAuthToken] = []
            for try await token in group { tokens.append(token) }
            return tokens
        }

        #expect(counter.count == 1)
        #expect(refresher.coalescedCount == callers - 1)
        #expect(results.count == callers)
        #expect(results.allSatisfy { $0.accessToken == "fresh" })
        #expect(refresher.isRefreshing(userId: "1") == false)
    }

    @Test("A failed refresh fails every waiter, then the next call after the backoff starts fresh")
    func failureIsSharedThenSlotClears() async throws {
        let clock = TestClock()
        let refresher = TokenRefresher(initialBackoff: 2, now: { clock.now })
        let counter = CallCounter()
        let gate = Gate()
        let failing: @MainActor @Sendable () async throws -> OAuthToken = {
            counter.count += 1
            await gate.wait()
            throw RefreshFailed()
        }
        let callers = 3

        let failures = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<callers {
                group.addTask {
                    do {
                        _ = try await refresher.refresh(userId: "1", operation: failing)
                        return false
                    } catch is RefreshFailed {
                        return true
                    } catch {
                        return false
                    }
                }
            }
            await Self.spin { refresher.coalescedCount == callers - 1 }
            await gate.open()
            var count = 0
            for await failed in group where failed { count += 1 }
            return count
        }

        #expect(failures == callers)
        #expect(counter.count == 1)
        #expect(refresher.isRefreshing(userId: "1") == false)

        // Once the backoff has passed, a later call runs a new refresh.
        clock.advance(by: 3)
        let recovered = try await refresher.refresh(userId: "1") {
            counter.count += 1
            return Self.token("recovered")
        }
        #expect(recovered.accessToken == "recovered")
        #expect(counter.count == 2)
    }

    @Test("A refresh asked for just after one succeeded reuses its token")
    func recentTokenIsReused() async throws {
        let clock = TestClock()
        let refresher = TokenRefresher(reuseWindow: 5, now: { clock.now })
        let counter = CallCounter()
        let operation: @MainActor @Sendable () async throws -> OAuthToken = {
            counter.count += 1
            return Self.token("t\(counter.count)")
        }

        let first = try await refresher.refresh(userId: "1", operation: operation)
        clock.advance(by: 4)
        let second = try await refresher.refresh(userId: "1", operation: operation)

        #expect(first.accessToken == "t1")
        #expect(second.accessToken == "t1")
        #expect(counter.count == 1)
        #expect(refresher.reusedCount == 1)
        #expect(refresher.coalescedCount == 0)
    }

    @Test("Sequential refreshes each run once the reuse window has passed")
    func sequentialCallsEachRunAfterReuseWindow() async throws {
        let clock = TestClock()
        let refresher = TokenRefresher(reuseWindow: 5, now: { clock.now })
        let counter = CallCounter()
        let operation: @MainActor @Sendable () async throws -> OAuthToken = {
            counter.count += 1
            return Self.token("t\(counter.count)")
        }

        let first = try await refresher.refresh(userId: "1", operation: operation)
        clock.advance(by: 6)
        let second = try await refresher.refresh(userId: "1", operation: operation)

        #expect(first.accessToken == "t1")
        #expect(second.accessToken == "t2")
        #expect(counter.count == 2)
        #expect(refresher.reusedCount == 0)
        #expect(refresher.coalescedCount == 0)
    }

    @Test("A token issued for another scope or account isn't reused")
    func reuseIsScopedAndPerAccount() async throws {
        let clock = TestClock()
        let refresher = TokenRefresher(reuseWindow: 5, now: { clock.now })
        let counter = CallCounter()
        let operation: @MainActor @Sendable () async throws -> OAuthToken = {
            counter.count += 1
            return Self.token("t\(counter.count)")
        }
        let oldClient = ScopeToken()
        let newClient = ScopeToken()

        _ = try await refresher.refresh(userId: "1", scope: oldClient, operation: operation)
        let sameScope = try await refresher.refresh(userId: "1", scope: oldClient, operation: operation)
        let otherAccount = try await refresher.refresh(userId: "2", scope: oldClient, operation: operation)
        let reauthorized = try await refresher.refresh(userId: "1", scope: newClient, operation: operation)

        #expect(sameScope.accessToken == "t1")
        #expect(otherAccount.accessToken == "t2")
        #expect(reauthorized.accessToken == "t3")
        #expect(counter.count == 3)
    }

    @Test("After a failure, refreshes fail fast until the backoff has passed, and the delay doubles up to the cap")
    func transientFailureBacksOff() async throws {
        let clock = TestClock()
        let refresher = TokenRefresher(initialBackoff: 2, maxBackoff: 60, now: { clock.now })
        let counter = CallCounter()
        let failing: @MainActor @Sendable () async throws -> OAuthToken = {
            counter.count += 1
            throw RefreshFailed()
        }

        #expect(refresher.backoffDelay(afterFailures: 1) == 2)
        #expect(refresher.backoffDelay(afterFailures: 2) == 4)
        #expect(refresher.backoffDelay(afterFailures: 5) == 32)
        #expect(refresher.backoffDelay(afterFailures: 6) == 60)
        #expect(refresher.backoffDelay(afterFailures: 500) == 60)

        // First failure: 2 s of failing fast.
        await #expect(throws: RefreshFailed.self) {
            try await refresher.refresh(userId: "1", operation: failing)
        }
        clock.advance(by: 1)
        await #expect(throws: RefreshFailed.self) {
            try await refresher.refresh(userId: "1", operation: failing)
        }
        #expect(counter.count == 1)
        #expect(refresher.backedOffCount == 1)

        // Second failure: the delay is now 4 s.
        clock.advance(by: 1.5)
        await #expect(throws: RefreshFailed.self) {
            try await refresher.refresh(userId: "1", operation: failing)
        }
        #expect(counter.count == 2)
        clock.advance(by: 3)
        await #expect(throws: RefreshFailed.self) {
            try await refresher.refresh(userId: "1", operation: failing)
        }
        #expect(counter.count == 2)

        // Another account isn't held back.
        await #expect(throws: RefreshFailed.self) {
            try await refresher.refresh(userId: "2", operation: failing)
        }
        #expect(counter.count == 3)
    }

    @Test("A success resets the backoff")
    func successResetsBackoff() async throws {
        let clock = TestClock()
        let refresher = TokenRefresher(reuseWindow: 0, initialBackoff: 2, maxBackoff: 60, now: { clock.now })
        let counter = CallCounter()
        let failing: @MainActor @Sendable () async throws -> OAuthToken = {
            counter.count += 1
            throw RefreshFailed()
        }

        for _ in 0..<3 {
            await #expect(throws: RefreshFailed.self) {
                try await refresher.refresh(userId: "1", operation: failing)
            }
            clock.advance(by: 60)
        }
        #expect(counter.count == 3)
        _ = try await refresher.refresh(userId: "1") { Self.token("ok") }

        // The next failure starts again from the initial delay.
        await #expect(throws: RefreshFailed.self) {
            try await refresher.refresh(userId: "1", operation: failing)
        }
        clock.advance(by: 3)
        await #expect(throws: RefreshFailed.self) {
            try await refresher.refresh(userId: "1", operation: failing)
        }
        #expect(counter.count == 5)
    }

    @Test("A discarded refresh or a dead session doesn't back off, and a new scope starts clean")
    func nonTransientFailuresDoNotBackOff() async throws {
        let clock = TestClock()
        let refresher = TokenRefresher(now: { clock.now })
        let counter = CallCounter()
        let cancelled: @MainActor @Sendable () async throws -> OAuthToken = {
            counter.count += 1
            throw CancellationError()
        }
        let expired: @MainActor @Sendable () async throws -> OAuthToken = {
            counter.count += 1
            throw AppError.sessionExpired(login: "landy")
        }
        let failing: @MainActor @Sendable () async throws -> OAuthToken = {
            counter.count += 1
            throw RefreshFailed()
        }

        await #expect(throws: CancellationError.self) {
            try await refresher.refresh(userId: "1", operation: cancelled)
        }
        await #expect(throws: AppError.sessionExpired(login: "landy")) {
            try await refresher.refresh(userId: "1", operation: expired)
        }
        #expect(counter.count == 2)

        let oldClient = ScopeToken()
        let newClient = ScopeToken()
        await #expect(throws: RefreshFailed.self) {
            try await refresher.refresh(userId: "1", scope: oldClient, operation: failing)
        }
        let fresh = try await refresher.refresh(userId: "1", scope: newClient) { Self.token("fresh") }
        #expect(fresh.accessToken == "fresh")
        #expect(counter.count == 3)
        #expect(refresher.backedOffCount == 0)
    }

    @Test("Refreshes for different accounts don't coalesce")
    func differentAccountsRunIndependently() async throws {
        let refresher = TokenRefresher()
        let counter = CallCounter()
        let gate = Gate()
        let operation: @MainActor @Sendable () async throws -> OAuthToken = {
            counter.count += 1
            await gate.wait()
            return Self.token("x")
        }

        try await withThrowingTaskGroup(of: OAuthToken.self) { group in
            group.addTask { try await refresher.refresh(userId: "1", operation: operation) }
            group.addTask { try await refresher.refresh(userId: "2", operation: operation) }
            await Self.spin { counter.count == 2 }
            #expect(refresher.isRefreshing(userId: "1"))
            #expect(refresher.isRefreshing(userId: "2"))
            await gate.open()
            for try await _ in group {}
        }

        #expect(counter.count == 2)
        #expect(refresher.coalescedCount == 0)
    }
}
