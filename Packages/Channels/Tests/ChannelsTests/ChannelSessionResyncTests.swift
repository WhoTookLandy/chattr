import Testing
import Foundation
import TwitchKit
@testable import Channels

/// Tests for the two pure functions behind the "New" messages divider:
///
///   - `mergeBackfill(history:pendingLive:capacity:divider:)` — the join-time
///     placement: the divider must sit between rustlog history and the live
///     events buffered during the fetch window, surviving dedup and the cap.
///   - `reconnectGapEvents(fetched:ring:dividerId:timestamp:)` — the
///     reconnect gap-fill: only messages the ring doesn't already hold come
///     back, prefixed with a divider; a clean reconnect yields nothing.
///
/// The actor-side commit paths (`applyBackfill`, `resyncAfterReconnect`) are
/// deliberately thin wrappers over these — same testing strategy as
/// `ChannelMergeTests`.
@Suite("ChannelSession divider & reconnect gap-fill")
struct ChannelSessionResyncTests {

    /// Build a real `ChatMessage` with a controllable `messageId` by going
    /// through the IRC parser (the only public path to a ChatMessage).
    private func chatMessage(id: String, text: String = "hi") -> ChatMessage {
        let line = "@id=\(id);room-id=1;user-id=2 :nick!nick@nick.tmi.twitch.tv PRIVMSG #ch :\(text)"
        return IRCMessageParser.parse(line, channelLogin: "ch")!
    }

    private func message(id: String) -> ChannelSession.ChannelEvent {
        .message(chatMessage(id: id))
    }

    /// Flatten an event list to a readable shape: message ids verbatim,
    /// dividers as their minted id (so position AND identity are asserted).
    private func ids(_ events: [ChannelSession.ChannelEvent]) -> [String] {
        events.compactMap {
            switch $0 {
            case .message(let m): return m.messageId
            case .newMessagesDivider(let id, _): return id
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
            divider: .newMessagesDivider(id: "div-1", timestamp: .now)
        )
        #expect(ids(merged) == ["h1", "h2", "div-1", "m3"])
    }

    @Test("Divider sits below a deduped overlap message (history position wins)")
    func dividerAfterDedupedOverlap() {
        // h2 came back from rustlog AND arrived live during the fetch — it
        // keeps its history slot, so it must stay ABOVE the divider.
        let merged = ChannelSession.mergeBackfill(
            history: [message(id: "h1"), message(id: "h2")],
            pendingLive: [message(id: "h2"), message(id: "m3")],
            capacity: 500,
            divider: .newMessagesDivider(id: "div-1", timestamp: .now)
        )
        #expect(ids(merged) == ["h1", "h2", "div-1", "m3"])
    }

    @Test("Divider with no buffered-live ends the transcript")
    func dividerWithEmptyLiveTrails() {
        let merged = ChannelSession.mergeBackfill(
            history: [message(id: "h1")],
            pendingLive: [],
            capacity: 500,
            divider: .newMessagesDivider(id: "div-1", timestamp: .now)
        )
        #expect(ids(merged) == ["h1", "div-1"])
    }

    @Test("Nil divider reproduces the pre-divider merge exactly")
    func nilDividerUnchanged() {
        let merged = ChannelSession.mergeBackfill(
            history: [message(id: "h1")],
            pendingLive: [message(id: "m2")],
            capacity: 500,
            divider: nil
        )
        #expect(ids(merged) == ["h1", "m2"])
    }

    @Test("Cap trims from the head — divider ages out like any event")
    func capTrimsDividerWithOldHistory() {
        let merged = ChannelSession.mergeBackfill(
            history: [message(id: "h1"), message(id: "h2")],
            pendingLive: [message(id: "m3"), message(id: "m4")],
            capacity: 2,
            divider: .newMessagesDivider(id: "div-1", timestamp: .now)
        )
        // Full list h1, h2, div-1, m3, m4 → newest 2 survive.
        #expect(ids(merged) == ["m3", "m4"])
    }

    // MARK: - reconnectGapEvents

    @Test("Only messages the ring doesn't hold come back, divider first")
    func gapFillReturnsOnlyMissing() {
        let ring = [message(id: "m1"), message(id: "m2")]
        let fetched = [
            chatMessage(id: "m1"),       // already have it
            chatMessage(id: "m2"),       // already have it
            chatMessage(id: "gap1"),     // missed during the drop
            chatMessage(id: "gap2"),
        ]
        let events = ChannelSession.reconnectGapEvents(
            fetched: fetched, ring: ring, dividerId: "div-r", timestamp: .now
        )
        #expect(ids(events) == ["div-r", "gap1", "gap2"])
    }

    @Test("Clean reconnect (nothing missed) yields no events — and no divider")
    func cleanReconnectYieldsNothing() {
        let ring = [message(id: "m1"), message(id: "m2")]
        let fetched = [chatMessage(id: "m1"), chatMessage(id: "m2")]
        let events = ChannelSession.reconnectGapEvents(
            fetched: fetched, ring: ring, dividerId: "div-r", timestamp: .now
        )
        #expect(events.isEmpty)
    }

    @Test("Fetched order is preserved for the gap block")
    func gapPreservesFetchedOrder() {
        let events = ChannelSession.reconnectGapEvents(
            fetched: [chatMessage(id: "a"), chatMessage(id: "b"), chatMessage(id: "c")],
            ring: [message(id: "b")],
            dividerId: "div-r",
            timestamp: .now
        )
        #expect(ids(events) == ["div-r", "a", "c"])
    }

    @Test("Non-message ring events (bubbles, prior dividers) don't block dedup")
    func nonMessageRingEventsIgnored() {
        let ring: [ChannelSession.ChannelEvent] = [
            .newMessagesDivider(id: "div-old", timestamp: .now),
            .chatCleared,
            message(id: "m1"),
        ]
        let events = ChannelSession.reconnectGapEvents(
            fetched: [chatMessage(id: "m1"), chatMessage(id: "gap1")],
            ring: ring,
            dividerId: "div-r",
            timestamp: .now
        )
        #expect(ids(events) == ["div-r", "gap1"])
    }

    @Test("Empty ring treats the whole fetch as the gap")
    func emptyRingTakesEverything() {
        let events = ChannelSession.reconnectGapEvents(
            fetched: [chatMessage(id: "a"), chatMessage(id: "b")],
            ring: [],
            dividerId: "div-r",
            timestamp: .now
        )
        #expect(ids(events) == ["div-r", "a", "b"])
    }

    // MARK: - Actor path (offline via injected fetchBackfill)

    /// Order-preserving sink for fan-out events and fetch invocations.
    private actor Recorder {
        var events: [ChannelSession.ChannelEvent] = []
        var fetchCount = 0
        func record(_ event: ChannelSession.ChannelEvent) { events.append(event) }
        func recordFetch() { fetchCount += 1 }
    }

    /// Real but never-`start()`ed session — the injected `fetchBackfill`
    /// keeps the resync path entirely offline (same NullTokenStore pattern
    /// as TabChatModelModerationTests).
    private func makeSession(
        recorder: Recorder,
        fetched: [ChatMessage]
    ) -> ChannelSession {
        struct NullTokenStore: TwitchTokenStore {
            func loadToken() async throws -> OAuthToken? { nil }
            func saveToken(_ token: OAuthToken) async throws {}
            func deleteToken() async throws {}
        }
        let client = TwitchClient(clientId: "test-client", tokenStore: NullTokenStore())
        return ChannelSession(
            client: client,
            channelId: "1",
            channelLoginName: "ch",
            accountUserId: "me",
            fetchBackfill: { _, _ in
                await recorder.recordFetch()
                return fetched
            }
        )
    }

    @Test("Resync commits divider + missing to the ring and fans them out in order")
    func resyncCommitsAndFansOut() async {
        let recorder = Recorder()
        let session = makeSession(
            recorder: recorder,
            fetched: [chatMessage(id: "m1"), chatMessage(id: "gap1")]
        )
        // End the buffering window with m1 as history → ring: [m1, join-divider].
        await session.applyBackfill([chatMessage(id: "m1")])
        _ = await session.subscribe { event in await recorder.record(event) }

        await session.resyncAfterReconnect()

        // Ring: m1, join divider, resync divider, gap1.
        let ring = await session.currentSnapshot()
        let ringIds = ids(ring)
        #expect(ringIds.count == 4)
        #expect(ringIds.first == "m1")
        #expect(ringIds.last == "gap1")
        if case .newMessagesDivider = ring[2] {} else {
            Issue.record("Expected a divider at the gap position, got \(ring[2])")
        }
        // Fan-out delivered exactly the gap batch, divider first. The fan-out
        // TaskGroup is awaited inside resyncAfterReconnect, so no waiting here.
        let received = await recorder.events
        #expect(ids(received).last == "gap1")
        #expect(received.count == 2)
        if case .newMessagesDivider = received[0] {} else {
            Issue.record("Expected the divider to fan out first, got \(received[0])")
        }
    }

    @Test("Clean resync (nothing missed) leaves the ring untouched and fans out nothing")
    func cleanResyncIsSilent() async {
        let recorder = Recorder()
        let session = makeSession(recorder: recorder, fetched: [chatMessage(id: "m1")])
        await session.applyBackfill([chatMessage(id: "m1")])
        _ = await session.subscribe { event in await recorder.record(event) }

        await session.resyncAfterReconnect()

        let ring = await session.currentSnapshot()
        #expect(ring.count == 2)   // m1 + join divider, nothing added
        #expect(await recorder.events.isEmpty)
        #expect(await recorder.fetchCount == 1)
    }

    @Test("Resync is skipped while the initial backfill is still pending")
    func resyncSkippedWhileBackfillPending() async {
        let recorder = Recorder()
        let session = makeSession(recorder: recorder, fetched: [chatMessage(id: "gap1")])
        // No applyBackfill — the session is still in its buffering window.

        await session.resyncAfterReconnect()

        #expect(await recorder.fetchCount == 0)   // bailed before fetching
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
