import Foundation

/// The signed-in user's own standing in one channel (timed out / banned /
/// warned), as a pure reducer over the signals that reveal it.
///
/// The authoritative copy lives on `ChannelSession` (the account × channel
/// session, which outlives any one chat page: the pager unmounts pages two
/// swipes away, the session stays while the tab is open). It sees every
/// event in one order: self-clears and own echoes in `handle(event:)` as
/// they arrive, send rejections and dismissals when the page reports them.
/// A page's `OwnChatRestrictionState` only ever holds a COPY of it, and
/// adopts a newer copy by `generation` — so nothing a page does can
/// reorder events against each other.
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

    /// The generation the latest self-clear produced (0: none yet). A send
    /// rejection based on an older generation predates that clear — see
    /// `apply(_:basis:now:)`.
    public private(set) var lastClearGeneration = 0

    public init() {}

    /// The restriction in force at `now`: nil once a known timeout ends.
    public func current(at now: Date = .now) -> OwnChatRestriction? {
        if case .timedOut(let until?)? = stored, until <= now { return nil }
        return stored
    }

    /// Applies `event`. Returns whether the in-force restriction (or the
    /// generation) changed.
    ///
    /// - Parameter basis: for `.rejected`, the generation of this ledger the
    ///   sender held when the send STARTED. If a self-clear landed since
    ///   (`lastClearGeneration > basis`), the rejection describes the
    ///   restriction before that clear — e.g. "timed out for 30 more
    ///   seconds" from a timeout a mod has since extended or turned into a
    ///   ban — so it's dropped rather than allowed to restore a stale
    ///   deadline over the newer unknown-length state. nil = no basis
    ///   (applied unconditionally).
    @discardableResult
    public mutating func apply(_ event: Event, basis: Int? = nil, now: Date = .now) -> Bool {
        switch event {
        case .rejected(let restriction):
            if let basis, basis < lastClearGeneration {
                return false
            }
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
            lastClearGeneration = generation
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
