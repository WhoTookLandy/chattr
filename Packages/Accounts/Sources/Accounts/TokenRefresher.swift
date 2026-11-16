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
/// of that race got a 4xx back — and a 4xx from the bridge is treated as
/// terminal (`forceSignOut` → `needsReauth`). One expired token could
/// therefore sign a healthy user out.
///
/// The fix: at most one refresh per `userId` is in flight. The first caller
/// starts it; every caller that arrives while it's running awaits the same
/// `Task` and receives the same token (or the same error). The slot clears
/// as soon as the refresh settles, so a *later* expiry triggers a fresh
/// refresh rather than replaying a stale result.
///
/// Isolation: `@MainActor`, matching its owner `AccountStore`. The map is
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
    private var inFlight: [String: Task<OAuthToken, Error>] = [:]

    /// Number of callers that joined an already-running refresh instead of
    /// starting their own. Diagnostic (and what the tests observe).
    private(set) var coalescedCount = 0

    /// Whether a refresh for `userId` is currently running.
    func isRefreshing(userId: String) -> Bool {
        inFlight[userId] != nil
    }

    /// Runs `operation` unless a refresh for `userId` is already in flight,
    /// in which case it awaits that one instead. Either way the caller gets
    /// the shared outcome.
    func refresh(
        userId: String,
        operation: @escaping @MainActor @Sendable () async throws -> OAuthToken
    ) async throws -> OAuthToken {
        if let existing = inFlight[userId] {
            coalescedCount += 1
            logger.debug("Joining in-flight token refresh for \(userId, privacy: .public)")
            return try await existing.value
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
            return token
        } catch {
            clearSlot(userId: userId, ifHolding: task)
            throw error
        }
    }

    private func clearSlot(userId: String, ifHolding task: Task<OAuthToken, Error>) {
        if inFlight[userId] == task {
            inFlight[userId] = nil
        }
    }
}
