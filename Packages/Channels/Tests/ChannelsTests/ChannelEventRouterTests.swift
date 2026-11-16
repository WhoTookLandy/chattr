import Testing
import Foundation
import TwitchKit
@testable import Channels

/// `ChannelEventRouter` — the off-main table the per-account dispatcher
/// hands every EventSub event to. Sessions are real but never `start()`ed;
/// a `channel.chat_settings.update` event is the probe because handling it
/// leaves an observable trace (`currentChatRestrictions()`) without needing
/// a subscriber.
@Suite("ChannelEventRouter", .timeLimit(.minutes(1)))
struct ChannelEventRouterTests {

    private struct NullTokenStore: TwitchTokenStore {
        func loadToken() async throws -> OAuthToken? { nil }
        func saveToken(_ token: OAuthToken) async throws {}
        func deleteToken() async throws {}
    }

    private func makeSession(channelId: String) -> ChannelSession {
        ChannelSession(
            client: TwitchClient(clientId: "test-client", tokenStore: NullTokenStore()),
            channelId: channelId,
            channelLoginName: "ch\(channelId)",
            accountUserId: "me",
            fetchBackfill: { _, _ in [] }
        )
    }

    private func settingsUpdate(channelId: String, slowSeconds: Int) throws -> EventSubEvent {
        let json = """
        {
            "broadcaster_user_id": "\(channelId)",
            "broadcaster_user_login": "ch",
            "broadcaster_user_name": "Ch",
            "emote_mode": false,
            "follower_mode": false,
            "follower_mode_duration_minutes": null,
            "slow_mode": true,
            "slow_mode_wait_time_seconds": \(slowSeconds),
            "subscriber_mode": false,
            "unique_chat_mode": false
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return .chatSettingsUpdate(try decoder.decode(EventSubChatSettingsUpdate.self, from: Data(json.utf8)))
    }

    /// Spin until the session has handled a restrictions event (the inbox
    /// drains on its own task, so delivery is asynchronous by design).
    private func waitForSlowMode(_ session: ChannelSession, seconds: Int) async -> Bool {
        for _ in 0..<1_000 {
            if await session.currentChatRestrictions()?.slowModeSeconds == seconds { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return false
    }

    @Test("Events reach the session registered for their (account, channel)")
    func routesByKey() async throws {
        let router = ChannelEventRouter()
        let one = makeSession(channelId: "1")
        let two = makeSession(channelId: "2")
        router.register(one, for: .init(accountUserId: "me", channelId: "1"))
        router.register(two, for: .init(accountUserId: "me", channelId: "2"))

        router.route(try settingsUpdate(channelId: "2", slowSeconds: 30), accountUserId: "me")

        #expect(await waitForSlowMode(two, seconds: 30))
        #expect(await one.currentChatRestrictions() == nil)
    }

    @Test("Same channel id under another account is a different route")
    func accountIsPartOfTheKey() async throws {
        let router = ChannelEventRouter()
        let mine = makeSession(channelId: "1")
        router.register(mine, for: .init(accountUserId: "me", channelId: "1"))

        router.route(try settingsUpdate(channelId: "1", slowSeconds: 10), accountUserId: "someone-else")
        router.route(try settingsUpdate(channelId: "1", slowSeconds: 20), accountUserId: "me")

        // Only the second event belongs to this account's route; the first
        // matched no route and was dropped.
        #expect(await waitForSlowMode(mine, seconds: 20))
    }

    @Test("Unregister is identity-based: a stale session can't unroute its replacement")
    func unregisterByIdentity() {
        let router = ChannelEventRouter()
        let key = ChannelEventRouter.RouteKey(accountUserId: "me", channelId: "1")
        let old = makeSession(channelId: "1")
        let new = makeSession(channelId: "1")

        router.register(old, for: key)
        router.register(new, for: key)   // replaces `old`
        router.unregister(old)
        #expect(router.isRouted(key))

        router.unregister(new)
        #expect(!router.isRouted(key))
    }

    @Test("Events for unrouted channels are dropped without effect")
    func unroutedEventsDropped() throws {
        let router = ChannelEventRouter()
        router.route(try settingsUpdate(channelId: "404", slowSeconds: 5), accountUserId: "me")
        #expect(!router.isRouted(.init(accountUserId: "me", channelId: "404")))
    }
}
