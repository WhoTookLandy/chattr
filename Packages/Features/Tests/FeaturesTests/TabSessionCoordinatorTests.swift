import Testing
import Foundation
import TwitchKit
import ChatModel
import Core
@testable import Channels
@testable import Features

/// Stand-in for `ChannelSessionRegistry`: hands out real (never-started)
/// `ChannelSession`s and records every call in order. Failed acquires are
/// counted, not logged.
@MainActor
private final class FakeTabSessionRegistry: TabSessionRegistry {
    private struct AcquireFailure: Error {}

    private struct NullTokenStore: TwitchTokenStore {
        func loadToken() async throws -> OAuthToken? { nil }
        func saveToken(_ token: OAuthToken) async throws {}
        func deleteToken() async throws {}
    }

    var log: [String] = []
    var acquireFails = false
    private(set) var acquireAttempts = 0
    private(set) var sessions: [String: ChannelSession] = [:]

    /// Runs inside `release`, before the release is logged, with the
    /// session being released.
    var onRelease: (@MainActor (ChannelSession) async -> Void)?

    func acquire(
        accountUserId: String,
        accountLogin: String,
        channelId: String,
        channelLoginName: String
    ) async throws -> ChannelSession {
        acquireAttempts += 1
        if acquireFails { throw AcquireFailure() }
        log.append("acquire \(channelId)")
        if let existing = sessions[channelId] { return existing }
        let session = ChannelSession(
            client: TwitchClient(clientId: "test-client", tokenStore: NullTokenStore()),
            channelId: channelId,
            channelLoginName: channelLoginName,
            accountUserId: accountUserId,
            accountLogin: accountLogin,
            fetchBackfill: { _, _ in [] }
        )
        sessions[channelId] = session
        return session
    }

    func existingSession(accountUserId: String, channelId: String) -> ChannelSession? {
        log.append("existingSession \(channelId)")
        return sessions[channelId]
    }

    func release(accountUserId: String, channelId: String) async {
        if let session = sessions.removeValue(forKey: channelId) {
            await onRelease?(session)
        }
        log.append("release \(channelId)")
    }

    func releaseUnowned(accountUserId: String, channelId: String) async {
        log.append("releaseUnowned \(channelId)")
    }

    func releaseAll(forAccountUserId accountUserId: String) async {
        log.append("releaseAll \(accountUserId)")
    }
}

/// Stands in for the coordinator's retry wait: each `sleep` parks until
/// `advance()` and throws when its task is cancelled, like `Task.sleep`.
/// Serves one retry task at a time.
@MainActor
private final class RetryGate {
    private(set) var requested: [Duration] = []
    private let ticks: AsyncStream<Void>
    private let ticker: AsyncStream<Void>.Continuation

    init() {
        let (ticks, ticker) = AsyncStream<Void>.makeStream()
        self.ticks = ticks
        self.ticker = ticker
    }

    func sleep(_ duration: Duration) async throws {
        requested.append(duration)
        for await _ in ticks { return }
        throw CancellationError()
    }

    func advance() {
        ticker.yield(())
    }
}

/// Counts the updates a second subscriber of a session received.
@MainActor
private final class WatcherProbe {
    private(set) var received = 0
    func add(_ count: Int) { received += count }
}

/// `TabSessionCoordinator`: the bridge from a chat tab's lifetime to the
/// session registry, its mention watcher, and the account-wide sweep when a
/// shell goes away.
///
/// The watcher delivers from the session's own task, so the tests wait on
/// conditions rather than on time; the limit is a hang guard that also has
/// to cover time spent queued for the main actor on CI.
@Suite("TabSessionCoordinator", .timeLimit(.minutes(5)))
@MainActor
struct TabSessionCoordinatorTests {

    // MARK: - Fixtures

    private struct Shell {
        let registry: FakeTabSessionRegistry
        let navigation: AppNavigation
        let gate: RetryGate
        let coordinator: TabSessionCoordinator
        let accountUserId: String
    }

    /// A started coordinator for a fresh account whose login is "me".
    private func makeShell(keywords: [String] = []) -> Shell {
        let registry = FakeTabSessionRegistry()
        let navigation = AppNavigation()
        let gate = RetryGate()
        let coordinator = TabSessionCoordinator(
            sleep: { [gate] duration in try await gate.sleep(duration) },
            highlightKeywords: { keywords }
        )
        let accountUserId = "account-\(UUID().uuidString)"
        coordinator.start(
            accountUserId: accountUserId,
            accountLogin: "me",
            registry: registry,
            navigation: navigation
        )
        return Shell(
            registry: registry,
            navigation: navigation,
            gate: gate,
            coordinator: coordinator,
            accountUserId: accountUserId
        )
    }

    private func makeChannel(_ name: String) -> ChannelDescriptor {
        // Unique id so draft pruning in `close` can't collide with other
        // suites' UserDefaults entries.
        ChannelDescriptor(
            channelId: "\(name)-\(UUID().uuidString)", channelLoginName: name,
            channelDisplayName: name, profileImageURL: nil
        )
    }

    private func chatMessage(id: String, userId: String, text: String) -> ChatMessage {
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

    private func message(
        _ id: String,
        from userId: String,
        text: String,
        isHistorical: Bool = false
    ) -> ChannelUpdate {
        .normalizedMessage(
            chatMessage(id: id, userId: userId, text: text),
            isHistorical: isHistorical,
            timestamp: Date(timeIntervalSince1970: 0)
        )
    }

    /// Yields the main actor until `condition` holds. Unbounded on purpose
    /// (the suite's time limit is the guard): what it waits for may be
    /// coming from a session's task, which a fixed number of yields can
    /// outrun.
    private func waitUntil(_ condition: () -> Bool) async {
        while !condition() {
            await Task.yield()
        }
    }

    /// Lets queued main-actor tasks run.
    private func drain() async {
        for _ in 0..<50 { await Task.yield() }
    }

    // MARK: - Open and the mention watcher

    @Test("An open installs one watcher: another user's live mention marks the tab; history rows and own messages don't")
    func watcherMarksOnlyLiveMentionsFromOthers() async throws {
        let shell = makeShell(keywords: ["sentinel"])
        let channel = makeChannel("one")
        let tabId = shell.navigation.chatTabs.open(channel: channel)
        // The pager popped: a ping in the active tab only counts while its
        // chat is off screen.
        shell.navigation.chatTabs.isPresented = false
        await waitUntil { shell.coordinator.watcherCount(forTab: tabId) == 1 }
        #expect(shell.registry.log == ["acquire \(channel.channelId)"])
        let session = try #require(shell.registry.sessions[channel.channelId])

        // The keyword row mentions nobody and comes last: once it has been
        // filed, the two rows ahead of it have been through the watcher.
        await session.emit([
            message("history", from: "viewer-1", text: "@me from before the join", isHistorical: true),
            message("own", from: shell.accountUserId, text: "@me talking to myself"),
            message("marker", from: "viewer-1", text: "the sentinel word"),
        ])
        await waitUntil { shell.navigation.activity.entries.contains(where: { $0.id == "marker" }) }
        #expect(shell.navigation.activity.entries.map(\.id) == ["marker"])
        #expect(shell.navigation.activity.entries.first?.reason == .keyword)
        #expect(shell.navigation.chatTabs.mentionedTabIds.isEmpty)

        // The watcher marks the tab before it files the hit.
        await session.emit([message("ping", from: "viewer-1", text: "hey @me look")])
        await waitUntil { shell.navigation.activity.entries.contains(where: { $0.id == "ping" }) }
        #expect(shell.navigation.chatTabs.mentionedTabIds == [tabId])
        #expect(shell.navigation.activity.entries.first(where: { $0.id == "ping" })?.reason == .mention)
        #expect(shell.navigation.activity.unreadCount == 2)
        #expect(shell.coordinator.watcherCount(forTab: tabId) == 1)
    }

    // MARK: - Acquire retry

    @Test("A failed acquire is retried with backoff until it succeeds")
    func failedAcquireIsRetried() async {
        let shell = makeShell()
        shell.registry.acquireFails = true
        let tabId = shell.navigation.chatTabs.open(channel: makeChannel("one"))
        // The retry task is parked in its first wait.
        await waitUntil { shell.gate.requested.count == 1 }
        #expect(shell.registry.acquireAttempts == 1)

        shell.gate.advance()
        await waitUntil { shell.gate.requested.count == 2 }
        #expect(shell.registry.acquireAttempts == 2)
        #expect(shell.coordinator.watcherCount(forTab: tabId) == 0)

        shell.registry.acquireFails = false
        shell.gate.advance()
        await waitUntil { shell.coordinator.watcherCount(forTab: tabId) == 1 }
        #expect(shell.registry.acquireAttempts == 3)
        #expect(shell.gate.requested == Array(TabSessionCoordinator.acquireRetryDelays.prefix(2)))
    }

    @Test("Closing the tab ends its retries before the release")
    func closingStopsRetries() async {
        let shell = makeShell()
        shell.registry.acquireFails = true
        let channel = makeChannel("one")
        let tabId = shell.navigation.chatTabs.open(channel: channel)
        await waitUntil { shell.gate.requested.count == 1 }
        shell.gate.advance()
        await waitUntil { shell.gate.requested.count == 2 }
        #expect(shell.registry.acquireAttempts == 2)

        shell.navigation.chatTabs.close(tabId: tabId)
        // `onClose` cancels the retry and waits for it to end, then releases.
        await waitUntil { !shell.registry.log.isEmpty }
        shell.registry.acquireFails = false
        shell.gate.advance()
        await drain()

        #expect(shell.registry.acquireAttempts == 2)
        #expect(shell.registry.log == ["release \(channel.channelId)"])
        #expect(shell.coordinator.watcherCount(forTab: tabId) == 0)
    }

    // MARK: - Close and discard

    @Test("Closing a tab removes its watcher before releasing the session")
    func closeUnsubscribesBeforeRelease() async throws {
        let shell = makeShell()
        let channel = makeChannel("one")
        let tabId = shell.navigation.chatTabs.open(channel: channel)
        await waitUntil { shell.coordinator.watcherCount(forTab: tabId) == 1 }
        let session = try #require(shell.registry.sessions[channel.channelId])

        // A second subscriber, still attached when the tab's watcher is
        // gone: it shows that what `release` posts below was delivered.
        let probe = WatcherProbe()
        _ = await session.subscribe(onBatch: { [probe] batch in
            await probe.add(batch.count)
        })
        // Posted at release time. A watcher still subscribed then would
        // file it in Activity.
        let latePing = message("late", from: "viewer-1", text: "@me too late")
        shell.registry.onRelease = { [latePing] session in
            await session.emit([latePing])
        }

        shell.navigation.chatTabs.close(tabId: tabId)
        await waitUntil { probe.received == 1 }
        await waitUntil { shell.registry.log.count == 3 }
        await drain()

        #expect(shell.registry.log == [
            "acquire \(channel.channelId)",
            "existingSession \(channel.channelId)",
            "release \(channel.channelId)",
        ])
        #expect(shell.navigation.activity.entries.isEmpty)
        #expect(shell.coordinator.watcherCount(forTab: tabId) == 0)
    }

    @Test("A tab closed before its open ran only releases an unowned session")
    func discardReleasesUnowned() async {
        let shell = makeShell()
        let channel = makeChannel("one")
        let tabId = shell.navigation.chatTabs.open(channel: channel)
        // Before the scheduled open has had a turn.
        shell.navigation.chatTabs.close(tabId: tabId)
        await waitUntil { !shell.registry.log.isEmpty }
        await drain()

        #expect(shell.registry.log == ["releaseUnowned \(channel.channelId)"])
        #expect(shell.registry.acquireAttempts == 0)
    }

    // MARK: - Shell owners and the account-wide sweep

    @Test("retire is true only for the account's last live shell")
    func retireReportsLastShell() {
        let account = "account-\(UUID().uuidString)"
        let first = UUID()
        let second = UUID()
        ShellSessionOwners.live[account] = [first, second]

        #expect(!ShellSessionOwners.retire(first, forAccountUserId: account))
        // Already retired.
        #expect(!ShellSessionOwners.retire(first, forAccountUserId: account))
        #expect(ShellSessionOwners.retire(second, forAccountUserId: account))
        #expect(ShellSessionOwners.live[account] == nil)
        #expect(!ShellSessionOwners.retire(second, forAccountUserId: account))
    }

    @Test("The account is swept only when its last shell goes away")
    func sweepWaitsForLastShell() async {
        let registry = FakeTabSessionRegistry()
        let account = "account-\(UUID().uuidString)"
        // Two windows on one account.
        let firstNavigation = AppNavigation()
        let secondNavigation = AppNavigation()
        let first = TabSessionCoordinator()
        let second = TabSessionCoordinator()
        first.start(accountUserId: account, accountLogin: "me", registry: registry, navigation: firstNavigation)
        second.start(accountUserId: account, accountLogin: "me", registry: registry, navigation: secondNavigation)

        await first.stop(after: nil)?.value
        #expect(registry.log.isEmpty)

        await second.stop(after: nil)?.value
        #expect(registry.log == ["releaseAll \(account)"])
    }

    @Test("A shell that comes back while the old one's releases run is not swept")
    func returningShellIsNotSwept() async {
        let registry = FakeTabSessionRegistry()
        let account = "account-\(UUID().uuidString)"
        let oldNavigation = AppNavigation()
        let newNavigation = AppNavigation()
        let outgoing = TabSessionCoordinator()
        let returning = TabSessionCoordinator()
        outgoing.start(accountUserId: account, accountLogin: "me", registry: registry, navigation: oldNavigation)

        // The old shell's tab releases, still running when the new shell mounts.
        let (gate, openGate) = AsyncStream<Void>.makeStream()
        let releases = Task {
            for await _ in gate { break }
        }
        let stopping = outgoing.stop(after: releases)
        returning.start(accountUserId: account, accountLogin: "me", registry: registry, navigation: newNavigation)
        openGate.yield(())
        openGate.finish()
        await stopping?.value
        #expect(registry.log.isEmpty)

        await returning.stop(after: nil)?.value
        #expect(registry.log == ["releaseAll \(account)"])
    }

    @Test("A re-appearing shell re-registers itself, and its sweep follows the tabs' releases")
    func teardownSweepsAfterTabReleases() async {
        let shell = makeShell()
        // `onAppear` again on the same shell.
        shell.coordinator.start(
            accountUserId: shell.accountUserId,
            accountLogin: "me",
            registry: shell.registry,
            navigation: shell.navigation
        )
        let channel = makeChannel("one")
        let tabId = shell.navigation.chatTabs.open(channel: channel)
        await waitUntil { shell.coordinator.watcherCount(forTab: tabId) == 1 }

        let releases = shell.navigation.chatTabs.tearDown()
        await shell.coordinator.stop(after: releases)?.value

        #expect(shell.registry.log == [
            "acquire \(channel.channelId)",
            "existingSession \(channel.channelId)",
            "release \(channel.channelId)",
            "releaseAll \(shell.accountUserId)",
        ])
    }
}
