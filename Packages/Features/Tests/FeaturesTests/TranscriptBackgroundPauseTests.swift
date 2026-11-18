import Testing
import Foundation
import TwitchKit
import ChatModel
@testable import Channels
@testable import Features

/// The transcript's background pause (`ChatTranscriptModel.setLiveUpdatesPaused`):
/// while paused nothing is drained from the session's mailbox, and resuming
/// applies the backlog in one turn — silently, and with the stuck-send
/// fallback held until the backlog (where the echo may be) has been read.
///
/// `@testable import Channels` reaches `ChannelSession.handle(event:)`, which
/// posts a live event to a real (never-started) session's subscribers.
///
/// The limit is a hang guard, and it counts time spent queued for the main
/// actor. The whole target runs in parallel on one simulator, and on CI that
/// wait has run to about 90 seconds before these tests get their turn.
@Suite("Transcript background pause", .timeLimit(.minutes(5)))
@MainActor
struct TranscriptBackgroundPauseTests {

    private struct NullTokenStore: TwitchTokenStore {
        func loadToken() async throws -> OAuthToken? { nil }
        func saveToken(_ token: OAuthToken) async throws {}
        func deleteToken() async throws {}
    }

    /// Counts highlight-sound plays in place of the speaker.
    private final class SoundCounter {
        var plays = 0
    }

    private func makeSession() -> ChannelSession {
        ChannelSession(
            client: TwitchClient(clientId: "test-client", tokenStore: NullTokenStore()),
            channelId: "chan-1",
            channelLoginName: "somechannel",
            accountUserId: "me-1",
            accountLogin: "me",
            fetchBackfill: { _, _ in [] }
        )
    }

    private func makeModel(_ counter: SoundCounter = SoundCounter()) -> ChatTranscriptModel {
        ChatTranscriptModel(dependencies: ChatTranscriptDependencies(
            chatFilters: { ChatViewerPolicy.Filters() },
            clearDraft: { _ in },
            isHighlightSoundEnabled: { true },
            playHighlightSound: { counter.plays += 1 }
        ))
    }

    private func chatMessage(id: String, text: String = "hello") -> ChatMessage {
        let json = """
        {
            "message_id": "\(id)",
            "broadcaster_user_id": "chan-1",
            "broadcaster_user_login": "somechannel",
            "broadcaster_user_name": "SomeChannel",
            "chatter_user_id": "u-1",
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

    /// Spin the main actor until the drain task has applied what the session
    /// posted (delivery is asynchronous by design).
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    @Test("Paused, live rows stay in the mailbox; resuming applies them in the same turn")
    func pauseParksAndResumeCatchesUp() async throws {
        let session = makeSession()
        let model = makeModel()
        await model.attach(sessions: [session], currentUserId: "me-1")
        await session.handle(event: .chatMessage(chatMessage(id: "before")))
        try await waitUntil { !model.lines.isEmpty }

        model.setLiveUpdatesPaused(true)
        await session.handle(event: .chatMessage(chatMessage(id: "during-1")))
        await session.handle(event: .chatMessage(chatMessage(id: "during-2")))
        try await Task.sleep(for: .milliseconds(40))
        #expect(model.lines.map(\.id) == ["before"])

        let versionBefore = model.changeVersion
        model.setLiveUpdatesPaused(false)
        // No waiting for the drain task: caught up, and published, already.
        #expect(model.lines.map(\.id) == ["before", "during-1", "during-2"])
        #expect(model.changeVersion == versionBefore + 1)

        // Draining is live again.
        await session.handle(event: .chatMessage(chatMessage(id: "after")))
        try await waitUntil { model.lines.count == 4 }
        #expect(model.lines.map(\.id) == ["before", "during-1", "during-2", "after"])
        await model.detach()
    }

    @Test("Pausing twice or resuming while not paused changes nothing")
    func pauseIsIdempotent() async throws {
        let session = makeSession()
        let model = makeModel()
        await model.attach(sessions: [session], currentUserId: "me-1")

        model.setLiveUpdatesPaused(false)
        model.setLiveUpdatesPaused(true)
        model.setLiveUpdatesPaused(true)
        await session.handle(event: .chatMessage(chatMessage(id: "m1")))
        try await Task.sleep(for: .milliseconds(40))
        #expect(model.lines.isEmpty)

        model.setLiveUpdatesPaused(false)
        model.setLiveUpdatesPaused(false)
        #expect(model.lines.map(\.id) == ["m1"])
        await model.detach()
    }

    @Test("The backlog applied on resume never pings; a live highlight afterwards does")
    func catchUpIsSilent() async throws {
        let counter = SoundCounter()
        let session = makeSession()
        let model = makeModel(counter)
        await model.attach(sessions: [session], currentUserId: "me-1", highlightKeywords: ["clip"])

        model.setLiveUpdatesPaused(true)
        await session.handle(event: .chatMessage(chatMessage(id: "m1", text: "nice clip")))
        model.setLiveUpdatesPaused(false)
        #expect(model.lines.map(\.isHighlighted) == [true])
        #expect(counter.plays == 0)

        await session.handle(event: .chatMessage(chatMessage(id: "m2", text: "another clip")))
        try await waitUntil { model.lines.count == 2 }
        #expect(counter.plays == 1)
        await model.detach()
    }

    @Test("Detaching while paused ends the parked drain; an attach made while paused catches up on resume")
    func detachWhilePaused() async throws {
        let session = makeSession()
        let model = makeModel()
        await model.attach(sessions: [session], currentUserId: "me-1")
        model.setLiveUpdatesPaused(true)
        await session.handle(event: .chatMessage(chatMessage(id: "m1")))
        try await Task.sleep(for: .milliseconds(20))   // the drain task parks
        await model.detach()

        // The pause follows the app, not the attach: a new attach's drain
        // parks as well.
        await model.attach(sessions: [session], currentUserId: "me-1")
        await session.handle(event: .chatMessage(chatMessage(id: "m2")))
        try await Task.sleep(for: .milliseconds(40))
        #expect(!model.lines.contains { $0.id == "m2" })

        model.setLiveUpdatesPaused(false)
        #expect(model.lines.last?.id == "m2")
        await model.detach()
    }

    // MARK: - Stuck-send fallback

    @Test("Held, an overdue send stays sending; release settles it at once")
    func heldFallbackWaitsForRelease() async throws {
        let store = TranscriptStore()
        let outgoing = OutgoingMessages(
            store: store,
            reconciler: OutgoingMessageReconciler(fallbackTimeout: .milliseconds(20))
        )
        let pendingId = outgoing.begin(text: "hi") { id in
            ChatLine(id: id, authorDisplayName: "me", runs: [.text("hi")], deliveryState: .sending)
        }
        outgoing.accepted(pendingId: pendingId, messageId: "msg-1")

        outgoing.setFallbacksHeld(true)
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.deliveryState(ofRow: pendingId) == .sending)
        #expect(!store.contains(id: "msg-1"))

        outgoing.setFallbacksHeld(false)
        #expect(store.deliveryState(ofRow: "msg-1") == .delivered)
        #expect(!store.contains(id: pendingId))
    }

    @Test("A send accepted while held arms no wake until the release")
    func acceptedWhileHeld() async throws {
        let store = TranscriptStore()
        let outgoing = OutgoingMessages(
            store: store,
            reconciler: OutgoingMessageReconciler(fallbackTimeout: .milliseconds(20))
        )
        outgoing.setFallbacksHeld(true)
        let pendingId = outgoing.begin(text: "hi") { id in
            ChatLine(id: id, authorDisplayName: "me", runs: [.text("hi")], deliveryState: .sending)
        }
        outgoing.accepted(pendingId: pendingId, messageId: "msg-1")
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.deliveryState(ofRow: pendingId) == .sending)

        outgoing.setFallbacksHeld(false)
        #expect(store.deliveryState(ofRow: "msg-1") == .delivered)
    }
}
