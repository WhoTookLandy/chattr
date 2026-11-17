import Testing
import Foundation
import os
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

    // MARK: - Send outcomes vs the sequence

    @Test("Rejection after a clear: a send started before the clear can't restore its stale deadline")
    func rejectionAfterClearDropped() {
        var ledger = OwnChatRestrictionLedger()
        let basis = ledger.beginSend()          // the send starts here
        ledger.apply(.ownMessagesCleared, now: now)
        let generation = ledger.generation

        // "Timed out for 30 more seconds" — about the timeout before the clear.
        #expect(ledger.finishSend(basis: basis, rejection: .timedOut(until: now.addingTimeInterval(30)), now: now) == false)
        #expect(ledger.current(at: now) == .removedByModerator)
        #expect(ledger.generation == generation)
        #expect(ledger.sendsInFlight == 0)
    }

    @Test("Rejection after an echo: a send started before our echo can't reinstate a lifted ban")
    func rejectionAfterEchoDropped() {
        var ledger = OwnChatRestrictionLedger()
        ledger.apply(.rejected(.banned), now: now)
        let basis = ledger.beginSend()
        // We were unbanned; a later message of ours went through.
        ledger.apply(.ownMessageDelivered, now: now)
        #expect(ledger.current(at: now) == nil)

        #expect(ledger.finishSend(basis: basis, rejection: .banned, now: now) == false)
        #expect(ledger.current(at: now) == nil)
    }

    @Test("Rejection after an echo while unrestricted: the in-flight send makes the echo count")
    func rejectionAfterUnrestrictedEchoDropped() {
        var ledger = OwnChatRestrictionLedger()
        #expect(ledger.observesOwnEchoes == false)
        let basis = ledger.beginSend()
        #expect(ledger.observesOwnEchoes)
        ledger.apply(.ownMessageDelivered, now: now)

        #expect(ledger.finishSend(basis: basis, rejection: .timedOut(until: now.addingTimeInterval(30)), now: now) == false)
        #expect(ledger.current(at: now) == nil)
        #expect(ledger.observesOwnEchoes == false)
    }

    @Test("A send rejection with no clear or echo since it started is applied")
    func freshRejectionRefines() {
        var ledger = OwnChatRestrictionLedger()
        ledger.apply(.ownMessagesCleared, now: now)
        let basis = ledger.beginSend()          // the send starts after the clear
        // Other transitions (dismiss, another rejection) don't make it stale.
        ledger.apply(.dismissed, now: now)

        let until = now.addingTimeInterval(600)
        let applied = ledger.finishSend(basis: basis, rejection: .timedOut(until: until), now: now)
        #expect(applied)
        #expect(ledger.current(at: now) == .timedOut(until: until))
    }

    @Test("A finished send with no rejection only balances the in-flight count")
    func acceptedSendBalances() {
        var ledger = OwnChatRestrictionLedger()
        let basis = ledger.beginSend()
        #expect(ledger.finishSend(basis: basis, rejection: nil, now: now) == false)
        #expect(ledger.sendsInFlight == 0)
        #expect(ledger.current(at: now) == nil)
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
        let after = await session.recordOwnChatRestriction(.rejected(.banned))
        #expect(after.current() == .banned)
        #expect(after.generation > before)
    }

    // MARK: - Send outcomes, recorded by the session

    private struct FixedTokenStore: TwitchTokenStore {
        func loadToken() async throws -> OAuthToken? { OAuthToken(accessToken: "test-token") }
        func saveToken(_ token: OAuthToken) async throws {}
        func deleteToken() async throws {}
    }

    /// Answers POST /chat/messages with a canned 200 body, but only once
    /// `open()` is called — so a test can land a clear / echo while the
    /// send is in flight.
    private final class GatedHTTPClient: HTTPClient, Sendable {
        private struct State {
            var requests = 0
            var isOpen = false
            var waiting: CheckedContinuation<Void, Never>?
        }
        private let state = OSAllocatedUnfairLock(initialState: State())
        private let body: Data

        init(json: String, open: Bool = false) {
            body = Data(json.utf8)
            if open { self.open() }
        }

        var requests: Int { state.withLock { $0.requests } }

        func open() {
            let waiting = state.withLock { state -> CheckedContinuation<Void, Never>? in
                state.isOpen = true
                defer { state.waiting = nil }
                return state.waiting
            }
            waiting?.resume()
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let proceed = state.withLock { state -> Bool in
                    state.requests += 1
                    if state.isOpen { return true }
                    state.waiting = continuation
                    return false
                }
                if proceed { continuation.resume() }
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (body, response)
        }
    }

    private func dropped(code: String, message: String) -> String {
        #"{"data":[{"message_id":"","is_sent":false,"drop_reason":{"code":"\#(code)","message":"\#(message)"}}]}"#
    }

    private func makeSendingSession(_ http: GatedHTTPClient) -> ChannelSession {
        ChannelSession(
            client: TwitchClient(clientId: "test-client", tokenStore: FixedTokenStore(), httpClient: http),
            channelId: "chan-1",
            channelLoginName: "somechannel",
            accountUserId: "me-1"
        )
    }

    /// Starts a send and returns once its request is on the wire (so the
    /// session has already captured its sequence).
    private func startSend(on session: ChannelSession, http: GatedHTTPClient) async -> Task<SendChatMessageResponse, any Error> {
        let task = Task { try await session.send("hi") }
        while http.requests == 0 { await Task.yield() }
        return task
    }

    @Test("A send's rejection is recorded by the session itself")
    func sendRecordsRejection() async throws {
        let http = GatedHTTPClient(json: dropped(code: "msg_timedout", message: "You are timed out for 30 more seconds."), open: true)
        let session = makeSendingSession(http)

        _ = try await session.send("hi")

        let ledger = await session.ownChatRestriction()
        guard case .timedOut(let until?)? = ledger.current() else {
            Issue.record("Expected a known timeout, got \(String(describing: ledger.current()))")
            return
        }
        #expect(until > Date.now)
        #expect(ledger.sendsInFlight == 0)
    }

    @Test("Rejection after clear: a self-clear landing mid-send wins over the older rejection")
    func sendRejectionAfterClear() async throws {
        let http = GatedHTTPClient(json: dropped(code: "msg_timedout", message: "You are timed out for 30 more seconds."))
        let session = makeSendingSession(http)

        let send = await startSend(on: session, http: http)
        await session.handle(event: try clearEvent(target: "me-1"))
        http.open()
        _ = try await send.value

        #expect(await session.ownChatRestriction().current() == .removedByModerator)
    }

    @Test("Rejection after echo: our own message broadcast mid-send wins over the older rejection")
    func sendRejectionAfterEcho() async throws {
        let http = GatedHTTPClient(json: dropped(code: "msg_banned", message: "You are permanently banned from talking in somechannel."))
        let session = makeSendingSession(http)

        let send = await startSend(on: session, http: http)
        // Unrestricted, but a send is in flight: the echo still counts.
        await session.handle(event: .chatMessage(chatMessage(id: "b", from: "me-1")))
        http.open()
        _ = try await send.value

        let ledger = await session.ownChatRestriction()
        #expect(ledger.current() == nil)
        #expect(ledger.sendsInFlight == 0)
    }
}
