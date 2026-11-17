import Testing
import Foundation
import TwitchKit
import ChatModel
import Channels
@testable import Features

/// The transcript's side of "you're timed out / banned here". The session's
/// ledger is the authority: the page syncs from it on our own clear / echo
/// and on reprime, and reports send rejections and dismissals to it.
/// Sessions are real but never started, as in
/// `ChatTranscriptModelModerationTests`, so `recordOwnChatRestriction`
/// stands in for what `handle(event:)` records before fanning an update out.
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

    // MARK: - Attached: the session's ledger is the authority

    @Test("Our messages cleared by a mod → removedByModerator, synced from the session")
    func ownClearRaisesRestriction() async {
        let session = makeSession()
        let model = makeModel()
        await model.attach(sessions: [session], currentUserId: "me-1")

        await session.recordOwnChatRestriction(.ownMessagesCleared)
        model.apply(.messagesClearedFromUser(targetUserId: "me-1"))
        await model.ownRestriction.pendingSync?.value

        #expect(model.ownRestriction.current == .removedByModerator)
        await model.detach()
    }

    @Test("Someone else's timeout leaves us unrestricted")
    func otherClearIgnored() async {
        let model = makeModel()
        await model.attach(sessions: [makeSession()], currentUserId: "me-1")

        model.apply(.messagesClearedFromUser(targetUserId: "someone-else"))
        await model.ownRestriction.pendingSync?.value

        #expect(model.ownRestriction.current == nil)
        await model.detach()
    }

    @Test("Our own delivered echo clears the restriction")
    func ownEchoClears() async {
        let session = makeSession()
        let model = makeModel()
        await model.attach(sessions: [session], currentUserId: "me-1")
        await session.recordOwnChatRestriction(.ownMessagesCleared)
        model.apply(.messagesClearedFromUser(targetUserId: "me-1"))
        await model.ownRestriction.pendingSync?.value
        #expect(model.ownRestriction.current == .removedByModerator)

        await session.recordOwnChatRestriction(.ownMessageDelivered)
        model.apply(ownMessage(id: "m-1"))
        await model.ownRestriction.pendingSync?.value

        #expect(model.ownRestriction.current == nil)
        await model.detach()
    }

    @Test("A remounted page restores the restriction kept on the session")
    func restoresFromSessionOnAttach() async {
        let session = makeSession()
        let until = Date.now.addingTimeInterval(600)
        await session.recordOwnChatRestriction(.rejected(.timedOut(until: until)))

        let model = makeModel()
        await model.attach(sessions: [session], currentUserId: "me-1")

        #expect(model.ownRestriction.current == .timedOut(until: until))
        await model.detach()
    }

    @Test("Page-only signals are recorded on the session, in order")
    func reportsToSession() async {
        let session = makeSession()
        let model = makeModel()
        await model.attach(sessions: [session], currentUserId: "me-1")

        model.ownRestriction.apply(.timedOut(until: nil))
        model.ownRestriction.apply(.banned)
        await model.ownRestriction.pendingSync?.value

        #expect(await session.ownChatRestriction().current() == .banned)
        #expect(model.ownRestriction.current == .banned)

        // A new page for the same session sees it.
        await model.detach()
        let remounted = makeModel()
        await remounted.attach(sessions: [session], currentUserId: "me-1")
        #expect(remounted.ownRestriction.current == .banned)
        await remounted.detach()
    }

    @Test("A send rejection started before a newer self-clear can't restore its stale deadline")
    func staleRejectionLosesToNewerClear() async {
        let session = makeSession()
        let model = makeModel()
        await model.attach(sessions: [session], currentUserId: "me-1")

        // The send starts while unrestricted…
        let basis = model.ownRestriction.sendBasis(for: session)
        // …a mod times us out meanwhile…
        await session.recordOwnChatRestriction(.ownMessagesCleared)
        model.apply(.messagesClearedFromUser(targetUserId: "me-1"))
        // …and only then does the older rejection come back.
        model.ownRestriction.reportSendRejection(
            .timedOut(until: Date.now.addingTimeInterval(30)), on: session, basis: basis
        )
        await model.ownRestriction.pendingSync?.value

        #expect(await session.ownChatRestriction().current() == .removedByModerator)
        #expect(model.ownRestriction.current == .removedByModerator)

        // A remount restores the clear, not the stale deadline.
        await model.detach()
        let remounted = makeModel()
        await remounted.attach(sessions: [session], currentUserId: "me-1")
        #expect(remounted.ownRestriction.current == .removedByModerator)
        await remounted.detach()
    }

    @Test("A send rejection arriving after detach still lands on the session")
    func rejectionAfterDetachIsKept() async {
        let session = makeSession()
        let model = makeModel()
        await model.attach(sessions: [session], currentUserId: "me-1")
        let basis = model.ownRestriction.sendBasis(for: session)

        await model.detach()
        model.ownRestriction.reportSendRejection(.banned, on: session, basis: basis)
        await model.ownRestriction.pendingSync?.value

        #expect(await session.ownChatRestriction().current() == .banned)
        let remounted = makeModel()
        await remounted.attach(sessions: [session], currentUserId: "me-1")
        #expect(remounted.ownRestriction.current == .banned)
        await remounted.detach()
    }

    @Test("A reprime resyncs a self-clear the overflowed mailbox dropped")
    func reprimeResyncsClear() async {
        let session = makeSession()
        let model = makeModel()
        await model.attach(sessions: [session], currentUserId: "me-1")

        // The clear reached the session, but its update was lost in an
        // overflow; this subscriber only gets the reprime.
        await session.recordOwnChatRestriction(.ownMessagesCleared)
        model.apply(.reprime([]))
        await model.ownRestriction.pendingSync?.value

        #expect(model.ownRestriction.current == .removedByModerator)
        await model.detach()
    }

    @Test("A reprime drops a restriction an overflowed echo lifted")
    func reprimeResyncsLift() async {
        let session = makeSession()
        let until = Date.now.addingTimeInterval(600)
        await session.recordOwnChatRestriction(.rejected(.timedOut(until: until)))
        let model = makeModel()
        await model.attach(sessions: [session], currentUserId: "me-1")
        #expect(model.ownRestriction.current == .timedOut(until: until))

        await session.recordOwnChatRestriction(.ownMessageDelivered)
        model.apply(.reprime([]))
        await model.ownRestriction.pendingSync?.value

        #expect(model.ownRestriction.current == nil)
        await model.detach()
    }

    @Test("Dismiss hides the banner at once and clears the session's copy")
    func dismissReachesSession() async {
        let session = makeSession()
        await session.recordOwnChatRestriction(.ownMessagesCleared)
        let model = makeModel()
        await model.attach(sessions: [session], currentUserId: "me-1")
        #expect(model.ownRestriction.current == .removedByModerator)

        model.ownRestriction.dismiss()
        #expect(model.ownRestriction.current == nil)
        await model.ownRestriction.pendingSync?.value

        #expect(await session.ownChatRestriction().current() == nil)
        #expect(model.ownRestriction.current == nil)
        await model.detach()
    }

    // MARK: - Detached: the same reducer, locally

    @Test("A known timeout isn't downgraded by a vague send rejection")
    func preciseStateWins() {
        let state = OwnChatRestrictionState()
        let until = Date.now.addingTimeInterval(600)
        state.apply(.timedOut(until: until))

        state.apply(.timedOut(until: nil))

        #expect(state.current == .timedOut(until: until))
        state.dismiss()
        #expect(state.current == nil)
    }

    @Test("A fresh self-clear during a known timeout drops the old deadline")
    func freshClearOverridesKnownTimeout() {
        let state = OwnChatRestrictionState()
        state.apply(.timedOut(until: Date.now.addingTimeInterval(600)))

        // Extended, or turned into a ban — the clear doesn't say which.
        state.noteOwnMessagesCleared()

        #expect(state.current == .removedByModerator)
        #expect(state.current?.blocksSending() == false)
        // Refined by the next send rejection.
        state.apply(.banned)
        #expect(state.current == .banned)
    }
}
