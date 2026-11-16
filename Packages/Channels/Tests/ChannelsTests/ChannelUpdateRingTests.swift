import Testing
import Foundation
@testable import Channels

/// `ChannelUpdateRing` and `ChannelUpdateHub` are plain value types, so the
/// cap/compaction invariant and the buffer-then-commit window can be pinned
/// directly, without a session or a `TwitchClient`.
@Suite("ChannelUpdateRing / ChannelUpdateHub")
struct ChannelUpdateRingTests {

    /// A row-free update whose id we can read back.
    private func marker(_ id: String) -> ChannelUpdate {
        .messageDeleted(targetMessageId: id)
    }

    private func ids(_ updates: [ChannelUpdate]) -> [String] {
        updates.compactMap {
            if case .messageDeleted(let id) = $0 { return id }
            return nil
        }
    }

    private func message(id: String) -> ChannelUpdate {
        let line = "@id=\(id);room-id=1;user-id=2 :nick!nick@nick.tmi.twitch.tv PRIVMSG #ch :hi"
        return .normalizedMessage(
            IRCMessageParser.parse(line, channelLogin: "ch")!,
            timestamp: Date(timeIntervalSince1970: 0)
        )
    }

    // MARK: - Ring

    @Test("Appends past capacity keep the newest `capacity` updates in order")
    func capKeepsNewest() {
        var ring = ChannelUpdateRing(capacity: 3)
        for i in 0..<5 { ring.append(marker("\(i)")) }
        #expect(ids(ring.snapshot) == ["2", "3", "4"])
        #expect(ring.count == 3)
    }

    @Test("Compaction (once per `capacity` trims) preserves the live window")
    func compactionPreservesWindow() {
        var ring = ChannelUpdateRing(capacity: 4)
        // Enough appends to cross several compaction boundaries.
        for i in 0..<23 {
            ring.append(marker("\(i)"))
            let expected = (max(0, i - 3)...i).map { "\($0)" }
            #expect(ids(ring.snapshot) == expected)
        }
    }

    @Test("replace(with:) resets the window")
    func replaceResets() {
        var ring = ChannelUpdateRing(capacity: 3)
        for i in 0..<5 { ring.append(marker("\(i)")) }
        ring.replace(with: [marker("a")])
        #expect(ids(ring.snapshot) == ["a"])
        ring.append(marker("b"))
        #expect(ids(ring.snapshot) == ["a", "b"])
    }

    @Test("refreshMessages rewrites only live-window messages the transform returns")
    func refreshMessagesInLiveWindow() {
        var ring = ChannelUpdateRing(capacity: 2)
        ring.append(message(id: "old"))     // trimmed out of the window below
        ring.append(message(id: "m1"))
        ring.append(marker("x"))
        var seen: [String] = []
        let refreshed = ring.refreshMessages { stale in
            seen.append(stale.message.messageId)
            return stale
        }
        #expect(seen == ["m1"])
        #expect(refreshed == 1)
        let untouched = ring.refreshMessages { _ in nil }
        #expect(untouched == 0)
    }

    // MARK: - Hub

    @Test("Updates emitted before the backfill commit are parked, then merged after history")
    func hubBuffersUntilCommit() {
        var hub = ChannelUpdateHub(capacity: 10, channelLoginName: "ch")
        hub.emit([marker("live1")])
        #expect(hub.backfillPending)
        #expect(hub.snapshot.isEmpty)

        let buffered = hub.commitBackfill(history: [marker("h1")], divider: nil)
        #expect(buffered == 1)
        #expect(!hub.backfillPending)
        #expect(ids(hub.snapshot) == ["h1", "live1"])

        hub.emit([marker("live2")])
        #expect(ids(hub.snapshot) == ["h1", "live1", "live2"])
    }

    @Test("Emit posts each batch to every subscriber; removed subscribers get nothing")
    func hubDeliversToSubscribers() {
        var hub = ChannelUpdateHub(capacity: 10, channelLoginName: "ch")
        _ = hub.commitBackfill(history: [], divider: nil)
        let a = hub.addSubscriber()
        let b = hub.addSubscriber()
        hub.removeSubscriber(b.token)

        hub.emit([marker("1"), marker("2")])

        #expect(ids(a.takePending()) == ["1", "2"])
        #expect(b.takePending().isEmpty)
    }

    @Test("Backlog limit is twice the ring, never below 1000")
    func hubBacklogLimit() {
        #expect(ChannelUpdateHub(capacity: 10, channelLoginName: "ch").subscriberBacklogLimit == 1_000)
        #expect(ChannelUpdateHub(capacity: 800, channelLoginName: "ch").subscriberBacklogLimit == 1_600)
    }
}
