import Testing
import Foundation
import TwitchKit
import ChatModel
@testable import Channels

/// The bounded join-history wait in `start()`: `beginJoinBackfill()` +
/// `finishJoinBackfill()` are the two halves `start()` wraps around its
/// EventSub connect/subscribe, driven directly here so no socket is needed.
/// The injected `fetchBackfill` is held on a `Gate` to make "history is late"
/// deterministic.
@Suite("ChannelSession join backfill deadline", .timeLimit(.minutes(1)))
struct ChannelSessionJoinBackfillTests {

    private struct NullTokenStore: TwitchTokenStore {
        func loadToken() async throws -> OAuthToken? { nil }
        func saveToken(_ token: OAuthToken) async throws {}
        func deleteToken() async throws {}
    }

    /// Holds the history fetch open until the test releases it.
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

    private func chatMessage(id: String) -> ChatMessage {
        let line = "@id=\(id);room-id=1;user-id=2 :nick!nick@nick.tmi.twitch.tv PRIVMSG #ch :hi"
        return IRCMessageParser.parse(line, channelLogin: "ch")!
    }

    private func record(_ id: String) -> BackfillMessage {
        BackfillMessage(message: chatMessage(id: id), sentAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private func makeSession(
        gate: Gate,
        history: [BackfillMessage],
        timeout: Duration
    ) -> ChannelSession {
        ChannelSession(
            client: TwitchClient(clientId: "test-client", tokenStore: NullTokenStore()),
            channelId: "1",
            channelLoginName: "ch",
            accountUserId: "me",
            fetchBackfill: { _, _ in
                await gate.wait()
                return history
            },
            joinBackfillTimeout: timeout
        )
    }

    /// Message ids in order, dividers as "|".
    private func shape(_ updates: [ChannelUpdate]) -> [String] {
        updates.compactMap {
            switch $0 {
            case .message(let m): return m.message.messageId
            case .row(let line) where line.kind == .newMessagesDivider: return "|"
            default: return nil
            }
        }
    }

    @Test("History that beats the deadline is merged ahead of buffered live rows")
    func onTimeHistoryMerges() async {
        let gate = Gate()
        let session = makeSession(gate: gate, history: [record("h1"), record("h2")], timeout: .seconds(30))

        await session.beginJoinBackfill()
        await session.handle(event: .chatMessage(chatMessage(id: "live1")))   // buffered
        await gate.open()
        await session.finishJoinBackfill()

        #expect(shape(await session.currentSnapshot()) == ["h1", "h2", "|", "live1"])
    }

    @Test("Late history: the session opens at the deadline, then merges history above live rows")
    func lateHistoryMergesAboveLive() async throws {
        let gate = Gate()
        let session = makeSession(gate: gate, history: [record("h1"), record("h2"), record("live1")], timeout: .milliseconds(50))

        await session.beginJoinBackfill()
        await session.handle(event: .chatMessage(chatMessage(id: "live1")))
        let started = ContinuousClock.now
        await session.finishJoinBackfill()

        // Exposed on the deadline with live chat only — no history, no divider.
        #expect(ContinuousClock.now - started < .seconds(10))
        #expect(shape(await session.currentSnapshot()) == ["live1"])

        let (subscription, snapshot) = await session.subscribe()
        #expect(shape(snapshot) == ["live1"])
        // The start-time restrictions fetch resolves while the subscriber
        // hasn't drained yet — it must survive the reprime below.
        await session.applyInitialRestrictions(ChatRestrictions(slowModeSeconds: 7))

        // History lands late: deduped against the ring (live1 is already
        // there), placed ABOVE the live rows with the join divider between,
        // and handed to the subscriber as one reprime of the new ring.
        await gate.open()
        try await waitUntilSettled(session)
        #expect(shape(await session.currentSnapshot()) == ["h1", "h2", "|", "live1"])

        let pending = subscription.takePending()
        try #require(pending.count == 2)
        guard case .restrictionsUpdated(let restrictions) = pending[0] else {
            Issue.record("Expected the pending restrictions to be carried, got \(pending[0])")
            return
        }
        #expect(restrictions.slowModeSeconds == 7)
        guard case .reprime(let reprimed) = pending[1] else {
            Issue.record("Expected a reprime, got \(pending[1])")
            return
        }
        #expect(shape(reprimed) == ["h1", "h2", "|", "live1"])
    }

    @Test("Late history that adds nothing new leaves the ring and subscribers alone")
    func lateDuplicateHistoryIsSilent() async throws {
        let gate = Gate()
        let session = makeSession(gate: gate, history: [record("live1")], timeout: .milliseconds(20))

        await session.beginJoinBackfill()
        await session.handle(event: .chatMessage(chatMessage(id: "live1")))
        await session.finishJoinBackfill()
        let (subscription, _) = await session.subscribe()

        await gate.open()
        try await waitUntilSettled(session)

        #expect(shape(await session.currentSnapshot()) == ["live1"])
        #expect(subscription.takePending().isEmpty)
    }

    @Test("Late history the ring has no room for is dropped without resetting subscribers")
    func lateHistoryWithoutRoomIsDropped() async throws {
        let gate = Gate()
        let session = ChannelSession(
            client: TwitchClient(clientId: "test-client", tokenStore: NullTokenStore()),
            channelId: "1",
            channelLoginName: "ch",
            accountUserId: "me",
            ringCapacity: 2,
            fetchBackfill: { _, _ in
                await gate.wait()
                return [BackfillMessage(message: IRCMessageParser.parse(
                    "@id=h1;room-id=1;user-id=2 :nick!nick@nick.tmi.twitch.tv PRIVMSG #ch :hi",
                    channelLogin: "ch"
                )!, sentAt: nil)]
            },
            joinBackfillTimeout: .milliseconds(20)
        )

        await session.beginJoinBackfill()
        await session.handle(event: .chatMessage(chatMessage(id: "live1")))
        await session.handle(event: .chatMessage(chatMessage(id: "live2")))
        await session.finishJoinBackfill()
        let (subscription, _) = await session.subscribe()

        await gate.open()
        try await waitUntilSettled(session)

        // The ring is full of live rows; history (oldest) would be trimmed
        // straight back out, so nothing changes — no orphan divider either.
        #expect(shape(await session.currentSnapshot()) == ["live1", "live2"])
        #expect(subscription.takePending().isEmpty)
    }

    @Test("A cancelled start stops waiting for history immediately")
    func cancellationEndsTheWait() async {
        let gate = Gate()
        let session = makeSession(gate: gate, history: [record("h1")], timeout: .seconds(60))

        await session.beginJoinBackfill()
        let finishing = Task { await session.finishJoinBackfill() }
        while !(await session.isWaitingForJoinBackfill) {
            await Task.yield()
        }

        finishing.cancel()
        await finishing.value   // returns promptly, not after 60s

        await gate.open()       // let the parked fetch closure finish
    }

    /// Spin until the join history has been applied or merged.
    private func waitUntilSettled(_ session: ChannelSession) async throws {
        for _ in 0..<1_000 {
            if await session.isJoinBackfillSettled { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("join history never settled")
    }

    @Test("stop() releases a start() still waiting on history")
    func stopReleasesWaiter() async {
        let gate = Gate()
        let session = makeSession(gate: gate, history: [record("h1")], timeout: .seconds(60))

        await session.beginJoinBackfill()
        let finishing = Task { await session.finishJoinBackfill() }
        while !(await session.isWaitingForJoinBackfill) {
            await Task.yield()
        }

        await session.stop()
        await finishing.value   // returns promptly, not after 60s

        await gate.open()       // let the parked fetch closure finish
    }
}
