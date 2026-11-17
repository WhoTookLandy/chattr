import Testing
import Foundation
import TwitchKit
import ChatModel
import Channels
@testable import Features

/// `ChatTranscriptModel` with its side effects injected
/// (`ChatTranscriptDependencies`): chat-filter settings, draft clearing and
/// the highlight sound are observed through fakes instead of UserDefaults,
/// `DraftStorage` and the speaker. Sessions are real but never started, as in
/// `ChatTranscriptModelModerationTests`.
@Suite("ChatTranscriptModel injected side effects")
@MainActor
struct ChatTranscriptModelDependencyTests {

    private struct NullTokenStore: TwitchTokenStore {
        func loadToken() async throws -> OAuthToken? { nil }
        func saveToken(_ token: OAuthToken) async throws {}
        func deleteToken() async throws {}
    }

    /// What the fakes saw.
    private final class Recorder {
        var soundPlays = 0
        var clearedDrafts: [String] = []
    }

    private func makeModel(
        _ recorder: Recorder,
        filters: ChatViewerPolicy.Filters = ChatViewerPolicy.Filters(),
        soundEnabled: Bool = true
    ) -> ChatTranscriptModel {
        ChatTranscriptModel(dependencies: ChatTranscriptDependencies(
            chatFilters: { filters },
            clearDraft: { recorder.clearedDrafts.append($0) },
            isHighlightSoundEnabled: { soundEnabled },
            playHighlightSound: { recorder.soundPlays += 1 }
        ))
    }

    private func makeSession(channelId: String = "chan-1", accountUserId: String = "me-1") -> ChannelSession {
        ChannelSession(
            client: TwitchClient(clientId: "test-client", tokenStore: NullTokenStore()),
            channelId: channelId,
            channelLoginName: "somechannel",
            accountUserId: accountUserId
        )
    }

    /// Mirrors TwitchKit's wire decoding for `ChatMessage` (no memberwise init).
    private func chatMessage(
        id: String,
        userId: String = "u-1",
        login: String = "chatter",
        text: String = "hello",
        badgeSetIds: [String] = []
    ) -> ChatMessage {
        let badges = badgeSetIds
            .map { "{ \"set_id\": \"\($0)\", \"id\": \"1\", \"info\": \"\" }" }
            .joined(separator: ", ")
        let json = """
        {
            "message_id": "\(id)",
            "broadcaster_user_id": "chan-1",
            "broadcaster_user_login": "somechannel",
            "broadcaster_user_name": "SomeChannel",
            "chatter_user_id": "\(userId)",
            "chatter_user_login": "\(login)",
            "chatter_user_name": "Chatter",
            "message": {
                "text": "\(text)",
                "fragments": [{ "type": "text", "text": "\(text)" }]
            },
            "color": "",
            "badges": [\(badges)],
            "message_type": "text"
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try! decoder.decode(ChatMessage.self, from: Data(json.utf8))
    }

    private func message(_ message: ChatMessage) -> ChannelUpdate {
        .normalizedMessage(message, timestamp: Date(timeIntervalSince1970: 0))
    }

    /// A row the session flagged as a self-mention (highlighted).
    private func highlighted(_ id: String, from userId: String = "u-1", isHistorical: Bool = false) -> ChannelUpdate {
        var line = ChatLine(
            id: id,
            authorUserId: userId,
            authorDisplayName: "Chatter",
            runs: [.mention(login: "me", isMe: true)],
            isHistorical: isHistorical
        )
        line.isHighlighted = true
        return .message(NormalizedMessage(message: chatMessage(id: id, userId: userId), line: line))
    }

    // MARK: - Chat filters

    @Test("Filter toggles come from the injected settings at attach; own messages are exempt")
    func filtersFromDependencies() async {
        let recorder = Recorder()
        let model = makeModel(recorder, filters: ChatViewerPolicy.Filters(hideCommands: true, hideBots: true))
        await model.attach(sessions: [makeSession()], currentUserId: "me-1")

        model.apply([
            message(chatMessage(id: "cmd", text: "!drops")),
            message(chatMessage(id: "bot", login: "nightbot", text: "hi")),
            message(chatMessage(id: "own-cmd", userId: "me-1", text: "!drops")),
            message(chatMessage(id: "plain", text: "hello")),
        ])

        #expect(model.lines.map(\.id) == ["own-cmd", "plain"])
        await model.detach()
    }

    @Test("With the toggles off, commands and bots show")
    func filtersOff() async {
        let model = makeModel(Recorder())
        await model.attach(sessions: [makeSession()], currentUserId: "me-1")

        model.apply([
            message(chatMessage(id: "cmd", text: "!drops")),
            message(chatMessage(id: "bot", login: "nightbot", text: "hi")),
        ])

        #expect(model.lines.map(\.id) == ["cmd", "bot"])
        await model.detach()
    }

    // MARK: - Highlight sound

    @Test("A live highlighted message from someone else plays the sound")
    func liveHighlightPlays() {
        let recorder = Recorder()
        let model = makeModel(recorder)
        model.apply(highlighted("m1"))
        #expect(recorder.soundPlays == 1)
    }

    @Test("History, a disabled setting, and blocked users stay silent")
    func silentCases() {
        let historical = Recorder()
        makeModel(historical).apply(highlighted("m1", isHistorical: true))
        #expect(historical.soundPlays == 0)

        let disabled = Recorder()
        makeModel(disabled, soundEnabled: false).apply(highlighted("m1"))
        #expect(disabled.soundPlays == 0)

        let blocked = Recorder()
        let model = makeModel(blocked)
        model.blockedIds = ["u-1"]
        model.apply(highlighted("m1"))
        #expect(blocked.soundPlays == 0)
    }

    @Test("An unhighlighted message never plays")
    func plainMessageSilent() {
        let recorder = Recorder()
        makeModel(recorder).apply(message(chatMessage(id: "m1")))
        #expect(recorder.soundPlays == 0)
    }

    // MARK: - Drafts

    @Test("Starting a send clears the channel's persisted draft")
    func sendClearsDraft() async {
        let recorder = Recorder()
        let model = makeModel(recorder)
        await model.attach(sessions: [makeSession()], currentUserId: "me-1", draftKey: "twitch/chan-1")

        // Offline: the send fails at once, after the draft was cleared.
        await model.send(text: "hi")

        #expect(recorder.clearedDrafts == ["twitch/chan-1"])
        await model.detach()
    }

    @Test("Thread-sheet sends and retries leave the main composer's draft alone")
    func nonComposerSendsKeepDraft() async throws {
        let recorder = Recorder()
        let model = makeModel(recorder)
        await model.attach(sessions: [makeSession()], currentUserId: "me-1", draftKey: "twitch/chan-1")

        // Offline: each send fails at once and leaves a retryable row.
        await model.send(text: "in thread", repinsTranscript: false, fromMainComposer: false)
        #expect(recorder.clearedDrafts.isEmpty)

        let failed = try #require(model.lines.last)
        await model.retry(failedLineId: failed.id)
        #expect(recorder.clearedDrafts.isEmpty)
        await model.detach()
    }

    @Test("Retrying a non-reply ignores (and keeps) the main composer's reply chip")
    func retryDoesNotTakeComposerReply() async throws {
        let model = makeModel(Recorder())
        await model.attach(sessions: [makeSession()], currentUserId: "me-1")

        // Offline: the plain send fails at once and leaves a retryable row.
        await model.send(text: "plain")
        let failed = try #require(model.lines.last)
        #expect(failed.replyParent == nil)

        // The user then picks Reply on another message in the main bar.
        model.apply(message(chatMessage(id: "m1")))
        let target = try #require(model.lines.first { $0.id == "m1" })
        model.beginReply(to: target)
        #expect(model.replyContext != nil)

        await model.retry(failedLineId: failed.id)

        let retried = try #require(model.lines.last)
        #expect(retried.replyParent == nil, "the retry must stay a non-reply")
        #expect(model.replyContext != nil, "the chip belongs to the main bar's next send")
        await model.detach()
    }

    @Test("No draft key (tests, previews) clears nothing")
    func sendWithoutDraftKey() async {
        let recorder = Recorder()
        let model = makeModel(recorder)
        await model.attach(sessions: [makeSession()], currentUserId: "me-1")

        await model.send(text: "hi")

        #expect(recorder.clearedDrafts.isEmpty)
        await model.detach()
    }

    // MARK: - Re-pin on send

    @Test("Each send that shows a row bumps outgoingSendCount; one that can't start doesn't")
    func sendBumpsOutgoingCount() async {
        let detached = makeModel(Recorder())
        await detached.send(text: "hi")             // no session → error, no row
        #expect(detached.outgoingSendCount == 0)
        #expect(detached.sendError != nil)

        let model = makeModel(Recorder())
        await model.attach(sessions: [makeSession()], currentUserId: "me-1")
        await model.send(text: "   ")               // blank → nothing to send
        #expect(model.outgoingSendCount == 0)
        await model.send(text: "hi")
        await model.send(text: "again")
        #expect(model.outgoingSendCount == 2)
        await model.detach()
    }

    @Test("Thread-sheet sends leave the main transcript alone; retries re-pin it")
    func repinOnlyForMainTranscriptSends() async throws {
        let model = makeModel(Recorder())
        await model.attach(sessions: [makeSession()], currentUserId: "me-1")

        // Offline, so every send fails at once and leaves a retryable row.
        await model.send(text: "in thread", repinsTranscript: false)
        #expect(model.outgoingSendCount == 0)
        #expect(model.lines.count == 1)

        let failed = try #require(model.lines.last)
        await model.retry(failedLineId: failed.id)
        #expect(model.outgoingSendCount == 1)
        #expect(model.lines.count == 1, "the retry replaces the failed row")
        await model.detach()
    }

    @Test("Retry with no session keeps the failed row instead of losing the message")
    func retryWhileDetachedKeepsRow() async throws {
        let model = makeModel(Recorder())
        await model.attach(sessions: [makeSession()], currentUserId: "me-1")
        await model.send(text: "hi")
        let failed = try #require(model.lines.last)
        await model.detach()

        await model.retry(failedLineId: failed.id)

        #expect(model.lines.map(\.id) == [failed.id])
        #expect(model.sendError == "Not connected to chat.")
    }

    // MARK: - Badge observation

    @Test("A moderator badge on our own echo grants mod status; someone else's doesn't")
    func ownModBadgePromotes() async {
        let model = makeModel(Recorder())
        await model.attach(
            sessions: [makeSession(channelId: "chan-9", accountUserId: "user-1")],
            currentUserId: "user-1"
        )
        #expect(!model.currentUserCanModerate)

        model.apply(message(chatMessage(id: "m1", userId: "u-2", badgeSetIds: ["moderator"])))
        #expect(!model.currentUserCanModerate)

        model.apply(message(chatMessage(id: "m2", userId: "user-1", badgeSetIds: ["moderator"])))
        #expect(model.currentUserCanModerate)
        await model.detach()
    }
}
