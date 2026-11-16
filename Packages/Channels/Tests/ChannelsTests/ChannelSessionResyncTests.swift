import Testing
import Foundation
import TwitchKit
import ChatModel
@testable import Channels

/// Tests for the "New" messages divider and the reconnect gap-fill:
///
///   - `mergeBackfill(history:pendingLive:capacity:divider:)` — the join-time
///     placement: the divider must sit between rustlog history and the live
///     updates buffered during the fetch window, surviving dedup and the cap.
///   - `missingMessages(_:notIn:)` — the reconnect dedup: only messages the
///     ring doesn't already hold come back; a clean reconnect yields nothing.
///   - `resyncAfterReconnect()` — the actor path: the gap (dimmed history +
///     trailing divider) is committed and delivered as ONE contiguous batch.
///
/// Sessions are real but never `start()`ed; the injected `fetchBackfill`
/// keeps everything offline. Delivery is read straight off the subscriber's
/// mailbox: `emit` posts synchronously, so once an awaited session call
/// returns, its rows are already there.
@Suite("ChannelSession divider & reconnect gap-fill", .timeLimit(.minutes(1)))
struct ChannelSessionResyncTests {

    /// Build a real `ChatMessage` with a controllable `messageId` by going
    /// through the IRC parser (the only public path to a ChatMessage).
    private func chatMessage(id: String, text: String = "hi") -> ChatMessage {
        let line = "@id=\(id);room-id=1;user-id=2 :nick!nick@nick.tmi.twitch.tv PRIVMSG #ch :\(text)"
        return IRCMessageParser.parse(line, channelLogin: "ch")!
    }

    private func record(id: String) -> BackfillMessage {
        BackfillMessage(message: chatMessage(id: id), sentAt: nil)
    }

    private func message(id: String) -> ChannelUpdate {
        .normalizedMessage(chatMessage(id: id), timestamp: Date(timeIntervalSince1970: 0))
    }

    private func divider(id: String) -> ChannelUpdate {
        .row(ChatLine(id: id, kind: .newMessagesDivider, authorDisplayName: "", runs: [], timestamp: .distantPast))
    }

    /// Flatten an update list to a readable shape: message ids verbatim,
    /// dividers as "|" (minted ids are random) — position is what matters.
    private func shape(_ events: [ChannelUpdate]) -> [String] {
        events.compactMap {
            switch $0 {
            case .message(let m): return m.message.messageId
            case .row(let line) where line.kind == .newMessagesDivider: return "|"
            default: return nil
            }
        }
    }

    // MARK: - mergeBackfill divider placement

    @Test("Divider lands between history and buffered-live")
    func dividerBetweenHistoryAndLive() {
        let merged = ChannelSession.mergeBackfill(
            history: [message(id: "h1"), message(id: "h2")],
            pendingLive: [message(id: "m3")],
            capacity: 500,
            divider: divider(id: "div-1")
        )
        #expect(shape(merged) == ["h1", "h2", "|", "m3"])
    }

    @Test("Divider sits below a deduped overlap message (history position wins)")
    func dividerAfterDedupedOverlap() {
        // h2 came back from rustlog AND arrived live during the fetch — it
        // keeps its history slot, so it must stay ABOVE the divider.
        let merged = ChannelSession.mergeBackfill(
            history: [message(id: "h1"), message(id: "h2")],
            pendingLive: [message(id: "h2"), message(id: "m3")],
            capacity: 500,
            divider: divider(id: "div-1")
        )
        #expect(shape(merged) == ["h1", "h2", "|", "m3"])
    }

    @Test("Divider with no buffered-live ends the transcript")
    func dividerWithEmptyLiveTrails() {
        let merged = ChannelSession.mergeBackfill(
            history: [message(id: "h1")],
            pendingLive: [],
            capacity: 500,
            divider: divider(id: "div-1")
        )
        #expect(shape(merged) == ["h1", "|"])
    }

    @Test("Nil divider reproduces the pre-divider merge exactly")
    func nilDividerUnchanged() {
        let merged = ChannelSession.mergeBackfill(
            history: [message(id: "h1")],
            pendingLive: [message(id: "m2")],
            capacity: 500,
            divider: nil
        )
        #expect(shape(merged) == ["h1", "m2"])
    }

    @Test("Cap trims from the head — divider ages out like any update")
    func capTrimsDividerWithOldHistory() {
        let merged = ChannelSession.mergeBackfill(
            history: [message(id: "h1"), message(id: "h2")],
            pendingLive: [message(id: "m3"), message(id: "m4")],
            capacity: 2,
            divider: divider(id: "div-1")
        )
        // Full list h1, h2, div-1, m3, m4 → newest 2 survive.
        #expect(shape(merged) == ["m3", "m4"])
    }

    // MARK: - missingMessages

    @Test("Only messages the ring doesn't hold come back, in fetched order")
    func gapFillReturnsOnlyMissing() {
        let ring = [message(id: "m1"), message(id: "m2")]
        let fetched = [record(id: "m1"), record(id: "gap1"), record(id: "m2"), record(id: "gap2")]
        let missing = ChannelSession.missingMessages(fetched, notIn: ring)
        #expect(missing.map(\.message.messageId) == ["gap1", "gap2"])
    }

    @Test("Clean reconnect (nothing missed) yields nothing")
    func cleanReconnectYieldsNothing() {
        let ring = [message(id: "m1"), message(id: "m2")]
        #expect(ChannelSession.missingMessages([record(id: "m1"), record(id: "m2")], notIn: ring).isEmpty)
    }

    @Test("Non-message ring rows (bubbles, prior dividers) don't block dedup")
    func nonMessageRingRowsIgnored() {
        let ring: [ChannelUpdate] = [divider(id: "div-old"), .chatCleared, message(id: "m1")]
        let missing = ChannelSession.missingMessages([record(id: "m1"), record(id: "gap1")], notIn: ring)
        #expect(missing.map(\.message.messageId) == ["gap1"])
    }

    @Test("Empty ring treats the whole fetch as the gap")
    func emptyRingTakesEverything() {
        let missing = ChannelSession.missingMessages([record(id: "a"), record(id: "b")], notIn: [])
        #expect(missing.map(\.message.messageId) == ["a", "b"])
    }

    // MARK: - Actor path (offline via injected fetchBackfill)

    private actor FetchLog {
        var count = 0
        func recordFetch() { count += 1 }
    }

    /// Holds a fetch open until the test releases it.
    private actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            isOpen = true
            for waiter in waiters { waiter.resume() }
            waiters = []
        }
    }

    private struct NullTokenStore: TwitchTokenStore {
        func loadToken() async throws -> OAuthToken? { nil }
        func saveToken(_ token: OAuthToken) async throws {}
        func deleteToken() async throws {}
    }

    private func makeSession(
        fetches: FetchLog,
        gate: Gate? = nil,
        fetched: [BackfillMessage]
    ) -> ChannelSession {
        let client = TwitchClient(clientId: "test-client", tokenStore: NullTokenStore())
        return ChannelSession(
            client: client,
            channelId: "1",
            channelLoginName: "ch",
            accountUserId: "me",
            fetchBackfill: { _, _ in
                await fetches.recordFetch()
                await gate?.wait()
                return fetched
            }
        )
    }

    @Test("Resync commits dimmed gap + trailing divider to the ring and delivers it as one batch")
    func resyncCommitsAndDelivers() async throws {
        let fetches = FetchLog()
        let session = makeSession(fetches: fetches, fetched: [record(id: "m1"), record(id: "gap1")])
        // End the buffering window with m1 as history → ring: [m1, join-divider].
        await session.applyBackfill([record(id: "m1")])
        let (subscription, _) = await session.subscribe()

        await session.resyncAfterReconnect()

        // Ring: m1, join divider, gap1 (historical), resync divider — the
        // divider TRAILS the gap so it marks where live messages resume.
        let ring = await session.currentSnapshot()
        try #require(shape(ring) == ["m1", "|", "gap1", "|"])
        if case .message(let gap) = ring[2] {
            #expect(gap.line.isHistorical)   // gap-fill rows render dimmed
        } else {
            Issue.record("Expected the gap message above the divider, got \(ring[2])")
        }
        // Delivered: exactly the gap batch, divider last.
        #expect(shape(subscription.takePending()) == ["gap1", "|"])
    }

    @Test("A live message during the gap fetch can't land inside the delivered gap")
    func gapIsContiguousAroundLiveTraffic() async throws {
        let fetches = FetchLog()
        let gate = Gate()
        let session = makeSession(
            fetches: fetches,
            gate: gate,
            fetched: [record(id: "gap1"), record(id: "gap2")]
        )
        await session.applyBackfill([])
        let (subscription, _) = await session.subscribe()

        let resync = Task { await session.resyncAfterReconnect() }
        // Wait until the fetch is in flight (the actor is free meanwhile).
        while await fetches.count == 0 { await Task.yield() }
        await session.handle(event: .chatMessage(chatMessage(id: "live1")))
        await gate.open()
        await resync.value

        // Live traffic during the fetch precedes the gap; the gap and its
        // divider arrive back-to-back with nothing in between.
        #expect(shape(subscription.takePending()) == ["live1", "gap1", "gap2", "|"])
    }

    @Test("Clean resync (nothing missed) leaves the ring untouched and delivers nothing")
    func cleanResyncIsSilent() async {
        let fetches = FetchLog()
        let session = makeSession(fetches: fetches, fetched: [record(id: "m1")])
        await session.applyBackfill([record(id: "m1")])
        let (subscription, _) = await session.subscribe()

        await session.resyncAfterReconnect()

        let ring = await session.currentSnapshot()
        #expect(ring.count == 2)   // m1 + join divider, nothing added
        #expect(subscription.takePending().isEmpty)
        #expect(await fetches.count == 1)
    }

    @Test("Resync is skipped while the initial backfill is still pending")
    func resyncSkippedWhileBackfillPending() async {
        let fetches = FetchLog()
        let session = makeSession(fetches: fetches, fetched: [record(id: "gap1")])
        // No applyBackfill — the session is still in its buffering window.

        await session.resyncAfterReconnect()

        #expect(await fetches.count == 0)   // bailed before fetching
        #expect(await session.currentSnapshot().isEmpty)
    }

    // MARK: - Registry transition trigger

    @Test("Only a drop→connected transition counts as a reconnect recovery")
    @MainActor
    func reconnectRecoveryTransitions() {
        // Recoveries — gap-fill fires.
        #expect(ChannelSessionRegistry.isReconnectRecovery(from: .reconnecting, to: .connected))
        #expect(ChannelSessionRegistry.isReconnectRecovery(from: .waitingForNetwork, to: .connected))
        // Cold start — the join backfill covers it.
        #expect(!ChannelSessionRegistry.isReconnectRecovery(from: .connecting, to: .connected))
        // Repeated .connected (stream replays, no-op updates).
        #expect(!ChannelSessionRegistry.isReconnectRecovery(from: .connected, to: .connected))
        // Explicit teardown only comes back through a fresh start().
        #expect(!ChannelSessionRegistry.isReconnectRecovery(from: .disconnected, to: .connected))
        // Transitions INTO a non-connected state never fire.
        #expect(!ChannelSessionRegistry.isReconnectRecovery(from: .connected, to: .reconnecting))
        #expect(!ChannelSessionRegistry.isReconnectRecovery(from: .connected, to: .waitingForNetwork))
    }
}
