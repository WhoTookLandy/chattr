import os

/// Process-wide "which accounts have a chat channel open?" signal.
///
/// Resolves a dependency-direction problem: `AccountStore` (in `Accounts`)
/// builds the EventSub-backed `TwitchClient` and needs an `isLive` closure, but
/// "open channels" is known to `ChannelSessionRegistry` (in `Channels`, which
/// depends on `Accounts` — not the reverse). Both packages depend on `Core`, so
/// the shared signal lives here.
///
/// `isLive == true` makes EventSub retry reconnection indefinitely with fast
/// backoff; `false` makes it give up after a few attempts. Without this,
/// chattr always passed the default `{ false }`, so a channel went permanently
/// dead after a ~30s network outage.
///
/// Counts are kept per account, so one account's client isn't told to
/// reconnect aggressively because a different account has a channel open.
/// The account-less `increment()` / `decrement()` count for every account.
///
/// Sendable + lock-guarded: read from a `@Sendable` `isLive` closure on an
/// arbitrary executor, written from the `@MainActor` registry.
public final class SessionActivitySignal: Sendable {
    private struct Counts: Sendable {
        /// Open channels not attributed to an account.
        var unattributed = 0
        /// Open channels per account userId. Zero entries are removed.
        var perAccount: [String: Int] = [:]
    }

    private let counts = OSAllocatedUnfairLock(initialState: Counts())

    public init() {}

    /// One open channel began. Pair with exactly one `decrement()`.
    public func increment() {
        counts.withLock { $0.unattributed += 1 }
    }

    /// One open channel ended. Clamped at zero so a spurious release can't
    /// drive the count negative and mask later real activity.
    public func decrement() {
        counts.withLock { $0.unattributed = max(0, $0.unattributed - 1) }
    }

    /// One of `accountUserId`'s channels opened. Pair with exactly one
    /// `decrement(forAccount:)` for the same account.
    public func increment(forAccount accountUserId: String) {
        counts.withLock { $0.perAccount[accountUserId, default: 0] += 1 }
    }

    /// One of `accountUserId`'s channels closed. Clamped at zero, like
    /// `decrement()`.
    public func decrement(forAccount accountUserId: String) {
        counts.withLock { state in
            guard let current = state.perAccount[accountUserId] else { return }
            if current <= 1 {
                state.perAccount[accountUserId] = nil
            } else {
                state.perAccount[accountUserId] = current - 1
            }
        }
    }

    /// True while at least one channel is open, on any account.
    public var hasActiveSessions: Bool {
        counts.withLock { $0.unattributed > 0 || !$0.perAccount.isEmpty }
    }

    /// True while `accountUserId` has a channel open (or an account-less one
    /// is).
    public func hasActiveSessions(forAccount accountUserId: String) -> Bool {
        counts.withLock { $0.unattributed > 0 || $0.perAccount[accountUserId] != nil }
    }
}
