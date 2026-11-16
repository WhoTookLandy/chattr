import Testing
import Foundation
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

    @Test("A failed refresh fails every waiter, then the next call starts fresh")
    func failureIsSharedThenSlotClears() async throws {
        let refresher = TokenRefresher()
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

        // The failure isn't cached: a later call runs a new refresh.
        let recovered = try await refresher.refresh(userId: "1") {
            counter.count += 1
            return Self.token("recovered")
        }
        #expect(recovered.accessToken == "recovered")
        #expect(counter.count == 2)
    }

    @Test("Sequential refreshes each run (settled results aren't replayed)")
    func sequentialCallsEachRun() async throws {
        let refresher = TokenRefresher()
        let counter = CallCounter()
        let operation: @MainActor @Sendable () async throws -> OAuthToken = {
            counter.count += 1
            return Self.token("t\(counter.count)")
        }

        let first = try await refresher.refresh(userId: "1", operation: operation)
        let second = try await refresher.refresh(userId: "1", operation: operation)

        #expect(first.accessToken == "t1")
        #expect(second.accessToken == "t2")
        #expect(counter.count == 2)
        #expect(refresher.coalescedCount == 0)
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
