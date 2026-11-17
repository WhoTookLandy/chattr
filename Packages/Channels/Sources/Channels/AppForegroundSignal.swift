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
/// What it gates: background network work that nobody is looking at. The
/// EventSub socket can stay up in the background (background audio / PiP),
/// so its events keep reducing, but no live-event Helix request starts.
///
/// Sendable + lock-guarded: written on the main actor, read on session
/// actors.
public final class AppForegroundSignal: Sendable {
    private let state: OSAllocatedUnfairLock<Bool>

    public init(isInForeground: Bool = true) {
        state = OSAllocatedUnfairLock(initialState: isInForeground)
    }

    public var isInForeground: Bool {
        state.withLock { $0 }
    }

    /// Sets the flag. Returns whether it changed.
    @discardableResult
    func set(_ isInForeground: Bool) -> Bool {
        state.withLock { current in
            guard current != isInForeground else { return false }
            current = isInForeground
            return true
        }
    }
}
