import Foundation
import TwitchKit
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
///
/// ## Token freshness
///
/// The gate also remembers the account's newest bridge-issued token, so a
/// late TwitchKit save can't roll it back. A refresh persists T1 and leaves
/// the single-flight slot *before* TwitchKit consumes the synthesized
/// response for it, so a second refresh can persist T2 in between; TwitchKit
/// then calls `setToken(T1)` on a client that is still active.
/// `LifecycleGuardedTokenStore` asks `admitSave(_:)` while holding the lock
/// and drops that save. The record is plain lock-protected state (it never
/// waits), reset on re-authorization and sign-out.
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

    /// Bridge-issued tokens, in the order the bridge issued them.
    private struct Freshness: Sendable {
        var nextSequence: UInt64 = 0
        /// Issued, not yet persisted: access token → sequence. Normally at
        /// most one (refreshes are single-flight); pruned on every persist.
        var pending: [String: UInt64] = [:]
        /// The newest bridge-issued token persisted since the last reset,
        /// and its sequence. The account's token entry holds exactly this.
        var newest: OAuthToken?
        var newestSequence: UInt64 = 0
    }

    private let freshness = OSAllocatedUnfairLock(initialState: Freshness())

    /// What `LifecycleGuardedTokenStore` may do with a save.
    enum SaveAdmission: Sendable, Equatable {
        /// Write it.
        case write
        /// The entry already holds this token: nothing to write.
        case alreadyStored
        /// Older than the newest bridge-issued token, which the entry holds
        /// (and the client's provider should hold too).
        case superseded(by: OAuthToken)
    }

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

    // MARK: Freshness

    /// Records a token the bridge just issued, before it is persisted.
    /// Called in issue order: refreshes are single-flight per account.
    func recordIssued(_ token: OAuthToken) {
        freshness.withLock { record in
            record.nextSequence += 1
            record.pending[token.accessToken] = record.nextSequence
        }
    }

    /// Whether a save of `token` may be written. A saving caller must hold
    /// the gate, so no other save interleaves between this and the write.
    ///
    /// Until a bridge-issued token has been persisted, everything is
    /// written. After that, only a token the bridge issued *later* is.
    /// Anything else is older: an earlier bridge token that TwitchKit saves
    /// late, or the token the client started with, handed back through
    /// `.unavailable(current:)`. Re-authorization never comes through here:
    /// it writes the base store directly and resets the record.
    func admitSave(_ token: OAuthToken) -> SaveAdmission {
        freshness.withLock { record in
            guard let newest = record.newest else { return .write }
            if token.accessToken == newest.accessToken { return .alreadyStored }
            if let sequence = record.pending[token.accessToken], sequence > record.newestSequence {
                return .write
            }
            return .superseded(by: newest)
        }
    }

    /// Records that `token` was written. A bridge-issued token becomes the
    /// newest; any other token (only written before the first bridge token)
    /// leaves the record alone.
    func didPersist(_ token: OAuthToken) {
        freshness.withLock { record in
            guard let sequence = record.pending[token.accessToken] else { return }
            record.newest = token
            record.newestSequence = sequence
            record.pending = record.pending.filter { $0.value > sequence }
        }
    }

    /// The newest bridge-issued token when `token` is older than it, else
    /// `nil`. Lets a refresh avoid POSTing a refresh token already spent.
    /// Reads the record only; never waits on the gate.
    ///
    /// Needed beside the store's re-seed: if TwitchKit's late `setToken`
    /// lands while a newer refresh is between issuing and persisting its
    /// token, the late save is still the newest *persisted* one and isn't
    /// dropped, so the provider can briefly hold it (a still-valid access
    /// token). The next refresh then comes here and spends the newest
    /// refresh token instead of the provider's spent one.
    func newerToken(than token: OAuthToken) -> OAuthToken? {
        guard case .superseded(let newest) = admitSave(token) else { return nil }
        return newest
    }

    /// Forgets every issued token. Called while holding the lock when the
    /// account is re-authorized or signed out: the next credential has no
    /// ordering relation to the old ones.
    func resetFreshness() {
        freshness.withLock { $0 = Freshness() }
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
