import Foundation

/// The signed-in user's own standing in one channel (timed out / banned /
/// warned), as a pure reducer over the signals that reveal it.
///
/// One copy lives on `ChannelSession` (the account × channel session, which
/// outlives any one chat page: the pager unmounts pages two swipes away, the
/// session stays while the tab is open) and one on the page's
/// `OwnChatRestrictionState`, which restores from the session's copy on
/// attach. Both run the same events through this reducer, so they agree.
///
/// Time is absolute: a known timeout stores its end `Date`, never a
/// remaining count, and `current(at:)` reads an ended timeout as nothing.
/// Expiry therefore needs no timer to be correct — a timer only tells a UI
/// when to look again.
public struct OwnChatRestrictionLedger: Sendable, Equatable {

    /// What happened. Sources:
    ///   - `.rejected` — a send was dropped / refused for our standing.
    ///   - `.ownMessagesCleared` — `channel.chat.clear_user_messages` for us.
    ///   - `.ownMessageDelivered` — Twitch broadcast one of ours.
    ///   - `.dismissed` — the user closed the banner.
    public enum Event: Sendable, Equatable {
        case rejected(OwnChatRestriction)
        case ownMessagesCleared
        case ownMessageDelivered
        case dismissed
    }

    /// The stored restriction, possibly an already-ended timeout; read it
    /// through `current(at:)`.
    public private(set) var stored: OwnChatRestriction?

    /// Bumped on every transition. A pending expiry timer captures the
    /// generation it was scheduled for and does nothing if it changed —
    /// so an old timeout's end can never lift a newer restriction.
    public private(set) var generation = 0

    public init() {}

    /// The restriction in force at `now`: nil once a known timeout ends.
    public func current(at now: Date = .now) -> OwnChatRestriction? {
        if case .timedOut(let until?)? = stored, until <= now { return nil }
        return stored
    }

    /// Applies `event`. Returns whether the in-force restriction (or the
    /// generation) changed.
    @discardableResult
    public mutating func apply(_ event: Event, now: Date = .now) -> Bool {
        switch event {
        case .rejected(let restriction):
            // A vague "timed out" (no duration) mustn't erase the end time we
            // already hold for the same running timeout.
            if case .timedOut(.none) = restriction,
               case .timedOut(let until?)? = stored, until > now {
                return false
            }
            return set(restriction)

        case .ownMessagesCleared:
            // A FRESH clear always wins, even over a known running timeout:
            // a mod may have extended it or turned it into a ban, and the
            // event carries no duration. Drop the old deadline (new
            // generation) and fall back to unknown-length until the next
            // send rejection refines it.
            stored = .removedByModerator
            generation &+= 1
            return true

        case .ownMessageDelivered:
            guard stored != nil else { return false }
            return set(nil)

        case .dismissed:
            return set(nil)
        }
    }

    private mutating func set(_ restriction: OwnChatRestriction?) -> Bool {
        guard stored != restriction else { return false }
        stored = restriction
        generation &+= 1
        return true
    }
}
