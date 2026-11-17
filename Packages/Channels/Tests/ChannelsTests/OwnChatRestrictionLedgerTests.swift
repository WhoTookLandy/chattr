import Testing
import Foundation
import TwitchKit
@testable import Channels

/// The reducer the session and the chat page both run for "you're timed
/// out / banned here": absolute deadlines, and a fresh self-clear that
/// always invalidates whatever deadline came before.
@Suite("OwnChatRestrictionLedger")
struct OwnChatRestrictionLedgerTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("A known timeout reads as nothing once its deadline passes")
    func deadlineBased() {
        var ledger = OwnChatRestrictionLedger()
        let until = now.addingTimeInterval(60)
        ledger.apply(.rejected(.timedOut(until: until)), now: now)

        #expect(ledger.current(at: now) == .timedOut(until: until))
        #expect(ledger.current(at: until) == nil)
        #expect(ledger.current(at: until.addingTimeInterval(1)) == nil)
    }

    @Test("A vague timeout keeps the running deadline")
    func vagueKeepsDeadline() {
        var ledger = OwnChatRestrictionLedger()
        let until = now.addingTimeInterval(600)
        ledger.apply(.rejected(.timedOut(until: until)), now: now)
        let generation = ledger.generation

        #expect(ledger.apply(.rejected(.timedOut(until: nil)), now: now) == false)
        #expect(ledger.current(at: now) == .timedOut(until: until))
        #expect(ledger.generation == generation)
    }

    @Test("A fresh self-clear replaces a running timeout with an unknown-length one")
    func freshClearWins() {
        var ledger = OwnChatRestrictionLedger()
        ledger.apply(.rejected(.timedOut(until: now.addingTimeInterval(600))), now: now)
        let generation = ledger.generation

        ledger.apply(.ownMessagesCleared, now: now)

        #expect(ledger.current(at: now) == .removedByModerator)
        #expect(ledger.generation != generation)
        // The old deadline no longer lifts anything.
        #expect(ledger.current(at: now.addingTimeInterval(601)) == .removedByModerator)
    }

    @Test("Every self-clear bumps the generation, even a repeated one")
    func repeatedClearBumps() {
        var ledger = OwnChatRestrictionLedger()
        ledger.apply(.ownMessagesCleared, now: now)
        let generation = ledger.generation
        ledger.apply(.ownMessagesCleared, now: now)
        #expect(ledger.generation != generation)
    }

    @Test("Our delivered echo and a dismiss clear it")
    func deliveredAndDismiss() {
        var ledger = OwnChatRestrictionLedger()
        #expect(ledger.apply(.ownMessageDelivered, now: now) == false)

        ledger.apply(.rejected(.banned), now: now)
        ledger.apply(.ownMessageDelivered, now: now)
        #expect(ledger.current(at: now) == nil)

        ledger.apply(.rejected(.warned(reason: nil)), now: now)
        ledger.apply(.dismissed, now: now)
        #expect(ledger.current(at: now) == nil)
    }

    @Test("A send rejection based before the latest self-clear is dropped")
    func staleRejectionDropped() {
        var ledger = OwnChatRestrictionLedger()
        let basis = ledger.generation          // the send starts here
        ledger.apply(.ownMessagesCleared, now: now)
        let generation = ledger.generation

        // "Timed out for 30 more seconds" — about the timeout before the clear.
        #expect(ledger.apply(.rejected(.timedOut(until: now.addingTimeInterval(30))), basis: basis, now: now) == false)
        #expect(ledger.current(at: now) == .removedByModerator)
        #expect(ledger.generation == generation)
    }

    @Test("A send rejection based on or after the latest self-clear refines it")
    func freshRejectionRefines() {
        var ledger = OwnChatRestrictionLedger()
        ledger.apply(.ownMessagesCleared, now: now)
        let basis = ledger.generation          // the send starts after the clear
        // Non-clear transitions since the basis don't make it stale.
        ledger.apply(.rejected(.warned(reason: nil)), now: now)

        let until = now.addingTimeInterval(600)
        #expect(ledger.apply(.rejected(.timedOut(until: until)), basis: basis, now: now))
        #expect(ledger.current(at: now) == .timedOut(until: until))
        #expect(ledger.lastClearGeneration == basis)
    }

    // MARK: - On the session

    private struct NullTokenStore: TwitchTokenStore {
        func loadToken() async throws -> OAuthToken? { nil }
        func saveToken(_ token: OAuthToken) async throws {}
        func deleteToken() async throws {}
    }

    private func makeSession() -> ChannelSession {
        ChannelSession(
            client: TwitchClient(clientId: "test-client", tokenStore: NullTokenStore()),
            channelId: "chan-1",
            channelLoginName: "somechannel",
            accountUserId: "me-1"
        )
    }

    private func clearEvent(target: String) throws -> EventSubEvent {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let json = """
        {
            "broadcaster_user_id": "chan-1",
            "broadcaster_user_login": "somechannel",
            "broadcaster_user_name": "SomeChannel",
            "target_user_id": "\(target)",
            "target_user_login": "t",
            "target_user_name": "T"
        }
        """
        return .chatClearUserMessages(try decoder.decode(EventSubChatClearUserMessages.self, from: Data(json.utf8)))
    }

    @Test("The session keeps page signals for a page that attaches later")
    func sessionKeepsLedger() async {
        let session = makeSession()
        await session.recordOwnChatRestriction(.rejected(.banned))
        #expect(await session.ownChatRestriction().current() == .banned)
    }

    @Test("The session records a clear of OUR messages itself, with no page attached")
    func sessionRecordsOwnClear() async throws {
        let session = makeSession()
        await session.recordOwnChatRestriction(.rejected(.timedOut(until: Date.now.addingTimeInterval(600))))

        await session.handle(event: try clearEvent(target: "someone-else"))
        #expect(await session.ownChatRestriction().current() != .removedByModerator)

        await session.handle(event: try clearEvent(target: "me-1"))
        #expect(await session.ownChatRestriction().current() == .removedByModerator)
    }

    private func chatMessage(id: String, from userId: String) -> ChatMessage {
        let line = "@id=\(id);room-id=chan-1;user-id=\(userId) :u!u@u.tmi.twitch.tv PRIVMSG #somechannel :hi"
        return IRCMessageParser.parse(line, channelLogin: "somechannel")!
    }

    @Test("The session lifts our restriction on our own broadcast message, in stream order")
    func sessionRecordsOwnEcho() async throws {
        let session = makeSession()
        await session.handle(event: try clearEvent(target: "me-1"))

        await session.handle(event: .chatMessage(chatMessage(id: "a", from: "someone-else")))
        #expect(await session.ownChatRestriction().current() == .removedByModerator)

        await session.handle(event: .chatMessage(chatMessage(id: "b", from: "me-1")))
        #expect(await session.ownChatRestriction().current() == nil)

        // An echo BEFORE a later clear can't undo that clear.
        await session.handle(event: try clearEvent(target: "me-1"))
        #expect(await session.ownChatRestriction().current() == .removedByModerator)
    }

    @Test("Recording a page signal returns the ledger the page adopts")
    func recordReturnsLedger() async {
        let session = makeSession()
        let before = await session.ownChatRestriction().generation
        let after = await session.recordOwnChatRestriction(.rejected(.banned), basis: before)
        #expect(after.current() == .banned)
        #expect(after.generation > before)
    }
}
