import Testing
import Foundation
import os
@testable import Channels

/// Refresh-once / retry-once mechanics of `HelixAuthRetry`, driven with a
/// local error type through the injectable `isAuthRefreshable` predicate —
/// no network, no TwitchKit error construction.
@Suite("HelixAuthRetry")
struct HelixAuthRetryTests {

    private enum TestError: Error, Equatable {
        case stale          // treated as auth-refreshable
        case other          // not refreshable
        case refreshFailed
    }

    private final class Counter: Sendable {
        private let value = OSAllocatedUnfairLock(initialState: 0)
        func increment() { value.withLock { $0 += 1 } }
        var count: Int { value.withLock { $0 } }
    }

    private func makeRetry(
        refreshes: Counter,
        refreshError: TestError? = nil
    ) -> HelixAuthRetry {
        HelixAuthRetry(
            refreshTokenHandler: {
                refreshes.increment()
                if let refreshError { throw refreshError }
            },
            isAuthRefreshable: { ($0 as? TestError) == .stale }
        )
    }

    @Test("A first-try success never refreshes")
    func successNoRefresh() async throws {
        let refreshes = Counter()
        let retry = makeRetry(refreshes: refreshes)
        var attempts = 0
        let value = try await retry.run("op") { () async throws -> Int in
            attempts += 1
            return 7
        }
        #expect(value == 7)
        #expect(attempts == 1)
        #expect(refreshes.count == 0)
    }

    @Test("An auth-refreshable failure refreshes once and retries once")
    func refreshThenRetry() async throws {
        let refreshes = Counter()
        let retry = makeRetry(refreshes: refreshes)
        var attempts = 0
        let value = try await retry.run("op") { () async throws -> Int in
            attempts += 1
            if attempts == 1 { throw TestError.stale }
            return 42
        }
        #expect(value == 42)
        #expect(attempts == 2)
        #expect(refreshes.count == 1)
    }

    @Test("A second auth failure propagates — no second refresh")
    func secondFailurePropagates() async {
        let refreshes = Counter()
        let retry = makeRetry(refreshes: refreshes)
        var attempts = 0
        var caught: TestError?
        do {
            try await retry.run("op") { () async throws -> Void in
                attempts += 1
                throw TestError.stale
            }
        } catch {
            caught = error as? TestError
        }
        #expect(caught == .stale)
        #expect(attempts == 2)
        #expect(refreshes.count == 1)
    }

    @Test("A non-refreshable failure propagates without refreshing")
    func nonRefreshablePropagates() async {
        let refreshes = Counter()
        let retry = makeRetry(refreshes: refreshes)
        var attempts = 0
        var caught: TestError?
        do {
            try await retry.run("op") { () async throws -> Void in
                attempts += 1
                throw TestError.other
            }
        } catch {
            caught = error as? TestError
        }
        #expect(caught == .other)
        #expect(attempts == 1)
        #expect(refreshes.count == 0)
    }

    @Test("A failed refresh propagates its error and skips the retry")
    func refreshFailurePropagates() async {
        let refreshes = Counter()
        let retry = makeRetry(refreshes: refreshes, refreshError: .refreshFailed)
        var attempts = 0
        var caught: TestError?
        do {
            try await retry.run("op") { () async throws -> Void in
                attempts += 1
                throw TestError.stale
            }
        } catch {
            caught = error as? TestError
        }
        #expect(caught == .refreshFailed)
        #expect(attempts == 1)
        #expect(refreshes.count == 1)
    }

    @Test("The production predicate ignores non-Helix errors")
    func defaultPredicateIgnoresOtherErrors() {
        #expect(!HelixAuthRetry.isHelixAuthRefreshable(TestError.stale))
        #expect(!HelixAuthRetry.isHelixAuthRefreshable(CancellationError()))
    }
}
