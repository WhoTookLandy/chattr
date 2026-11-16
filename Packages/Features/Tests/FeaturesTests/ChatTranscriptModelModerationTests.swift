import Testing
import Foundation
import TwitchKit
import Channels
@testable import Features

/// Tests for the attach-time `currentUserCanModerate` seeding paths:
/// the instant broadcaster check and the moderated-channels pre-seed
/// (`moderatedChannelIds` provider), plus the live mod/unmod events. The
/// badge-observation upgrade path is covered in
/// `ChatTranscriptModelDependencyTests`.
///
/// The `ChannelSession`s here are real but never `start()`ed, so nothing
/// touches the network or Twitch. attach only exercises offline-safe
/// members: `subscribe` registers a handler on the actor,
/// `currentChatRestrictions()` reads a nil cache, and the chat-color
/// fetch is fire-and-forget and swallows its offline failure.
@Suite("ChatTranscriptModel moderation seeding")
@MainActor
struct ChatTranscriptModelModerationTests {

    /// Token store that holds nothing — keeps the offline `TwitchClient`
    /// away from the real Keychain during tests.
    private struct NullTokenStore: TwitchTokenStore {
        func loadToken() async throws -> OAuthToken? { nil }
        func saveToken(_ token: OAuthToken) async throws {}
        func deleteToken() async throws {}
    }

    private func makeSession(channelId: String, accountUserId: String) -> ChannelSession {
        let client = TwitchClient(clientId: "test-client", tokenStore: NullTokenStore())
        return ChannelSession(
            client: client,
            channelId: channelId,
            channelLoginName: "somechannel",
            accountUserId: accountUserId
        )
    }

    @Test("Broadcaster is seeded instantly at attach, no fetch involved")
    func broadcasterInstant() async {
        let model = ChatTranscriptModel()
        // accountUserId == channelId → the broadcaster check fires.
        let session = makeSession(channelId: "user-1", accountUserId: "user-1")

        await model.attach(sessions: [session], currentUserId: "user-1")

        #expect(model.currentUserCanModerate)
        // No provider passed → no seed task should have been spawned.
        #expect(model.moderationSeedTask == nil)
        await model.detach()
    }

    @Test("Channel in the moderated set → flag flips once the seed lands")
    func moderatedChannelSeeds() async {
        let model = ChatTranscriptModel()
        let session = makeSession(channelId: "chan-9", accountUserId: "user-1")

        await model.attach(
            sessions: [session],
            currentUserId: "user-1",
            moderatedChannelIds: { ["chan-3", "chan-9"] }
        )
        // attach fires the seed concurrently; await it for determinism.
        await model.moderationSeedTask?.value

        #expect(model.currentUserCanModerate)
        await model.detach()
    }

    @Test("Channel NOT in the moderated set → flag stays false")
    func unmoderatedChannelStaysFalse() async {
        let model = ChatTranscriptModel()
        let session = makeSession(channelId: "chan-9", accountUserId: "user-1")

        await model.attach(
            sessions: [session],
            currentUserId: "user-1",
            moderatedChannelIds: { ["chan-3", "chan-5"] }
        )
        await model.moderationSeedTask?.value

        #expect(!model.currentUserCanModerate)
        await model.detach()
    }

    @Test("Fetch failure (empty set, the registry's degraded result) → flag stays false")
    func fetchFailureStaysFalse() async {
        let model = ChatTranscriptModel()
        let session = makeSession(channelId: "chan-9", accountUserId: "user-1")

        // `ChannelSessionRegistry.moderatedChannelIds` maps every fetch
        // error (missing scope, network) to an empty set — the model must
        // treat that as "no pre-knowledge" and leave the badge-observation
        // path to do its thing.
        await model.attach(
            sessions: [session],
            currentUserId: "user-1",
            moderatedChannelIds: { [] }
        )
        await model.moderationSeedTask?.value

        #expect(!model.currentUserCanModerate)
        await model.detach()
    }

    @Test("Broadcaster short-circuits the seed — no task spawned even with a provider")
    func broadcasterSkipsSeed() async {
        let model = ChatTranscriptModel()
        let session = makeSession(channelId: "user-1", accountUserId: "user-1")

        await model.attach(
            sessions: [session],
            currentUserId: "user-1",
            moderatedChannelIds: { ["user-1"] }
        )

        #expect(model.currentUserCanModerate)
        // The broadcaster check made the fetch redundant; attach must not
        // have started one.
        #expect(model.moderationSeedTask == nil)
        await model.detach()
    }

    @Test("Live unmod downgrades the flag and fires the revocation hook")
    func liveUnmodDowngrades() async {
        let model = ChatTranscriptModel()
        // Broadcaster attach so the flag starts true without any fetch.
        let session = makeSession(channelId: "user-1", accountUserId: "user-1")
        let (hookFired, continuation) = AsyncStream.makeStream(of: Void.self)

        await model.attach(
            sessions: [session],
            currentUserId: "user-1",
            onModerationRevoked: { continuation.yield() }
        )
        #expect(model.currentUserCanModerate)

        model.apply(.moderationStatusChanged(canModerate: false))

        #expect(!model.currentUserCanModerate)
        // The hook runs in a fire-and-forget Task — await its signal
        // rather than asserting on a side effect that may not have
        // landed yet.
        var signals = hookFired.makeAsyncIterator()
        _ = await signals.next()
        await model.detach()
    }

    @Test("Live mod event upgrades the flag mid-session")
    func liveModUpgrades() async {
        let model = ChatTranscriptModel()
        let session = makeSession(channelId: "chan-9", accountUserId: "user-1")

        await model.attach(sessions: [session], currentUserId: "user-1")
        #expect(!model.currentUserCanModerate)

        model.apply(.moderationStatusChanged(canModerate: true))

        #expect(model.currentUserCanModerate)
        await model.detach()
    }

    @Test("detach cancels an unresolved seed so it can't flip the flag late")
    func detachCancelsSeed() async {
        let model = ChatTranscriptModel()
        let session = makeSession(channelId: "chan-9", accountUserId: "user-1")

        // A provider that parks until cancellation, simulating a slow
        // first-open Helix fetch that's still in flight when the user
        // closes the tab.
        await model.attach(
            sessions: [session],
            currentUserId: "user-1",
            moderatedChannelIds: {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                return ["chan-9"]
            }
        )
        let seed = model.moderationSeedTask
        await model.detach()
        await seed?.value

        // The set named our channel, but the result landed post-detach —
        // the cancellation guard must have dropped it.
        #expect(!model.currentUserCanModerate)
    }
}
