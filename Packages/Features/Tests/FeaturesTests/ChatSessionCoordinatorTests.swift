import Testing
import Foundation
import TwitchKit
import Core
import Accounts
@testable import Channels
@testable import Features

// MARK: - Fixtures

/// Counts events and lets a test wait for the nth one, so nothing here
/// sleeps to let another task "get there".
@MainActor
private final class Tally {
    private(set) var count = 0
    private var waiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func add() {
        count += 1
        var stillWaiting: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in waiters {
            if count >= waiter.target {
                waiter.continuation.resume()
            } else {
                stillWaiting.append(waiter)
            }
        }
        waiters = stillWaiting
    }

    func reach(_ target: Int) async {
        guard count < target else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.waiters.append((target: target, continuation: continuation))
        }
    }
}

/// Holds a start "in flight" until the test opens it.
@MainActor
private final class Gate {
    private var isOpen = false
    private var parked: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.parked.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let waiting = parked
        parked = []
        for continuation in waiting {
            continuation.resume()
        }
    }
}

private struct StartFailure: LocalizedError {
    var errorDescription: String? { "no route to chat" }
}

/// A scripted stand-in for the registry and the transcript model: each attach
/// plays the next step, and every detach is recorded with its epoch.
@MainActor
private final class ScriptedChat {
    enum Step {
        /// Attaches with `epoch` once `gate` (if any) opens. With
        /// `stopsWhenCancelled`, a start whose task was cancelled meanwhile
        /// throws `CancellationError` instead, as the registry's fetch does.
        case attaches(epoch: Int, after: Gate? = nil, stopsWhenCancelled: Bool = false)
        case fails(any Error)
    }

    private var steps: [Step]
    /// Attach calls begun (each may still be parked at its gate).
    let attachCalls = Tally()
    private(set) var detachedEpochs: [Int] = []
    var isAttached = false

    init(_ steps: Step...) {
        self.steps = steps
    }

    var link: ChatSessionCoordinator.Link {
        ChatSessionCoordinator.Link(
            channelLoginName: "somechannel",
            attach: { try await self.attach() },
            detach: { epoch in self.detachedEpochs.append(epoch) },
            isAttached: { self.isAttached }
        )
    }

    /// The link a screen with no registry in its environment would build.
    var linkWithoutRegistry: ChatSessionCoordinator.Link {
        ChatSessionCoordinator.Link(
            channelLoginName: "somechannel",
            attach: nil,
            detach: { epoch in self.detachedEpochs.append(epoch) },
            isAttached: { self.isAttached }
        )
    }

    private func attach() async throws -> Int {
        guard !steps.isEmpty else {
            Issue.record("attach called more often than the test scripted")
            throw CancellationError()
        }
        let step = steps.removeFirst()
        attachCalls.add()
        switch step {
        case .attaches(let epoch, let gate, let stopsWhenCancelled):
            await gate?.wait()
            if stopsWhenCancelled {
                try Task.checkCancellation()
            }
            isAttached = true
            return epoch
        case .fails(let error):
            throw error
        }
    }
}

// MARK: - Lease rules

/// The rules `ChatSessionCoordinator` keeps for `ChatScreen`: which attach
/// epoch each teardown detaches, and what Retry and the compose bar's
/// self-heal do around it. Driven through a scripted link — no registry, no
/// session, no model.
///
/// A "lifecycle" below is `run` in a task of its own, which is what
/// `.task(id: channelId)` gives it; cancelling that task is the view going
/// away. `run` holds on a year-long sleep that only cancellation ends, so
/// awaiting the cancelled task is exact, not timing.
///
/// The limit is a hang guard, and it counts time spent queued for the main
/// actor (see `ChatTranscriptModelPipelineTests`).
@Suite("ChatSessionCoordinator lease rules", .timeLimit(.minutes(5)))
@MainActor
struct ChatSessionCoordinatorTests {

    @Test("The lifecycle attaches on start and detaches that epoch when the view goes")
    func lifecycleAttachesThenDetaches() async {
        let chat = ScriptedChat(.attaches(epoch: 1))
        let coordinator = ChatSessionCoordinator()

        let lifecycle = Task { await coordinator.run(chat.link) }
        await chat.attachCalls.reach(1)
        #expect(chat.detachedEpochs.isEmpty)

        lifecycle.cancel()
        await lifecycle.value
        #expect(chat.detachedEpochs == [1])
        #expect(coordinator.errorMessage == nil)
    }

    @Test("A failed start shows the error and leaves the teardown holding the 0 sentinel")
    func failedStartShowsError() async {
        let chat = ScriptedChat(.fails(StartFailure()))
        let coordinator = ChatSessionCoordinator()

        let lifecycle = Task { await coordinator.run(chat.link) }
        await chat.attachCalls.reach(1)
        lifecycle.cancel()
        await lifecycle.value

        #expect(coordinator.errorMessage == "Couldn't open chat: no route to chat")
        #expect(chat.detachedEpochs == [0])
    }

    @Test("A cancelled start is silent: no error view")
    func cancelledStartIsSilent() async {
        let chat = ScriptedChat(.fails(CancellationError()))
        let coordinator = ChatSessionCoordinator()

        let lifecycle = Task { await coordinator.run(chat.link) }
        await chat.attachCalls.reach(1)
        lifecycle.cancel()
        await lifecycle.value

        #expect(coordinator.errorMessage == nil)
        #expect(chat.detachedEpochs == [0])
    }

    @Test("With no registry to ask, a start reports that and attaches nothing")
    func missingRegistry() async {
        let chat = ScriptedChat()
        let coordinator = ChatSessionCoordinator()

        await coordinator.reattachIfNeeded(chat.linkWithoutRegistry)

        #expect(coordinator.errorMessage == "Couldn't open chat: missing session registry")
        #expect(chat.attachCalls.count == 0)
        #expect(chat.detachedEpochs.isEmpty)
    }

    // MARK: Retry

    @Test("Retry after a failed start clears the error, and the teardown detaches what it attached")
    func retryAfterFailure() async throws {
        let chat = ScriptedChat(.fails(StartFailure()), .attaches(epoch: 1))
        let coordinator = ChatSessionCoordinator()
        let lifecycle = Task { await coordinator.run(chat.link) }
        await chat.attachCalls.reach(1)

        let retry = try #require(coordinator.retry(chat.link))
        await retry.value
        #expect(coordinator.errorMessage == nil)

        // Not the `0` sentinel the failed start left: that teardown would
        // no-op and leave the retry's subscription draining offscreen.
        lifecycle.cancel()
        await lifecycle.value
        #expect(chat.detachedEpochs == [1])
    }

    @Test("Retry dismisses the error view as it starts; failing again brings it back")
    func retryClearsErrorWhileInFlight() async throws {
        let gate = Gate()
        let chat = ScriptedChat(
            .fails(StartFailure()),
            .attaches(epoch: 1, after: gate),
            .fails(StartFailure())
        )
        let coordinator = ChatSessionCoordinator()
        let lifecycle = Task { await coordinator.run(chat.link) }
        await chat.attachCalls.reach(1)

        let retry = try #require(coordinator.retry(chat.link))
        await chat.attachCalls.reach(2)
        #expect(coordinator.errorMessage == nil)
        gate.open()
        await retry.value

        let again = try #require(coordinator.retry(chat.link))
        await again.value
        #expect(coordinator.errorMessage == "Couldn't open chat: no route to chat")

        lifecycle.cancel()
        await lifecycle.value
        #expect(chat.detachedEpochs == [1])
    }

    @Test("Retry after the view has gone starts nothing")
    func retryIgnoredAfterTeardown() async {
        let chat = ScriptedChat(.attaches(epoch: 1))
        let coordinator = ChatSessionCoordinator()
        let lifecycle = Task { await coordinator.run(chat.link) }
        await chat.attachCalls.reach(1)
        lifecycle.cancel()
        await lifecycle.value

        let started = coordinator.retry(chat.link) != nil
        #expect(!started)
        #expect(chat.attachCalls.count == 1)
    }

    @Test("The teardown cancels a Retry still in flight, which then ends silently")
    func teardownCancelsRetryInFlight() async throws {
        let gate = Gate()
        let chat = ScriptedChat(
            .fails(StartFailure()),
            .attaches(epoch: 1, after: gate, stopsWhenCancelled: true)
        )
        let coordinator = ChatSessionCoordinator()
        let lifecycle = Task { await coordinator.run(chat.link) }
        await chat.attachCalls.reach(1)
        let retry = try #require(coordinator.retry(chat.link))
        await chat.attachCalls.reach(2)

        lifecycle.cancel()
        await lifecycle.value
        #expect(retry.isCancelled)

        gate.open()
        await retry.value
        #expect(coordinator.errorMessage == nil)
        #expect(chat.detachedEpochs == [0])
    }

    @Test("A Retry that still attaches after the view has gone detaches its own attachment")
    func retryLandingAfterTeardownDetachesItself() async throws {
        let gate = Gate()
        let chat = ScriptedChat(
            .fails(StartFailure()),
            // Ignores its cancellation, like an attach already past the fetch.
            .attaches(epoch: 1, after: gate)
        )
        let coordinator = ChatSessionCoordinator()
        let lifecycle = Task { await coordinator.run(chat.link) }
        await chat.attachCalls.reach(1)
        let retry = try #require(coordinator.retry(chat.link))
        await chat.attachCalls.reach(2)

        lifecycle.cancel()
        await lifecycle.value
        #expect(chat.detachedEpochs == [0])

        // Its lease is closed: nobody else will tear this attachment down.
        gate.open()
        await retry.value
        #expect(chat.detachedEpochs == [0, 1])
    }

    // MARK: Self-heal

    @Test("The self-heal does nothing while the model is attached")
    func selfHealSkipsWhenAttached() async {
        let chat = ScriptedChat(.attaches(epoch: 1))
        let coordinator = ChatSessionCoordinator()
        let lifecycle = Task { await coordinator.run(chat.link) }
        await chat.attachCalls.reach(1)

        await coordinator.reattachIfNeeded(chat.link)
        #expect(chat.attachCalls.count == 1)

        lifecycle.cancel()
        await lifecycle.value
        #expect(chat.detachedEpochs == [1])
    }

    @Test("The self-heal re-attaches a model that lost its session, and the teardown detaches the new epoch")
    func selfHealRecordsIntoLiveLease() async {
        let chat = ScriptedChat(.attaches(epoch: 1), .attaches(epoch: 2))
        let coordinator = ChatSessionCoordinator()
        let lifecycle = Task { await coordinator.run(chat.link) }
        await chat.attachCalls.reach(1)

        chat.isAttached = false
        await coordinator.reattachIfNeeded(chat.link)
        #expect(chat.attachCalls.count == 2)
        #expect(chat.isAttached)

        lifecycle.cancel()
        await lifecycle.value
        #expect(chat.detachedEpochs == [2])
    }

    @Test("The self-heal after a failed start clears the error")
    func selfHealAfterFailure() async {
        let chat = ScriptedChat(.fails(StartFailure()), .attaches(epoch: 1))
        let coordinator = ChatSessionCoordinator()
        let lifecycle = Task { await coordinator.run(chat.link) }
        await chat.attachCalls.reach(1)

        await coordinator.reattachIfNeeded(chat.link)
        #expect(coordinator.errorMessage == nil)

        lifecycle.cancel()
        await lifecycle.value
        #expect(chat.detachedEpochs == [1])
    }

    @Test("A self-heal that lands after the view has gone detaches its own attachment")
    func selfHealLandingAfterTeardownDetachesItself() async {
        let gate = Gate()
        let chat = ScriptedChat(.attaches(epoch: 1), .attaches(epoch: 2, after: gate))
        let coordinator = ChatSessionCoordinator()
        let lifecycle = Task { await coordinator.run(chat.link) }
        await chat.attachCalls.reach(1)

        chat.isAttached = false
        let heal = Task { await coordinator.reattachIfNeeded(chat.link) }
        await chat.attachCalls.reach(2)

        lifecycle.cancel()
        await lifecycle.value
        #expect(chat.detachedEpochs == [1])

        gate.open()
        await heal.value
        #expect(chat.detachedEpochs == [1, 2])
    }

    // MARK: Overlapping starts and runs

    @Test("A superseded start that finishes late can't put its stale epoch back in the lease")
    func lateStartKeepsNewerEpoch() async {
        let gate = Gate()
        let chat = ScriptedChat(.attaches(epoch: 1, after: gate), .attaches(epoch: 2))
        let coordinator = ChatSessionCoordinator()
        // The lifecycle's own start is still in flight…
        let lifecycle = Task { await coordinator.run(chat.link) }
        await chat.attachCalls.reach(1)
        // …when a second one (the self-heal) attaches with a newer epoch.
        await coordinator.reattachIfNeeded(chat.link)
        #expect(chat.attachCalls.count == 2)

        // The first lands last, with the older epoch.
        gate.open()
        lifecycle.cancel()
        await lifecycle.value
        #expect(chat.detachedEpochs == [2])
    }

    @Test("Each run has its own lease: an outgoing run's teardown detaches only its own epoch")
    func newRunGetsNewLease() async {
        let chat = ScriptedChat(.attaches(epoch: 1), .attaches(epoch: 2), .attaches(epoch: 3))
        let coordinator = ChatSessionCoordinator()
        let outgoing = Task { await coordinator.run(chat.link) }
        await chat.attachCalls.reach(1)
        // The next run starts before the outgoing one has torn down.
        let incoming = Task { await coordinator.run(chat.link) }
        await chat.attachCalls.reach(2)
        // An out-of-band start now belongs to the incoming run.
        chat.isAttached = false
        await coordinator.reattachIfNeeded(chat.link)

        outgoing.cancel()
        await outgoing.value
        #expect(chat.detachedEpochs == [1])

        incoming.cancel()
        await incoming.value
        #expect(chat.detachedEpochs == [1, 3])
    }

    // MARK: AttachLease

    @Test("A lease keeps the newest epoch recorded into it")
    func leaseKeepsNewestEpoch() {
        let lease = AttachLease()
        #expect(lease.epoch == 0)
        lease.record(3)
        lease.record(2)
        #expect(lease.epoch == 3)
    }

    @Test("Closing a lease cancels the starts it tracks")
    func leaseCloseCancelsTrackedStarts() async {
        let gate = Gate()
        let lease = AttachLease()
        let start = Task { await gate.wait() }
        lease.track(start)
        #expect(!lease.isClosed)

        lease.close()
        #expect(lease.isClosed)
        #expect(start.isCancelled)
        gate.open()
        await start.value
    }
}

// MARK: - Against a real transcript model

/// The same entry points against a real `ChatTranscriptModel`, whose attach
/// epochs are what the lease rules exist for. The sessions are real but never
/// `start()`ed (see `ChatTranscriptModelModerationTests`), and the registry
/// in the last tests starts and stops them with no-ops, so nothing touches
/// the network.
@Suite("ChatSessionCoordinator with a transcript model", .timeLimit(.minutes(5)))
@MainActor
struct ChatSessionCoordinatorAttachmentTests {

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
            accountUserId: "me-1",
            accountLogin: "me",
            fetchBackfill: { _, _ in [] }
        )
    }

    /// Keeps UserDefaults, the draft store and the speaker out of it.
    private func makeModel() -> ChatTranscriptModel {
        ChatTranscriptModel(dependencies: ChatTranscriptDependencies(
            chatFilters: { ChatViewerPolicy.Filters() },
            clearDraft: { _ in },
            isHighlightSoundEnabled: { false },
            playHighlightSound: {}
        ))
    }

    /// A link that attaches `model` to `session`; `attaches` counts the
    /// attaches that have completed.
    private func makeLink(
        _ model: ChatTranscriptModel,
        _ session: ChannelSession,
        attaches: Tally
    ) -> ChatSessionCoordinator.Link {
        ChatSessionCoordinator.Link(
            channelLoginName: "somechannel",
            attach: {
                let epoch = await model.attach(
                    sessions: [session],
                    currentUserId: "me-1",
                    currentUserLogin: "me"
                )
                attaches.add()
                return epoch
            },
            detach: { epoch in await model.detach(ifEpoch: epoch) },
            isAttached: { model.attachState == .attached }
        )
    }

    @Test("The lifecycle attaches the model and detaches it when the view goes")
    func lifecycleAttachesModel() async {
        let model = makeModel()
        let attaches = Tally()
        let link = makeLink(model, makeSession(), attaches: attaches)
        let coordinator = ChatSessionCoordinator()

        let lifecycle = Task { await coordinator.run(link) }
        await attaches.reach(1)
        #expect(model.attachState == .attached)

        lifecycle.cancel()
        await lifecycle.value
        #expect(model.attachState == .detached)
    }

    @Test("A stale appearance's teardown can't detach the model a newer appearance re-attached")
    func staleTeardownLeavesNewerAttachment() async {
        let model = makeModel()
        let attaches = Tally()
        let link = makeLink(model, makeSession(), attaches: attaches)
        let coordinator = ChatSessionCoordinator()

        let stale = Task { await coordinator.run(link) }
        await attaches.reach(1)
        // The page re-mounts and re-attaches before the old task is gone.
        let current = Task { await coordinator.run(link) }
        await attaches.reach(2)

        stale.cancel()
        await stale.value
        #expect(model.attachState == .attached)

        current.cancel()
        await current.value
        #expect(model.attachState == .detached)
    }

    @Test("The self-heal re-attaches a detached model, and the teardown still detaches it")
    func selfHealReattachesModel() async {
        let model = makeModel()
        let attaches = Tally()
        let link = makeLink(model, makeSession(), attaches: attaches)
        let coordinator = ChatSessionCoordinator()
        let lifecycle = Task { await coordinator.run(link) }
        await attaches.reach(1)

        // The model loses its session under the screen.
        await model.detach()
        #expect(model.attachState == .detached)

        await coordinator.reattachIfNeeded(link)
        #expect(model.attachState == .attached)

        lifecycle.cancel()
        await lifecycle.value
        #expect(model.attachState == .detached)
    }

    // MARK: Production link

    private func makeRegistry() -> ChannelSessionRegistry {
        ChannelSessionRegistry(dependencies: .init(
            client: { _ in TwitchClient(clientId: "test-client", tokenStore: NullTokenStore()) },
            refreshTokens: { _, _ in },
            sessionActivity: SessionActivitySignal(),
            // Never connects, and makes no emote-provider requests.
            startSession: { _ in },
            stopSession: { _ in },
            loadEmoteIndex: { _, _, _ in }
        ))
    }

    /// The account is the channel's broadcaster, so attach settles mod status
    /// on the spot instead of fetching the moderated-channels list.
    private var account: Account {
        Account(userId: "me-1", login: "me", displayName: "Me", profileImageURL: "", tokenNamespace: "ns-me-1")
    }

    private var channel: ChannelDescriptor {
        ChannelDescriptor(
            channelId: "me-1", channelLoginName: "me",
            channelDisplayName: "Me", profileImageURL: nil
        )
    }

    @Test("The production link builds the session through the registry and attaches the model to it")
    func liveLinkAttachesThroughRegistry() async throws {
        let registry = makeRegistry()
        let model = makeModel()
        let coordinator = ChatSessionCoordinator()
        let link = ChatSessionCoordinator.Link.live(
            registry: registry, chatModel: model, account: account, channel: channel
        )

        // The self-heal path: a send finds no session, so one is built.
        await coordinator.reattachIfNeeded(link)

        #expect(coordinator.errorMessage == nil)
        #expect(model.attachState == .attached)
        let session = try await registry.session(
            accountUserId: "me-1", accountLogin: "me",
            channelId: "me-1", channelLoginName: "me"
        )
        let attachedToRegistrySession = model.liveEventsSession === session
        #expect(attachedToRegistrySession)

        await model.detach()
        await registry.releaseUnowned(accountUserId: "me-1", channelId: "me-1")
    }

    @Test("The production link without a registry reports it and leaves the model detached")
    func liveLinkWithoutRegistry() async {
        let model = makeModel()
        let coordinator = ChatSessionCoordinator()
        let link = ChatSessionCoordinator.Link.live(
            registry: nil, chatModel: model, account: account, channel: channel
        )

        await coordinator.reattachIfNeeded(link)

        #expect(coordinator.errorMessage == "Couldn't open chat: missing session registry")
        #expect(model.attachState == .detached)
    }
}
