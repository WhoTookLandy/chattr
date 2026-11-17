import Foundation

/// The signed-in user's own standing in one channel (timed out / banned /
/// warned), as a pure reducer over the signals that reveal it.
///
/// The authoritative copy lives on `ChannelSession` (the account × channel
/// session, which outlives any one chat page: the pager unmounts pages two
/// swipes away, the session stays while the tab is open). Every signal is
/// recorded there, in one order: self-clears and own echoes in
/// `handle(event:)` as they arrive, send outcomes in `send(...)`, dismissals
/// when the page reports them. A page's `OwnChatRestrictionState` only ever
/// holds a COPY of it, and adopts a newer copy by `generation` — so nothing
/// a page does can reorder events against each other.
///
/// ## Ordering send outcomes
///
/// A send's answer can arrive long after the send started, so it may
/// describe a standing that has since changed. One monotonically increasing
/// `sequence` marks those changes: every self-clear and every own echo
/// advances it. A send captures it when it starts (`beginSend()`) and its
/// outcome is applied only if it's still current (`finishSend`) — an older
/// rejection can neither restore a deadline a newer clear superseded nor
/// reinstate a restriction a newer echo lifted.
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

    /// Bumped on every transition. A page adopts a copy only if its
    /// generation is newer; a pending expiry timer captures the generation
    /// it was scheduled for and does nothing if it changed — so an old
    /// timeout's end can never lift a newer restriction.
    public private(set) var generation = 0

    /// Advanced by every self-clear and every observed own echo: a send
    /// outcome captured at an older value is stale. See the type docs.
    public private(set) var sequence = 0

    /// Sends started (`beginSend`) and not yet finished.
    public private(set) var sendsInFlight = 0

    public init() {}

    /// The restriction in force at `now`: nil once a known timeout ends.
    public func current(at now: Date = .now) -> OwnChatRestriction? {
        if case .timedOut(let until?)? = stored, until <= now { return nil }
        return stored
    }

    /// Whether an own echo matters: only while restricted (it lifts that)
    /// or while a send is in flight (it makes that send's outcome stale).
    /// Otherwise — nearly always — the per-message path skips it.
    public var observesOwnEchoes: Bool {
        stored != nil || sendsInFlight > 0
    }

    /// Applies `event` unconditionally. Returns whether the in-force
    /// restriction (or the generation) changed.
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
            sequence &+= 1
            stored = .removedByModerator
            generation &+= 1
            return true

        case .ownMessageDelivered:
            sequence &+= 1
            guard stored != nil else { return false }
            return set(nil)

        case .dismissed:
            return set(nil)
        }
    }

    /// A send is starting: returns the `sequence` its outcome is judged
    /// against in `finishSend`.
    public mutating func beginSend() -> Int {
        sendsInFlight += 1
        return sequence
    }

    /// The send started at `basis` finished. A `rejection` is applied only
    /// if no self-clear or own echo happened since it started; otherwise
    /// it describes an older standing and is dropped. Every `beginSend`
    /// must be balanced by exactly one call, rejection or not.
    @discardableResult
    public mutating func finishSend(basis: Int, rejection: OwnChatRestriction?, now: Date = .now) -> Bool {
        sendsInFlight = max(sendsInFlight - 1, 0)
        guard let rejection, basis == sequence else { return false }
        return apply(.rejected(rejection), now: now)
    }

    private mutating func set(_ restriction: OwnChatRestriction?) -> Bool {
        guard stored != restriction else { return false }
        stored = restriction
        generation &+= 1
        return true
    }
}
