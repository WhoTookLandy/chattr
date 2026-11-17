import Testing
import Foundation
import TwitchKit
import ChatModel
@testable import Channels
@testable import Features

/// The transcript half of the message pipeline: rows arrive normalized by
/// the session, in batches drained from a subscription mailbox; the model
/// layers this attach's keyword highlight on top, applies a batch per
/// main-actor turn, and rebuilds on `.reprime` without losing local sends.
///
/// `@testable import Channels` reaches `ChannelSession.handle(event:)` so the
/// end-to-end tests can inject a live event into a real (never-started)
/// session without a socket.
@Suite("ChatTranscriptModel pipeline", .timeLimit(.minutes(1)))
@MainActor
struct ChatTranscriptModelPipelineTests {

    private struct NullTokenStore: TwitchTokenStore {
        func loadToken() async throws -> OAuthToken? { nil }
        func saveToken(_ token: OAuthToken) async throws {}
        func deleteToken() async throws {}
    }

    private func makeSession(accountLogin: String = "me") -> ChannelSession {
        ChannelSession(
            client: TwitchClient(clientId: "test-client", tokenStore: NullTokenStore()),
            channelId: "chan-1",
            channelLoginName: "somechannel",
            accountUserId: "me-1",
            accountLogin: accountLogin,
            fetchBackfill: { _, _ in [] }
        )
    }

    private func chatMessage(id: String, userId: String = "u-1", text: String = "hello") -> ChatMessage {
        let json = """
        {
            "message_id": "\(id)",
            "broadcaster_user_id": "chan-1",
            "broadcaster_user_login": "somechannel",
            "broadcaster_user_name": "SomeChannel",
            "chatter_user_id": "\(userId)",
            "chatter_user_login": "chatter",
            "chatter_user_name": "Chatter",
            "message": {
                "text": "\(text)",
                "fragments": [{ "type": "text", "text": "\(text)" }]
            },
            "color": "",
            "badges": [],
            "message_type": "text"
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try! decoder.decode(ChatMessage.self, from: Data(json.utf8))
    }

    /// `isHistorical` rows still get keyword highlighting but never play
    /// the highlight sound — tests that highlight use them to stay silent.
    private func message(_ id: String, text: String = "hello", isHistorical: Bool = false) -> ChannelUpdate {
        .normalizedMessage(
            chatMessage(id: id, text: text),
            isHistorical: isHistorical,
            timestamp: Date(timeIntervalSince1970: 0)
        )
    }

    /// Spin the main actor until the consumer task has applied what the
    /// session posted (delivery is asynchronous by design).
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    // MARK: - Batches

    @Test("A drained batch applies in one turn and publishes as ONE version")
    func batchPublishesOnce() {
        let model = ChatTranscriptModel()
        model.apply([message("a"), message("b"), message("c")])
        #expect(model.lines.map(\.id) == ["a", "b", "c"])
        #expect(model.changeVersion == 0)
        model.flushPendingChanges()
        #expect(model.changeVersion == 1)
        guard case .changes(let changes, through: 1) = model.changes(since: 0) else {
            Issue.record("expected one replayable version"); return
        }
        #expect(changes.count == 3)
    }

    // MARK: - Highlighting

    @Test("This attach's keywords are layered onto session rows; another attach of the same session is unaffected")
    func keywordHighlightIsPerAttach() async {
        let session = makeSession()
        let withKeywords = ChatTranscriptModel()
        await withKeywords.attach(sessions: [session], currentUserId: "me-1", highlightKeywords: ["clip"])
        let withoutKeywords = ChatTranscriptModel()
        await withoutKeywords.attach(sessions: [session], currentUserId: "me-1")

        let row = message("m1", text: "watch this Clip", isHistorical: true)
        withKeywords.apply(row)
        withoutKeywords.apply(row)
        withKeywords.apply(message("m2", text: "nothing here", isHistorical: true))

        #expect(withKeywords.lines.map(\.isHighlighted) == [true, false])
        #expect(withoutKeywords.lines.map(\.isHighlighted) == [false])
        await withKeywords.detach()
        await withoutKeywords.detach()
    }

    @Test("A session-flagged self-mention stays highlighted with no keywords configured")
    func sessionSelfMentionSurvives() {
        let model = ChatTranscriptModel()
        var line = ChatLine(
            id: "m1",
            authorDisplayName: "Chatter",
            runs: [.mention(login: "me", isMe: true)],
            isHistorical: true   // keeps the highlight sound out of the test
        )
        line.isHighlighted = true
        model.apply(.message(NormalizedMessage(message: chatMessage(id: "m1"), line: line)))
        #expect(model.lines.first?.isHighlighted == true)
    }

    // MARK: - Reprime

    @Test("Reprime rebuilds from the snapshot and keeps local (failed) send rows")
    func reprimeKeepsLocalRows() async throws {
        let model = ChatTranscriptModel()
        await model.attach(sessions: [makeSession()], currentUserId: "me-1", currentUserLogin: "me")
        model.apply(message("old"))

        // Offline: the token lookup throws before any request, so the
        // optimistic row settles as `.failed` right away.
        await model.send(text: "my message")
        let local = try #require(model.lines.last)
        guard case .failed = local.deliveryState else {
            Issue.record("expected the offline send to fail, got \(local.deliveryState)"); return
        }

        model.apply(.reprime([message("h1"), message("h2")]))

        #expect(model.lines.map(\.id) == ["h1", "h2", local.id])
        await model.detach()
    }

    @Test("A reprime reaches readers as ONE wholesale reset, kept local rows included")
    func reprimePublishesOneReset() async throws {
        let model = ChatTranscriptModel()
        await model.attach(sessions: [makeSession()], currentUserId: "me-1", currentUserLogin: "me")
        model.apply(message("old"))
        // Offline, so the send fails at once and stays as a local row.
        await model.send(text: "my message")
        let local = try #require(model.lines.last)
        let before = model.transcriptSnapshot().version

        model.apply(.reprime([message("h1"), message("old")]))

        let rebuilt = model.lines
        #expect(rebuilt.map(\.id) == ["h1", "old", local.id])
        // Not `.reset([])` plus an append per row: a list in scrollback
        // applies resets at once and holds appends back.
        #expect(model.changes(since: before) == .changes([.reset(rebuilt)], through: before + 1))
        await model.detach()
    }

    @Test("An own echo arriving inside a reprime settles its in-flight send instead of duplicating it")
    func reprimeSettlesInFlightSendByEcho() async throws {
        let session = ChannelSession(
            client: TwitchClient(clientId: "test-client", tokenStore: NullTokenStore()),
            channelId: "chan-1",
            channelLoginName: "somechannel",
            accountUserId: "me-1",
            accountLogin: "me",
            // Offline send → notAuthenticated → token refresh. Parking the
            // refresh holds the optimistic row in `.sending`.
            refreshTokenHandler: { try await Task.sleep(for: .seconds(30)) },
            fetchBackfill: { _, _ in [] }
        )
        let model = ChatTranscriptModel()
        await model.attach(sessions: [session], currentUserId: "me-1", currentUserLogin: "me")
        let sending = Task { await model.send(text: "hi there") }
        try await waitUntil { model.lines.last?.deliveryState == .sending }
        try #require(model.lines.last?.deliveryState == .sending)

        // The echo was in the backlog the reprime replaced; it reaches the
        // transcript only inside the snapshot.
        let echo = ChannelUpdate.normalizedMessage(
            chatMessage(id: "echo-1", userId: "me-1", text: "hi there"),
            timestamp: Date(timeIntervalSince1970: 0)
        )
        model.apply(.reprime([message("h1"), echo]))
        #expect(model.lines.map(\.id) == ["h1", "echo-1"])

        // The settled send's failure path finds no row to resurrect.
        sending.cancel()
        await sending.value
        #expect(model.lines.map(\.id) == ["h1", "echo-1"])
        await model.detach()
    }

    // MARK: - End to end

    @Test("A live event posted by the session reaches an attached transcript")
    func liveEventReachesTranscript() async throws {
        let session = makeSession()
        let model = ChatTranscriptModel()
        await model.attach(sessions: [session], currentUserId: "me-1")

        await session.handle(event: .chatMessage(chatMessage(id: "live-1", text: "hi")))
        try await waitUntil { model.lines.contains { $0.id == "live-1" } }

        #expect(model.lines.map(\.id) == ["live-1"])
        await model.detach()
    }

    @Test("After detach, nothing the session posts lands in the transcript")
    func detachStopsDelivery() async throws {
        let session = makeSession()
        let model = ChatTranscriptModel()
        await model.attach(sessions: [session], currentUserId: "me-1")
        await session.handle(event: .chatMessage(chatMessage(id: "before")))
        try await waitUntil { !model.lines.isEmpty }

        await model.detach()
        await session.handle(event: .chatMessage(chatMessage(id: "after")))
        try await Task.sleep(for: .milliseconds(30))

        #expect(model.lines.map(\.id) == ["before"])
    }
}
