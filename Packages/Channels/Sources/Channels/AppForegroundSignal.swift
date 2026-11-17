import os

/// Process-wide "is the app in the foreground?" flag, shared by the registry
/// and every `ChannelSession` it builds.
///
/// The registry writes it from the scene phase
/// (`ChannelSessionRegistry.setAppInForeground`) and then nudges each
/// session to re-read it (`ChannelSession.appForegroundDidChange()`).
/// Sessions read the flag itself rather than a value carried by the nudge,
/// so nudges that reach a session out of order (fast background /
/// foreground flips, each delivered by its own Task) still leave it in the
/// right state.
///
/// Every change also bumps `generation`. A session compares generations,
/// not flag values: if both nudges of a quick background → foreground flip
/// reach it after the flag is already back to `true`, the value looks
/// unchanged but the generation has moved, so the session still runs its
/// one catch-up reconcile for the background stretch it never saw.
///
/// What it gates: background network work that nobody is looking at. The
/// EventSub socket can stay up in the background (background audio / PiP),
/// so its events keep reducing, but no live-event Helix request starts.
///
/// Sendable + lock-guarded: written on the main actor, read on session
/// actors.
public final class AppForegroundSignal: Sendable {

    /// The flag and how many times it has changed, read together.
    struct State: Sendable, Equatable {
        var isInForeground: Bool
        /// Incremented on every change of `isInForeground`.
        var generation: UInt64 = 0
    }

    private let lock: OSAllocatedUnfairLock<State>

    public init(isInForeground: Bool = true) {
        lock = OSAllocatedUnfairLock(initialState: State(isInForeground: isInForeground))
    }

    public var isInForeground: Bool {
        lock.withLock { $0.isInForeground }
    }

    /// The flag and its generation, read atomically.
    var state: State {
        lock.withLock { $0 }
    }

    /// Sets the flag, bumping the generation if it changed. Returns whether
    /// it changed.
    @discardableResult
    func set(_ isInForeground: Bool) -> Bool {
        lock.withLock { current in
            guard current.isInForeground != isInForeground else { return false }
            current.isInForeground = isInForeground
            current.generation &+= 1
            return true
        }
    }
}
