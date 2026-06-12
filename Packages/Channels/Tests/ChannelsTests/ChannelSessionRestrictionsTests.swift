import Testing
import Foundation
import TwitchKit
@testable import Channels

/// Tests for `applyInitialRestrictions(_:)` — the commit + fan-out path
/// behind making the start-time chat-restrictions fetch non-blocking.
///
/// `start()` no longer awaits the Helix `fetchChatSettings` round-trip before
/// exposing the session; instead it kicks the fetch off in the background and
/// the result reaches an already-attached tab reactively, as a
/// `.restrictionsUpdated` fan-out — exactly like a live
/// `channel.chat_settings.update` event. These tests pin that fan-out, the
/// nil/failure no-op, and the race guard that keeps a late-resolving Helix
/// snapshot from clobbering a fresher live update.
///
/// Same offline strategy as `ChannelSessionResyncTests`: a real but
/// never-`start()`ed session driven through the internal commit method
/// directly, so no network is touched.
@Suite("ChannelSession initial restrictions fan-out")
struct ChannelSessionRestrictionsTests {

    private actor Recorder {
        var events: [ChannelSession.ChannelEvent] = []
        func record(_ event: ChannelSession.ChannelEvent) { events.append(event) }
    }

    private func makeSession(recorder: Recorder) -> ChannelSession {
        struct NullTokenStore: TwitchTokenStore {
            func loadToken() async throws -> OAuthToken? { nil }
            func saveToken(_ token: OAuthToken) async throws {}
            func deleteToken() async throws {}
        }
        let client = TwitchClient(clientId: "test-client", tokenStore: NullTokenStore())
        return ChannelSession(
            client: client,
            channelId: "1",
            channelLoginName: "ch",
            accountUserId: "me",
            fetchBackfill: { _, _ in [] }
        )
    }

    /// Count how many of the recorded events are restrictions updates.
    private func restrictionEvents(
        _ events: [ChannelSession.ChannelEvent]
    ) -> [ChatRestrictions] {
        events.compactMap {
            if case .restrictionsUpdated(let r) = $0 { return r }
            return nil
        }
    }

    @Test("Initial restrictions fan out to an attached subscriber and seed the cache")
    func initialRestrictionsFanOut() async {
        let recorder = Recorder()
        let session = makeSession(recorder: recorder)
        await session.applyBackfill([])   // end the buffering window
        _ = await session.subscribe { event in await recorder.record(event) }

        await session.applyInitialRestrictions(ChatRestrictions(slowModeSeconds: 30))

        let restrictions = restrictionEvents(await recorder.events)
        #expect(restrictions.count == 1)
        #expect(restrictions.first?.slowModeSeconds == 30)
        #expect(await session.currentChatRestrictions()?.slowModeSeconds == 30)
    }

    @Test("A nil snapshot (fetch failed) fans out nothing and leaves the cache empty")
    func nilRestrictionsAreNoOp() async {
        let recorder = Recorder()
        let session = makeSession(recorder: recorder)
        await session.applyBackfill([])
        _ = await session.subscribe { event in await recorder.record(event) }

        await session.applyInitialRestrictions(nil)

        #expect(restrictionEvents(await recorder.events).isEmpty)
        #expect(await session.currentChatRestrictions() == nil)
    }

    @Test("A late Helix snapshot backs off once a live update already populated the cache")
    func initialRestrictionsBackOffAfterLiveUpdate() async throws {
        let recorder = Recorder()
        let session = makeSession(recorder: recorder)
        await session.applyBackfill([])
        _ = await session.subscribe { event in await recorder.record(event) }

        // A live `channel.chat_settings.update` lands first — followers-only.
        // handle() sets cachedRestrictionsAreLive = true and fans it out.
        let live = try chatSettingsUpdate(followerMode: true, followerDurationMinutes: 10)
        await session.handle(event: .chatSettingsUpdate(live))

        // The start-time Helix fetch resolves LATER with a stale snapshot
        // (slow mode, taken before the broadcaster toggled followers-only).
        await session.applyInitialRestrictions(ChatRestrictions(slowModeSeconds: 5))

        // Only the live update fanned out; the stale Helix snapshot backed off.
        let restrictions = restrictionEvents(await recorder.events)
        #expect(restrictions.count == 1)
        #expect(restrictions.first?.followersOnly == true)
        // Cache reflects the live value, not the stale Helix one.
        let cached = await session.currentChatRestrictions()
        #expect(cached?.followersOnly == true)
        #expect(cached?.slowModeSeconds == nil)
    }

    /// Decode a real `EventSubChatSettingsUpdate` from the wire shape (no
    /// public memberwise init), matching the moderation tests' fixture style.
    private func chatSettingsUpdate(
        followerMode: Bool,
        followerDurationMinutes: Int?
    ) throws -> EventSubChatSettingsUpdate {
        let durationJSON = followerDurationMinutes.map(String.init) ?? "null"
        let json = """
        {
            "broadcaster_user_id": "1",
            "broadcaster_user_login": "ch",
            "broadcaster_user_name": "Ch",
            "emote_mode": false,
            "follower_mode": \(followerMode),
            "follower_mode_duration_minutes": \(durationJSON),
            "slow_mode": false,
            "slow_mode_wait_time_seconds": null,
            "subscriber_mode": false,
            "unique_chat_mode": false
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(EventSubChatSettingsUpdate.self, from: Data(json.utf8))
    }
}
