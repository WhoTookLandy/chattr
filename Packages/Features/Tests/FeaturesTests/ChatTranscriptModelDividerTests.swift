import Testing
import Foundation
import TwitchKit
import ChatModel
import Channels
@testable import Features

/// Tests for the "New" messages divider as it flows through `ChatTranscriptModel`:
/// the session builds the divider row (id + timestamp minted once, stored in
/// its ring); the model must append it as-is, keep it intact through a
/// chat-clear, and dedup gap-filled messages around it.
///
/// Sessions here are real but never `start()`ed — same offline pattern as
/// `ChatTranscriptModelModerationTests`. Updates are driven through the internal
/// `apply(_:)`, the same entry point the subscription consumer uses.
@Suite("ChatTranscriptModel new-messages divider")
@MainActor
struct ChatTranscriptModelDividerTests {

    /// Mirrors TwitchKit's wire decoding for `ChatMessage` — the only public
    /// construction path (no memberwise init), matching the EventSub
    /// `channel.chat.message` payload shape.
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

    private func message(_ id: String, isHistorical: Bool = false) -> ChannelUpdate {
        .normalizedMessage(chatMessage(id: id), isHistorical: isHistorical, timestamp: Date(timeIntervalSince1970: 0))
    }

    private func divider(_ id: String, timestamp: Date = Date(timeIntervalSince1970: 0)) -> ChannelUpdate {
        .row(ChatLine(id: id, kind: .newMessagesDivider, authorDisplayName: "", runs: [], timestamp: timestamp))
    }

    private func makeAttachedModel() async -> ChatTranscriptModel {
        struct NullTokenStore: TwitchTokenStore {
            func loadToken() async throws -> OAuthToken? { nil }
            func saveToken(_ token: OAuthToken) async throws {}
            func deleteToken() async throws {}
        }
        let client = TwitchClient(clientId: "test-client", tokenStore: NullTokenStore())
        let session = ChannelSession(
            client: client,
            channelId: "chan-1",
            channelLoginName: "somechannel",
            accountUserId: "me-1"
        )
        let model = ChatTranscriptModel()
        await model.attach(sessions: [session], currentUserId: "me-1")
        return model
    }

    @Test("A divider row is appended as-is, keeping its session-minted id and time")
    func dividerRowAppended() async {
        let model = await makeAttachedModel()
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)

        model.apply(message("m1"))
        model.apply(divider("div-1", timestamp: stamp))

        #expect(model.lines.map(\.id) == ["m1", "div-1"])
        let line = model.lines.last
        #expect(line?.kind == .newMessagesDivider)
        #expect(line?.timestamp == stamp)
        #expect(line?.runs.isEmpty == true)
        await model.detach()
    }

    @Test("Chat-clear strikes messages but leaves the divider intact")
    func chatClearPreservesDivider() async {
        let model = await makeAttachedModel()

        model.apply([message("m1"), divider("div-1"), message("m2"), .chatCleared])

        let kinds = model.lines.map(\.kind)
        #expect(kinds == [.deletedPlaceholder, .newMessagesDivider, .deletedPlaceholder])
        await model.detach()
    }

    @Test("Gap-filled messages after the divider dedup against existing rows")
    func gapFillDedupsAgainstBuffer() async {
        // The reconnect path can re-deliver a message the model already
        // holds (e.g. a self-send whose lost echo was synthesized locally).
        // Path 1 dedup-by-id must drop it rather than duplicate the row.
        let model = await makeAttachedModel()

        model.apply(message("m1"))
        model.apply([divider("div-1"), message("m1", isHistorical: true), message("gap1", isHistorical: true)])

        #expect(model.lines.map(\.id) == ["m1", "div-1", "gap1"])
        await model.detach()
    }

    @Test("Historical provenance stamped by the session reaches the line")
    func historicalFlagStampsLine() async {
        let model = await makeAttachedModel()

        model.apply(message("h1", isHistorical: true))
        model.apply(message("m1"))

        #expect(model.lines.first?.isHistorical == true)
        #expect(model.lines.last?.isHistorical == false)
        await model.detach()
    }

    @Test("markingDeleted is a no-op on divider lines")
    func deletedPlaceholderNoOpOnDivider() {
        let divider = ChatLine(
            id: "div-1",
            kind: .newMessagesDivider,
            authorDisplayName: "",
            runs: []
        )
        #expect(divider.markingDeleted() == divider)
    }
}
