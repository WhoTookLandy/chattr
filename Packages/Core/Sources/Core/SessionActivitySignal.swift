import os

/// Process-wide "is any chat channel currently open?" flag.
///
/// Resolves a dependency-direction problem: `AccountStore` (in `Accounts`)
/// builds the EventSub-backed `TwitchClient` and needs an `isLive` closure, but
/// "open channels" is known to `ChannelSessionRegistry` (in `Channels`, which
/// depends on `Accounts` — not the reverse). Both packages depend on `Core`, so
/// the shared signal lives here.
///
/// `isLive == true` (any active session) makes EventSub retry reconnection
/// indefinitely with fast backoff; `false` makes it give up after a few
/// attempts. Without this, chattr always passed the default `{ false }`, so a
/// channel went permanently dead after a ~30s network outage.
///
/// Sendable + lock-guarded: read from a `@Sendable` `isLive` closure on an
/// arbitrary executor, written from the `@MainActor` registry.
public final class SessionActivitySignal: Sendable {
    private let count = OSAllocatedUnfairLock(initialState: 0)

    public init() {}

    /// One open channel began. Pair with exactly one `decrement()`.
    public func increment() {
        count.withLock { $0 += 1 }
    }

    /// One open channel ended. Clamped at zero so a spurious release can't
    /// drive the count negative and mask later real activity.
    public func decrement() {
        count.withLock { $0 = max(0, $0 - 1) }
    }

    /// True while at least one channel is open.
    public var hasActiveSessions: Bool {
        count.withLock { $0 > 0 }
    }
}
