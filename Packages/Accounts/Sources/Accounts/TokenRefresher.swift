import Foundation
import TwitchKit
import Core
import os

private let logger = AppLogger.make("Accounts.TokenRefresher")

/// Single-flight coordinator for per-account OAuth refreshes.
///
/// Why this exists: at launch several independent tasks (RootView's
/// catalog / follows / emote / block loads, plus every `ChannelSession`'s
/// `refreshTokenHandler`) can all hit an expired access token at once. Each
/// of them used to POST its own refresh to the bridge with the *same*
/// refresh_token. Twitch may rotate the refresh_token on use, so the losers
/// of that race got "Invalid refresh token" back — which is terminal
/// (`forceSignOut` → `needsReauth`). One expired token could therefore sign
/// a healthy user out.
///
/// Three rules, all per `userId`:
///
/// - **Single flight.** At most one refresh is in flight. The first caller
///   starts it; every caller that arrives while it's running awaits the same
///   `Task` and receives the same token (or the same error).
/// - **Reuse.** A refresh asked for within `reuseWindow` of the last
///   successful one gets that token back without another bridge call. A
///   request that was sent with the old token and 401s just after the
///   refresh settled wants exactly that token, and so does a caller's own
///   refresh-and-retry layered on TwitchKit's (which already refreshed for
///   the same 401). A token that is itself the problem (a missing scope)
///   then costs one bridge call instead of one per layer.
/// - **Backoff.** After a transient failure, refreshes fail fast with that
///   error until a delay has passed: `initialBackoff`, doubling per
///   consecutive failure up to `maxBackoff`, reset by a success. A bridge
///   outage is then probed occasionally instead of on every request.
///
/// Reuse and backoff are tied to the `scope` the caller passes (the
/// account's client lifecycle): a token or failure remembered for one
/// sign-in says nothing about the next, so a re-authorized or signed-out
/// account starts clean.
///
/// Isolation: `@MainActor`, matching its owner `AccountStore`. The maps are
/// only touched on the main actor, so check-then-insert is atomic with
/// respect to other callers (no suspension point between the lookup and
/// the insert).
///
/// Cancellation: the refresh runs in an unstructured `Task`, so cancelling
/// the caller that happened to start it does NOT cancel the refresh other
/// callers are waiting on. Awaiting `Task.value` doesn't forward
/// cancellation either — each caller simply waits for the shared result.
@MainActor
final class TokenRefresher {
    /// How long a just-issued token answers further refresh requests.
    nonisolated static let defaultReuseWindow: TimeInterval = 5
    nonisolated static let defaultInitialBackoff: TimeInterval = 2
    nonisolated static let defaultMaxBackoff: TimeInterval = 60

    /// What a remembered token or failure belongs to, compared by identity.
    typealias Scope = AnyObject & Sendable

    private struct Issued {
        let token: OAuthToken
        let at: Date
        let scope: Scope?
    }

    private struct Failure {
        let error: any Error
        let at: Date
        /// Consecutive failures, this one included.
        let count: Int
        let scope: Scope?
    }

    private var inFlight: [String: Task<OAuthToken, Error>] = [:]
    private var lastIssued: [String: Issued] = [:]
    private var lastFailure: [String: Failure] = [:]

    private let reuseWindow: TimeInterval
    private let initialBackoff: TimeInterval
    private let maxBackoff: TimeInterval

    /// The clock reuse, backoff and `AccountStore`'s token expiry read.
    /// Tests inject one they can advance.
    let now: @MainActor () -> Date

    /// Number of callers that joined an already-running refresh instead of
    /// starting their own. Diagnostic (and what the tests observe).
    private(set) var coalescedCount = 0

    /// Number of callers handed a just-issued token instead of refreshing.
    private(set) var reusedCount = 0

    /// Number of callers failed fast while backing off.
    private(set) var backedOffCount = 0

    init(
        reuseWindow: TimeInterval = TokenRefresher.defaultReuseWindow,
        initialBackoff: TimeInterval = TokenRefresher.defaultInitialBackoff,
        maxBackoff: TimeInterval = TokenRefresher.defaultMaxBackoff,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.reuseWindow = reuseWindow
        self.initialBackoff = initialBackoff
        self.maxBackoff = maxBackoff
        self.now = now
    }

    /// Whether a refresh for `userId` is currently running.
    func isRefreshing(userId: String) -> Bool {
        inFlight[userId] != nil
    }

    /// The delay after `failures` consecutive failures.
    func backoffDelay(afterFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        // Capped exponent: the delay is already past any sane `maxBackoff`.
        let doublings = min(failures - 1, 16)
        return min(maxBackoff, initialBackoff * pow(2, Double(doublings)))
    }

    /// Runs `operation` unless a refresh for `userId` is already in flight
    /// (then it awaits that one), a token was issued for `scope` within the
    /// reuse window (then it returns that), or a failure for `scope` is
    /// still backing off (then it rethrows that).
    func refresh(
        userId: String,
        scope: Scope? = nil,
        operation: @escaping @MainActor @Sendable () async throws -> OAuthToken
    ) async throws -> OAuthToken {
        if let existing = inFlight[userId] {
            coalescedCount += 1
            logger.debug("Joining in-flight token refresh for \(userId, privacy: .public)")
            return try await existing.value
        }

        let startedAt = now()
        if let issued = lastIssued[userId] {
            // A clock that went backwards makes the record unusable.
            let age = startedAt.timeIntervalSince(issued.at)
            if Self.same(issued.scope, scope), age >= 0, age < reuseWindow {
                reusedCount += 1
                logger.debug("Reusing the token just issued for \(userId, privacy: .public)")
                return issued.token
            }
            lastIssued[userId] = nil
        }
        if let failure = lastFailure[userId] {
            let age = startedAt.timeIntervalSince(failure.at)
            if Self.same(failure.scope, scope), age >= 0, age < backoffDelay(afterFailures: failure.count) {
                backedOffCount += 1
                logger.debug("Token refresh for \(userId, privacy: .public) is backing off after \(failure.count) failure(s)")
                throw failure.error
            }
            if !Self.same(failure.scope, scope) || age < 0 {
                lastFailure[userId] = nil
            }
        }

        // Inherits @MainActor from this method, so `operation` runs on main
        // like the rest of AccountStore.
        let task = Task<OAuthToken, Error> { try await operation() }
        inFlight[userId] = task
        // No `defer`: the clear must happen after the await, and only if the
        // slot still holds OUR task (it always should — nothing else removes
        // or replaces a live entry — but the identity check keeps a future
        // change from clearing someone else's refresh).
        do {
            let token = try await task.value
            clearSlot(userId: userId, ifHolding: task)
            lastIssued[userId] = Issued(token: token, at: now(), scope: scope)
            lastFailure[userId] = nil
            return token
        } catch {
            clearSlot(userId: userId, ifHolding: task)
            if Self.backsOff(after: error) {
                let previous = lastFailure[userId]
                let count = previous.map { Self.same($0.scope, scope) ? $0.count + 1 : 1 } ?? 1
                lastFailure[userId] = Failure(error: error, at: now(), count: count, scope: scope)
            } else {
                lastFailure[userId] = nil
            }
            throw error
        }
    }

    /// Whether `error` is worth backing off from. A discarded refresh
    /// (`CancellationError`: the account changed under it) and a dead
    /// session say nothing about the bridge's health.
    private static func backsOff(after error: any Error) -> Bool {
        if error is CancellationError { return false }
        if let appError = error as? AppError, case .sessionExpired = appError.kind { return false }
        return true
    }

    private static func same(_ lhs: Scope?, _ rhs: Scope?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (lhs?, rhs?): return ObjectIdentifier(lhs) == ObjectIdentifier(rhs)
        default: return false
        }
    }

    private func clearSlot(userId: String, ifHolding task: Task<OAuthToken, Error>) {
        if inFlight[userId] == task {
            inFlight[userId] = nil
        }
    }
}
