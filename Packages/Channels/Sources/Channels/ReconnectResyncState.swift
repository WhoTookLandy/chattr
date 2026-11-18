import Foundation

/// The bookkeeping of a session's reconnect gap-fill: at most one history
/// fetch at a time, at most one queued behind it, and where a gap began when
/// chat couldn't be subscribed again right away after a client rebind.
///
/// A gap is filled from a *floor*: nothing sent before it is taken. See
/// `ChannelSession.resyncAfterReconnect`.
///
/// A value type owned by (and only ever mutated inside) `ChannelSession`.
/// Nothing here awaits: the session does the fetching and asks this what to
/// do before and after each fetch.
struct ReconnectResyncState {

    /// True while a gap-fill is in flight. Set by `request` in the same
    /// actor turn that decides to fetch (before the session's first await),
    /// so back-to-back `.connected` transitions — flapping network, registry
    /// resyncing every session for the account — never run two history
    /// fetches at once.
    private(set) var isInFlight = false

    /// A resync was requested while one was in flight: its floor, kept so
    /// exactly one more fetch runs when the current one finishes. Coalesces
    /// any number of requests, keeping the earliest floor.
    private(set) var followUpFloor: Date?

    /// Set when a client rebind couldn't subscribe chat on the new client:
    /// where that gap began. The retry that subscribes it resyncs from here
    /// (the rebind's own resync ran before chat was back).
    private(set) var chatGapFloor: Date?

    /// A resync was asked for. Returns the floor to fetch from when the
    /// caller should start fetching now (and must call `finish()` when its
    /// loop ends), or nil when a fetch is already in flight: the request is
    /// queued behind it instead of dropped, because that fetch may have been
    /// answered before the newer gap existed.
    ///
    /// The floor is the earlier of `droppedAt` (when the socket was seen
    /// going down) and the newest live receipt — events that arrive after
    /// the reconnect, before the resync runs, must not move it past the gap.
    mutating func request(lastLiveReceiptAt: Date, droppedAt: Date?) -> Date? {
        let floor = min(lastLiveReceiptAt, droppedAt ?? lastLiveReceiptAt)
        guard !isInFlight else {
            followUpFloor = min(followUpFloor ?? floor, floor)
            return nil
        }
        isInFlight = true
        return floor
    }

    /// A fetch finished: the floor of the one follow-up to run next, if any
    /// request arrived meanwhile. Clears it.
    mutating func takeFollowUp() -> Date? {
        let floor = followUpFloor
        followUpFloor = nil
        return floor
    }

    /// The fetch loop ended (nothing queued, or the session stopped).
    mutating func finish() {
        isInFlight = false
    }

    /// A rebind finished subscribing on the new client. `chatFailed`: chat
    /// has to be retried, so the gap that began at `gapFloor` is still open.
    mutating func rebound(chatFailed: Bool, gapFloor: Date) {
        chatGapFloor = chatFailed ? gapFloor : nil
    }

    /// A retry round ended. If chat is subscribed again and a rebind left a
    /// gap open, returns its floor (once) for the caller to resync from.
    mutating func takeChatGapFloor(chatSubscribed: Bool) -> Date? {
        guard chatSubscribed, let floor = chatGapFloor else { return nil }
        chatGapFloor = nil
        return floor
    }
}
