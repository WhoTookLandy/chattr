import Testing
import Foundation
import TwitchKit
import ChatModel
import EmoteSources
import Core
@testable import Channels

/// The session half of the message pipeline: events are normalized ONCE in
/// the session (with ids/timestamps minted once and stored), and delivered
/// to per-subscriber mailboxes without the session ever waiting on a
/// subscriber.
///
/// Sessions are real but never `start()`ed. `applyBackfill([])` ends the
/// buffering window so live events go straight to the ring.
@Suite("ChannelSession pipeline", .timeLimit(.minutes(1)))
struct ChannelSessionPipelineTests {

    private struct NullTokenStore: TwitchTokenStore {
        func loadToken() async throws -> OAuthToken? { nil }
        func saveToken(_ token: OAuthToken) async throws {}
        func deleteToken() async throws {}
    }

    private func makeSession(
        accountLogin: String = "me",
        ringCapacity: Int = 500,
        emoteIndex: EmoteIndex? = nil
    ) async -> ChannelSession {
        let session = ChannelSession(
            client: TwitchClient(clientId: "test-client", tokenStore: NullTokenStore()),
            channelId: "1",
            channelLoginName: "ch",
            accountUserId: "me-id",
            accountLogin: accountLogin,
            ringCapacity: ringCapacity,
            emoteIndex: emoteIndex,
            fetchBackfill: { _, _ in [] }
        )
        await session.applyBackfill([])
        return session
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    /// An EventSub `channel.chat.message` for channel "1". `fragmentsJSON`
    /// defaults to one text fragment holding `text`.
    private func chatEvent(id: String, text: String = "hello", fragmentsJSON: String? = nil) throws -> EventSubEvent {
        let fragments = fragmentsJSON ?? #"[{ "type": "text", "text": "\#(text)" }]"#
        let json = """
        {
            "message_id": "\(id)",
            "broadcaster_user_id": "1",
            "broadcaster_user_login": "ch",
            "broadcaster_user_name": "Ch",
            "chatter_user_id": "u-1",
            "chatter_user_login": "chatter",
            "chatter_user_name": "Chatter",
            "message": { "text": "\(text)", "fragments": \(fragments) },
            "color": "",
            "badges": [],
            "message_type": "text"
        }
        """
        return .chatMessage(try decoder.decode(ChatMessage.self, from: Data(json.utf8)))
    }

    private func raidEvent(from raiderId: String) throws -> EventSubEvent {
        let json = """
        {
            "from_broadcaster_user_id": "\(raiderId)",
            "from_broadcaster_user_login": "raider",
            "from_broadcaster_user_name": "Raider",
            "to_broadcaster_user_id": "1",
            "to_broadcaster_user_login": "ch",
            "to_broadcaster_user_name": "Ch",
            "viewers": 42
        }
        """
        return .raid(try decoder.decode(EventSubRaid.self, from: Data(json.utf8)))
    }

    private func settingsEvent(slowSeconds: Int) throws -> EventSubEvent {
        let json = """
        {
            "broadcaster_user_id": "1",
            "broadcaster_user_login": "ch",
            "broadcaster_user_name": "Ch",
            "emote_mode": false,
            "follower_mode": false,
            "follower_mode_duration_minutes": null,
            "slow_mode": true,
            "slow_mode_wait_time_seconds": \(slowSeconds),
            "subscriber_mode": false,
            "unique_chat_mode": false
        }
        """
        return .chatSettingsUpdate(try decoder.decode(EventSubChatSettingsUpdate.self, from: Data(json.utf8)))
    }

    private func ircRecord(id: String, text: String = "hi", sentAt: Date?) -> BackfillMessage {
        let line = "@id=\(id);room-id=1;user-id=2 :nick!nick@nick.tmi.twitch.tv PRIVMSG #ch :\(text)"
        return BackfillMessage(message: IRCMessageParser.parse(line, channelLogin: "ch")!, sentAt: sentAt)
    }

    private func lines(_ updates: [ChannelUpdate]) -> [ChatLine] {
        updates.compactMap {
            switch $0 {
            case .message(let normalized): return normalized.line
            case .row(let line): return line
            default: return nil
            }
        }
    }

    // MARK: - Normalize once, identical replays

    @Test("A live message is normalized once; every replay is the identical line")
    func liveMessageReplaysIdentically() async throws {
        let session = await makeSession()
        try await session.handle(event: chatEvent(id: "m1", text: "hello world"))

        let first = lines(await session.currentSnapshot())
        try await Task.sleep(for: .milliseconds(5))   // a re-normalize would pick a new clock
        let second = lines(await session.currentSnapshot())

        #expect(first.count == 1)
        #expect(first == second)
        #expect(first.first?.runs == [.text("hello"), .text("world")])
        #expect(first.first?.isHistorical == false)
    }

    @Test("Self-mentions are flagged by the session using its account login")
    func selfMentionFlaggedInSession() async throws {
        let session = await makeSession(accountLogin: "me")
        let fragments = #"""
        [{ "type": "mention", "text": "@me", "mention": { "user_id": "me-id", "user_login": "me", "user_name": "Me" } },
         { "type": "text", "text": " hi" }]
        """#
        try await session.handle(event: chatEvent(id: "m1", text: "@me hi", fragmentsJSON: fragments))

        let line = try #require(lines(await session.currentSnapshot()).first)
        #expect(line.runs.first == .mention(login: "me", isMe: true))
        #expect(line.isHighlighted)
    }

    @Test("A raid row's id and timestamp are minted once and survive every replay")
    func raidIdentityMintedOnce() async throws {
        let session = await makeSession()
        try await session.handle(event: raidEvent(from: "77"))

        let first = try #require(lines(await session.currentSnapshot()).first)
        try await Task.sleep(for: .milliseconds(5))
        let second = try #require(lines(await session.currentSnapshot()).first)

        #expect(first.id.hasPrefix("raid-77-"))
        #expect(first.id == second.id)
        #expect(first.timestamp == second.timestamp)
    }

    @Test("History rows carry tmi-sent-ts; lines without one share the batch's arrival time")
    func historyTimestamps() async throws {
        let session = ChannelSession(
            client: TwitchClient(clientId: "test-client", tokenStore: NullTokenStore()),
            channelId: "1",
            channelLoginName: "ch",
            accountUserId: "me-id",
            fetchBackfill: { _, _ in [] }
        )
        let sent = Date(timeIntervalSince1970: 1_700_000_000)
        await session.applyBackfill([
            ircRecord(id: "h1", sentAt: sent),
            ircRecord(id: "h2", sentAt: nil),
            ircRecord(id: "h3", sentAt: nil),
        ])

        let history = lines(await session.currentSnapshot()).filter { $0.kind == .message }
        try #require(history.count == 3)
        #expect(history[0].timestamp == sent)
        #expect(history[1].timestamp == history[2].timestamp)
        #expect(history.allSatisfy(\.isHistorical))
    }

    // MARK: - Delivery never waits on a subscriber

    @Test("A subscriber that never drains doesn't hold up handle() or other subscribers")
    func stalledSubscriberDoesNotBlock() async throws {
        let session = await makeSession()
        let (stalled, _) = await session.subscribe()
        let (healthy, _) = await session.subscribe()

        for i in 0..<3 {
            try await session.handle(event: chatEvent(id: "m\(i)"))
        }

        // handle() returned for every event (we got here), and the healthy
        // subscriber has all three without the stalled one draining anything.
        #expect(lines(healthy.takePending()).map(\.id) == ["m0", "m1", "m2"])
        #expect(lines(stalled.takePending()).map(\.id) == ["m0", "m1", "m2"])
    }

    @Test("Posts between drains come out as ONE batch behind one wakeup")
    func postsCoalesceIntoOneBatch() async throws {
        let session = await makeSession()
        let (subscription, _) = await session.subscribe()
        for i in 0..<5 {
            try await session.handle(event: chatEvent(id: "m\(i)"))
        }

        var wakeups = subscription.wakeups.makeAsyncIterator()
        let woke = await wakeups.next()
        #expect(woke != nil)
        #expect(subscription.takePending().count == 5)
        #expect(subscription.takePending().isEmpty)
    }

    @Test("A subscriber past its backlog cap gets one reprime of the ring, keeping the latest state update")
    func overflowingSubscriberIsReprimed() async throws {
        let session = await makeSession(ringCapacity: 5)
        let (subscription, _) = await session.subscribe()
        // Backlog cap is max(2 × ring, 1_000) = 1_000: the settings update
        // plus 999 messages fill it; the 1_000th message overflows.
        try await session.handle(event: settingsEvent(slowSeconds: 5))
        for i in 0..<1_000 {
            try await session.handle(event: chatEvent(id: "m\(i)"))
        }

        let pending = subscription.takePending()
        try #require(pending.count == 2)
        // Rows come back via the snapshot; the restrictions change can't, so
        // it rides along ahead of the reprime.
        guard case .restrictionsUpdated(let kept) = pending[0] else {
            Issue.record("Expected the carried restrictions first, got \(pending[0])")
            return
        }
        #expect(kept.slowModeSeconds == 5)
        guard case .reprime(let snapshot) = pending[1] else {
            Issue.record("Expected a reprime, got \(pending[1])")
            return
        }
        #expect(lines(snapshot).map(\.id) == ["m995", "m996", "m997", "m998", "m999"])   // exactly the ring
    }

    @Test("A state update that is itself refused for overflow still reaches the subscriber")
    func refusedStateUpdateIsCarried() async throws {
        let session = await makeSession(ringCapacity: 5)
        let (subscription, _) = await session.subscribe()
        for i in 0..<1_000 {
            try await session.handle(event: chatEvent(id: "m\(i)"))
        }
        try await session.handle(event: settingsEvent(slowSeconds: 9))   // the overflowing post

        let pending = subscription.takePending()
        try #require(pending.count == 2)
        guard case .restrictionsUpdated(let kept) = pending[0], case .reprime = pending[1] else {
            Issue.record("Expected [restrictions, reprime], got \(pending)")
            return
        }
        #expect(kept.slowModeSeconds == 9)
    }

    @Test("Unsubscribe ends the subscriber's wakeups")
    func unsubscribeEndsWakeups() async {
        let session = await makeSession()
        let (subscription, _) = await session.subscribe()
        await session.unsubscribe(subscription.token)

        var wakeups = subscription.wakeups.makeAsyncIterator()
        let woke = await wakeups.next()
        #expect(woke == nil)
    }

    @Test("subscribe(onBatch:) runs the handler on its own task, per batch")
    func batchHandlerReceivesUpdates() async throws {
        actor Received {
            var ids: [String] = []
            func add(_ batch: [ChannelUpdate]) {
                for case .message(let normalized) in batch { ids.append(normalized.message.messageId) }
            }
        }
        let received = Received()
        let session = await makeSession()
        let token = await session.subscribe(onBatch: { batch in await received.add(batch) })

        try await session.handle(event: chatEvent(id: "a"))
        try await session.handle(event: chatEvent(id: "b"))

        for _ in 0..<500 {
            if await received.ids.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(await received.ids == ["a", "b"])
        await session.unsubscribe(token)
    }

    // MARK: - Stale emote tables

    private struct OneEmoteProvider: EmoteProvider {
        let emote: Emote
        let globalCatalogKey = "pipeline-tests-\(UUID().uuidString)"
        func globalEmotes() async throws -> [Emote] { [] }
        func channelEmotes(broadcasterId: String, broadcasterLogin: String) async throws -> [Emote] { [emote] }
    }

    @Test("Rows normalized before the emote table loaded are refreshed when a tab subscribes")
    func staleRowsRenormalizedOnSubscribe() async throws {
        let kappa = Emote(
            id: "7tv:Kappa",
            name: "Kappa",
            urls: [.x1: URL(string: "https://cdn.example/kappa")!],
            isAnimated: false,
            isZeroWidth: false,
            source: .sevenTV,
            ownerChannelId: "1"
        )
        let index = EmoteIndex(
            providers: [OneEmoteProvider(emote: kappa)],
            cache: JSONDiskCache(
                subdirectory: "ch",
                baseDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("pipeline-tests-\(UUID().uuidString)", isDirectory: true)
            )
        )
        let session = await makeSession(emoteIndex: index)

        // Arrives before the channel's emotes are loaded → plain text.
        try await session.handle(event: chatEvent(id: "m1", text: "hi Kappa"))
        let before = try #require(lines(await session.currentSnapshot()).first)
        #expect(before.runs == [.text("hi"), .text("Kappa")])

        await index.load(broadcasterId: "1", broadcasterLogin: "ch")

        let (_, snapshot) = await session.subscribe()
        let after = try #require(lines(snapshot).first)
        try #require(after.runs.count == 2)
        #expect(after.runs[0] == .text("hi"))
        guard case .emote(let resolved) = after.runs[1] else {
            Issue.record("Expected Kappa to resolve as an emote, got \(after.runs[1])")
            return
        }
        #expect(resolved.name == "Kappa")
        // Same row identity and send time — only the runs were refreshed.
        #expect(after.id == before.id)
        #expect(after.timestamp == before.timestamp)
    }
}
