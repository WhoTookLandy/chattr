import Foundation
import os

/// A FIFO async mutex for one account's stored token. `TwitchClientCache`
/// keeps one per userId, shared by every client it builds for that account
/// (they all write the same Keychain entry), and runs through it:
///
/// - every save and delete a client's `LifecycleGuardedTokenStore` lets
///   through, with the lifecycle check *inside* the critical section, so a
///   write can't be admitted while the client is active and land after it
///   was retired;
/// - every lifecycle transition (`beginSignOut`, `retire`), so a transition
///   waits for any write admitted before it to finish;
/// - re-authorization's retire-old → write-new → install swap, so the new
///   credential is always written after every write the old client was
///   admitted for;
/// - every other change to which client is cached for the account: a
///   sign-out's check-still-current → evict → session cleanup, so it either
///   runs wholly before a re-authorization or does nothing after one.
///
/// Needed because production builds a separate `KeychainTokenStore` actor per
/// client, so writes from an old and a new client for the same key aren't
/// otherwise ordered.
///
/// ## Why it can't deadlock
///
/// - It is held only around one token-store operation, one lifecycle flip,
///   or an eviction with its synchronous cleanup (which includes one
///   synchronous Keychain delete of the refresh-token mirror). Never across
///   a bridge or Helix request.
/// - Nothing that runs while it's held acquires it again (it's not
///   reentrant): the guarded store calls the *base* store, and the cache's
///   critical sections call the base store or flip a lifecycle directly.
/// - Waiting doesn't block a thread: waiters are suspended continuations,
///   handed the lock in arrival order.
///
/// Waiting isn't cancellable. That's deliberate: the holder only ever does
/// one Keychain operation, and a mutation that gave up its place in line
/// could no longer be ordered against a re-authorization.
///
/// Known limit: there is no timeout. A Keychain operation that never
/// returns stalls that one account's gate (its token writes, sign-out and
/// re-authorization) until relaunch. Reads and other accounts are
/// unaffected.
///
/// Not on any read path: `loadToken` and request handling never touch it.
final class AccountTokenGate: Sendable {
    private struct Watcher: Sendable {
        let waiters: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State: Sendable {
        var held = false
        var waiters: [CheckedContinuation<Void, Never>] = []
        var watchers: [Watcher] = []

        /// Removes and returns the watchers whose waiter count is reached.
        mutating func takeSatisfiedWatchers() -> [CheckedContinuation<Void, Never>] {
            let count = waiters.count
            let ready = watchers.filter { $0.waiters <= count }.map(\.continuation)
            watchers.removeAll { $0.waiters <= count }
            return ready
        }
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Runs `body` once every earlier caller's `body` has finished. `body`
    /// runs in the caller's isolation.
    func withLock<T>(
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> T
    ) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let (acquired, ready) = state.withLock { state -> (Bool, [CheckedContinuation<Void, Never>]) in
                guard state.held else {
                    state.held = true
                    return (true, [])
                }
                state.waiters.append(continuation)
                return (false, state.takeSatisfiedWatchers())
            }
            if acquired { continuation.resume() }
            for watcher in ready { watcher.resume() }
        }
    }

    /// Hands the lock straight to the longest waiter, or frees it.
    private func release() {
        let next = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard !state.waiters.isEmpty else {
                state.held = false
                return nil
            }
            return state.waiters.removeFirst()
        }
        next?.resume()
    }

    /// Test hook: returns once at least `count` callers are queued behind
    /// the current holder, so a test can prove a caller is waiting without
    /// sleeping.
    func waitForWaiters(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = state.withLock { state -> Bool in
                if state.waiters.count >= count { return true }
                state.watchers.append(Watcher(waiters: count, continuation: continuation))
                return false
            }
            if ready { continuation.resume() }
        }
    }
}
