import Testing
import Foundation
@testable import Channels

/// Tests for `ChannelHistoryMerge.mergeBackfill` — the pure function that merges
/// rustlog history with live updates that arrived (and were buffered) while
/// the backfill fetch was in flight.
///
/// These cover the three things the merge MUST get right:
///   1. Ordering — history (oldest scrollback) comes before buffered-live.
///   2. Dedup — the overlap window means the same `messageId` can appear in
///      both rustlog history AND the live buffer; it must survive exactly once.
///   3. Cap — the result is bounded to `capacity`, keeping the newest updates.
@Suite("ChannelHistoryMerge.mergeBackfill")
struct ChannelMergeTests {

    /// Build a real message update with a controllable `messageId` by going
    /// through the IRC parser (the only public path to a ChatMessage).
    private func message(id: String, text: String = "hi") -> ChannelUpdate {
        let line = "@id=\(id);room-id=1;user-id=2 :nick!nick@nick.tmi.twitch.tv PRIVMSG #ch :\(text)"
        return .normalizedMessage(
            IRCMessageParser.parse(line, channelLogin: "ch")!,
            timestamp: Date(timeIntervalSince1970: 0)
        )
    }

    /// Extract the ordered list of messageIds from a merged update list.
    private func ids(_ events: [ChannelUpdate]) -> [String] {
        events.compactMap {
            if case .message(let m) = $0 { return m.message.messageId }
            return nil
        }
    }

    @Test("History precedes buffered-live, each in arrival order")
    func ordersHistoryThenLive() {
        let history = [message(id: "h1"), message(id: "h2")]
        let live = [message(id: "m3"), message(id: "m4")]

        let merged = ChannelHistoryMerge.mergeBackfill(history: history, pendingLive: live, capacity: 500)

        #expect(ids(merged) == ["h1", "h2", "m3", "m4"])
    }

    @Test("Overlap is deduped by messageId, keeping the history position")
    func dedupesOverlapByMessageId() {
        // h3 was returned by rustlog AND also arrived live during the fetch
        // window — it must appear exactly once, at its chronological spot.
        let history = [message(id: "h1"), message(id: "h2"), message(id: "h3")]
        let live = [message(id: "h3"), message(id: "m4")]

        let merged = ChannelHistoryMerge.mergeBackfill(history: history, pendingLive: live, capacity: 500)

        #expect(ids(merged) == ["h1", "h2", "h3", "m4"])
    }

    @Test("Result is capped to capacity, retaining the newest updates")
    func capsToCapacityKeepingNewest() {
        let history = (1...5).map { message(id: "h\($0)") }
        let live = [message(id: "m6"), message(id: "m7")]

        let merged = ChannelHistoryMerge.mergeBackfill(history: history, pendingLive: live, capacity: 3)

        // Full chronological list is h1..h5, m6, m7 → newest 3 survive.
        #expect(ids(merged) == ["h5", "m6", "m7"])
    }

    @Test("Empty backfill yields the buffered-live updates unchanged")
    func emptyHistoryKeepsLive() {
        let live = [message(id: "m1"), message(id: "m2")]

        let merged = ChannelHistoryMerge.mergeBackfill(history: [], pendingLive: live, capacity: 500)

        #expect(ids(merged) == ["m1", "m2"])
    }
}
