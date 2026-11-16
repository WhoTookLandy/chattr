import Foundation

/// A session's chat-restrictions snapshot plus the guard that keeps a
/// late-resolving Helix fetch from overwriting a fresher live update.
///
/// Storing the snapshot inside the session (rather than passing through Helix
/// every time the compose bar wants to render) means the compose bar reads
/// from a stable snapshot. EventSub `channel.chat_settings.update` events and
/// local settings PATCHes land as `applyLive`; the start-time Helix fetch
/// lands as `applyInitial`.
///
/// A value type owned by (and only ever mutated inside) `ChannelSession`.
struct ChatRestrictionsCache {

    /// The most recent snapshot from the start-time Helix fetch OR a live
    /// update. nil before we've seen either.
    private(set) var value: ChatRestrictions?

    /// True once a live update (EventSub `chat_settings.update`, or our own
    /// settings PATCH) has landed. Used by `applyInitial` to AVOID
    /// overwriting a fresh live update with a late-resolving Helix fetch.
    ///
    /// The race this prevents (CR MEDIUM 4):
    ///   1. `start()` kicks `refreshChatRestrictions()` (Helix in flight).
    ///   2. EventSub subscribe completes, broadcaster toggles slow mode,
    ///      a `chat_settings.update` event arrives BEFORE the Helix fetch
    ///      resolves.
    ///   3. `handle()` sets the cached value = X (new state).
    ///   4. Helix fetch completes with OLD state (snapshot taken before
    ///      the broadcaster's toggle).
    ///   5. Without the flag, the fetch overwrites the cached value with
    ///      stale Helix data → strip shows pre-toggle state until the next
    ///      event.
    ///
    /// With the flag, Helix backs off once a live update has arrived.
    /// EventSub is the authoritative live source after that.
    private(set) var isLive = false

    /// Commits an authoritative live snapshot — always wins.
    mutating func applyLive(_ restrictions: ChatRestrictions) {
        value = restrictions
        isLive = true
    }

    /// Commits the start-time Helix snapshot unless a live update already
    /// landed. Returns whether it was committed (the caller fans it out only
    /// then).
    mutating func applyInitial(_ restrictions: ChatRestrictions) -> Bool {
        guard !isLive else { return false }
        value = restrictions
        return true
    }
}
