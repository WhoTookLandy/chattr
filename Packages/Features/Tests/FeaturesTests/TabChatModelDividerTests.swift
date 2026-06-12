import Testing
import Foundation
import TwitchKit
import ChatModel
import Channels
@testable import Features

/// Tests for the "New" messages divider as it flows through `TabChatModel`:
/// the `.newMessagesDivider` ChannelEvent must become a divider `ChatLine`
/// with the ring-minted id, survive a chat-clear un-struck, and replay with
/// stable identity when a tab re-primes.
///
/// Sessions here are real but never `start()`ed — same offline pattern as
/// `TabChatModelModerationTests`. Events are driven through the internal
/// `apply(_:)`, the same entry point the live subscriber callback uses.
@Suite("TabChatModel new-messages divider")
@MainActor
struct TabChatModelDividerTests {

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

    private func makeAttachedModel() async -> TabChatModel {
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
        let model = TabChatModel()
        await model.attach(sessions: [session], currentUserId: "me-1")
        return model
    }

    @Test("Divider event becomes a divider line with the ring-minted id")
    func dividerEventBecomesLine() async {
        let model = await makeAttachedModel()
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)

        model.apply(.message(chatMessage(id: "m1")))
        model.apply(.newMessagesDivider(id: "div-1", timestamp: stamp))

        #expect(model.lines.map(\.id) == ["m1", "div-1"])
        let divider = model.lines.last
        #expect(divider?.kind == .newMessagesDivider)
        #expect(divider?.timestamp == stamp)
        #expect(divider?.runs.isEmpty == true)
        await model.detach()
    }

    @Test("Chat-clear strikes messages but leaves the divider intact")
    func chatClearPreservesDivider() async {
        let model = await makeAttachedModel()

        model.apply(.message(chatMessage(id: "m1")))
        model.apply(.newMessagesDivider(id: "div-1", timestamp: .now))
        model.apply(.message(chatMessage(id: "m2")))
        model.apply(.chatCleared)

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

        model.apply(.message(chatMessage(id: "m1")))
        model.apply(.newMessagesDivider(id: "div-1", timestamp: .now))
        model.apply(.message(chatMessage(id: "m1")))   // duplicate — dropped
        model.apply(.message(chatMessage(id: "gap1"))) // genuinely missed

        #expect(model.lines.map(\.id) == ["m1", "div-1", "gap1"])
        await model.detach()
    }

    @Test("withDeletedPlaceholder is a no-op on divider lines")
    func deletedPlaceholderNoOpOnDivider() {
        let divider = ChatLine(
            id: "div-1",
            kind: .newMessagesDivider,
            authorDisplayName: "",
            runs: []
        )
        #expect(divider.withDeletedPlaceholder() == divider)
    }
}
