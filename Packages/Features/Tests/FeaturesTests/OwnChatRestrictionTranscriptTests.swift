import Testing
import Foundation
import TwitchKit
import ChatModel
import Channels
@testable import Features

/// The transcript's side of "you're timed out / banned here": a
/// `messagesClearedFromUser` targeting OUR account raises the restriction,
/// anyone else's doesn't, and our own delivered echo clears it. Sessions are
/// real but never started, as in `ChatTranscriptModelModerationTests`.
@Suite("ChatTranscriptModel own chat restriction")
@MainActor
struct OwnChatRestrictionTranscriptTests {

    private struct NullTokenStore: TwitchTokenStore {
        func loadToken() async throws -> OAuthToken? { nil }
        func saveToken(_ token: OAuthToken) async throws {}
        func deleteToken() async throws {}
    }

    private func makeModel() -> ChatTranscriptModel {
        ChatTranscriptModel(dependencies: ChatTranscriptDependencies(
            chatFilters: { ChatViewerPolicy.Filters() },
            clearDraft: { _ in },
            isHighlightSoundEnabled: { false },
            playHighlightSound: {}
        ))
    }

    private func makeSession() -> ChannelSession {
        ChannelSession(
            client: TwitchClient(clientId: "test-client", tokenStore: NullTokenStore()),
            channelId: "chan-1",
            channelLoginName: "somechannel",
            accountUserId: "me-1"
        )
    }

    private func ownMessage(id: String) -> ChannelUpdate {
        let json = """
        {
            "message_id": "\(id)",
            "broadcaster_user_id": "chan-1",
            "broadcaster_user_login": "somechannel",
            "broadcaster_user_name": "SomeChannel",
            "chatter_user_id": "me-1",
            "chatter_user_login": "me",
            "chatter_user_name": "Me",
            "message": { "text": "hi", "fragments": [{ "type": "text", "text": "hi" }] },
            "color": "",
            "badges": [],
            "message_type": "text"
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let message = try! decoder.decode(ChatMessage.self, from: Data(json.utf8))
        return .normalizedMessage(message, timestamp: Date(timeIntervalSince1970: 0))
    }

    @Test("Our messages cleared by a mod → removedByModerator")
    func ownClearRaisesRestriction() async {
        let model = makeModel()
        await model.attach(sessions: [makeSession()], currentUserId: "me-1")

        model.apply(.messagesClearedFromUser(targetUserId: "me-1"))

        #expect(model.ownRestriction.current == .removedByModerator)
        await model.detach()
    }

    @Test("Someone else's timeout leaves us unrestricted")
    func otherClearIgnored() async {
        let model = makeModel()
        await model.attach(sessions: [makeSession()], currentUserId: "me-1")

        model.apply(.messagesClearedFromUser(targetUserId: "someone-else"))

        #expect(model.ownRestriction.current == nil)
        await model.detach()
    }

    @Test("Our own delivered echo clears the restriction")
    func ownEchoClears() async {
        let model = makeModel()
        await model.attach(sessions: [makeSession()], currentUserId: "me-1")
        model.apply(.messagesClearedFromUser(targetUserId: "me-1"))

        model.apply(ownMessage(id: "m-1"))

        #expect(model.ownRestriction.current == nil)
        await model.detach()
    }

    @Test("A known timeout isn't downgraded by a later vague signal")
    func preciseStateWins() {
        let state = OwnChatRestrictionState()
        let until = Date.now.addingTimeInterval(600)
        state.apply(.timedOut(until: until))

        state.noteOwnMessagesCleared()
        state.apply(.timedOut(until: nil))

        #expect(state.current == .timedOut(until: until))
        state.dismiss()
        #expect(state.current == nil)
    }
}
