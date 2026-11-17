import Testing
import Foundation
import TwitchKit
@testable import Channels
@testable import Features

/// Banner-presentation rules on top of the Channels reducer: what pops open,
/// what stays folded, and what the close button hides.
@MainActor
@Suite("LiveEventsModel")
struct LiveEventsModelTests {

    private func poll(id: String = "p1", votes: [Int] = [0, 0], status: LivePoll.Status = .active) -> LivePoll {
        LivePoll(
            id: id,
            title: "Best map?",
            choices: votes.enumerated().map { LivePoll.Choice(id: "c\($0.offset)", title: "C\($0.offset)", votes: $0.element) },
            status: status,
            concludedAt: status.isConcluded ? Date() : nil
        )
    }

    @Test("a new poll pops its banner open; vote ticks leave the expansion alone")
    func attentionThenTicks() {
        // Isolated from any persisted user toggle.
        UserDefaults.standard.removeObject(forKey: LiveEventsSettings.pollsKey)
        let model = LiveEventsModel()

        model.receive(LiveEventsState(poll: poll()))
        #expect(model.expanded == .poll)

        model.toggle(.poll)
        #expect(model.expanded == nil)

        model.receive(LiveEventsState(poll: poll(votes: [3, 1])))
        #expect(model.expanded == nil)
        #expect(model.state.poll?.totalVotes == 4)

        // Concluding is news again.
        model.receive(LiveEventsState(poll: poll(votes: [3, 1], status: .completed)))
        #expect(model.expanded == .poll)
    }

    @Test("a dismissed event stays hidden; the next one shows")
    func dismissal() {
        UserDefaults.standard.removeObject(forKey: LiveEventsSettings.pollsKey)
        let model = LiveEventsModel()
        model.receive(LiveEventsState(poll: poll(id: "p1")))
        model.dismiss(.poll)
        #expect(model.isDismissed("p1"))
        #expect(model.expanded == nil)

        model.receive(LiveEventsState(poll: poll(id: "p1", status: .completed)))
        #expect(model.expanded == nil)

        model.receive(LiveEventsState(poll: poll(id: "p2")))
        #expect(!model.isDismissed("p2"))
        #expect(model.expanded == .poll)
    }

    @Test("suspending (page off-screen) folds the banner but keeps state and dismissals; resuming catches up")
    func suspendAndCatchUp() {
        UserDefaults.standard.removeObject(forKey: LiveEventsSettings.pollsKey)
        let model = LiveEventsModel()
        model.receive(LiveEventsState(poll: poll(id: "p1")))
        #expect(model.expanded == .poll)

        model.suspend()
        #expect(model.expanded == nil)
        #expect(model.state.poll?.id == "p1")

        // Back on screen: the poll ended meanwhile, which is news.
        model.receive(LiveEventsState(poll: poll(id: "p1", votes: [2, 1], status: .completed)))
        #expect(model.expanded == .poll)

        // A dismissal survives a suspend; only a detach (reset) forgets it.
        model.dismiss(.poll)
        model.suspend()
        #expect(model.isDismissed("p1"))
        model.reset()
        #expect(!model.isDismissed("p1"))
        #expect(model.state.isEmpty)
    }

    @Test("resuming with an unchanged snapshot re-arms the result timeout, so a finished banner still goes away")
    func unchangedResumeRearmsPrune() async throws {
        UserDefaults.standard.removeObject(forKey: LiveEventsSettings.pollsKey)
        let model = LiveEventsModel()
        // A finished poll whose linger runs out shortly.
        var finished = poll(id: "p1", votes: [2, 1], status: .completed)
        finished.concludedAt = Date().addingTimeInterval(-LiveEventsState.resultLinger + 0.3)
        let state = LiveEventsState(poll: finished)
        model.receive(state)
        #expect(model.isPruneScheduled)

        // Swiped away within the linger: the timer is cancelled.
        model.suspend()
        #expect(!model.isPruneScheduled)

        // Swiped back: `run` resumes, then the session primes the same
        // state, which `receive` ignores as unchanged.
        model.resume()
        model.receive(state)
        #expect(model.isPruneScheduled)

        // And the result really does go away on its own.
        for _ in 0..<50 where model.state.poll != nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(model.state.poll == nil)
    }

    @Test("a disabled kind never pops open")
    func disabledKind() {
        LiveEventsSettings.setEnabled(false, for: .poll)
        defer { UserDefaults.standard.removeObject(forKey: LiveEventsSettings.pollsKey) }
        let model = LiveEventsModel()
        model.receive(LiveEventsState(poll: poll()))
        #expect(model.expanded == nil)
    }

    // MARK: - Attention among hidden banners

    private func prediction(id: String = "pr1", status: LivePrediction.Status = .active) -> LivePrediction {
        LivePrediction(
            id: id,
            title: "Win?",
            outcomes: [
                LivePrediction.Outcome(id: "o1", title: "Yes", color: "BLUE", users: 1, points: 10),
                LivePrediction.Outcome(id: "o2", title: "No", color: "PINK", users: 1, points: 10),
            ],
            status: status
        )
    }

    @Test("a disabled Hype Train levelling up doesn't mask a poll result in the same snapshot")
    func disabledHigherPriorityDoesNotMask() {
        UserDefaults.standard.removeObject(forKey: LiveEventsSettings.pollsKey)
        LiveEventsSettings.setEnabled(false, for: .hypeTrain)
        defer { UserDefaults.standard.removeObject(forKey: LiveEventsSettings.hypeTrainKey) }
        let model = LiveEventsModel()

        model.receive(LiveEventsState(poll: poll(id: "p1"), hypeTrain: LiveHypeTrain(id: "t1", level: 1)))
        #expect(model.expanded == .poll)
        model.toggle(.poll)
        #expect(model.expanded == nil)

        // The train levels up (news, but its banner is off) as the poll
        // completes (news, and shown): the poll gets the attention.
        model.receive(LiveEventsState(
            poll: poll(id: "p1", votes: [2, 1], status: .completed),
            hypeTrain: LiveHypeTrain(id: "t1", level: 2)
        ))
        #expect(model.expanded == .poll)
    }

    @Test("a dismissed prediction locking doesn't mask a poll result in the same snapshot")
    func dismissedHigherPriorityDoesNotMask() {
        UserDefaults.standard.removeObject(forKey: LiveEventsSettings.pollsKey)
        UserDefaults.standard.removeObject(forKey: LiveEventsSettings.predictionsKey)
        let model = LiveEventsModel()

        model.receive(LiveEventsState(poll: poll(id: "p1"), prediction: prediction(id: "pr1")))
        model.dismiss(.prediction)
        #expect(model.expanded == nil)

        model.receive(LiveEventsState(
            poll: poll(id: "p1", votes: [2, 1], status: .completed),
            prediction: prediction(id: "pr1", status: .locked)
        ))
        #expect(model.expanded == .poll)
    }

    // MARK: - Run ownership

    private struct NullTokenStore: TwitchTokenStore {
        func loadToken() async throws -> OAuthToken? { nil }
        func saveToken(_ token: OAuthToken) async throws {}
        func deleteToken() async throws {}
    }

    /// Polls `condition` on the main actor for up to ~2s.
    private func eventually(_ condition: () async -> Bool) async throws -> Bool {
        for _ in 0..<200 {
            if await condition() { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    @Test("a superseded run exiting late leaves the replacement's result timeout armed")
    func supersededRunLeavesReplacementTimers() async throws {
        UserDefaults.standard.removeObject(forKey: LiveEventsSettings.pollsKey)
        // Not the account's own channel: no Helix traffic, just the mailbox.
        let session = ChannelSession(
            client: TwitchClient(clientId: "test-client", tokenStore: NullTokenStore()),
            channelId: "chan-1",
            channelLoginName: "somechannel",
            accountUserId: "me-1",
            fetchBackfill: { _, _ in [] }
        )
        // A finished poll lingering on screen: its result timeout is armed.
        await session.applyLiveEvent(.poll(poll(id: "p1", votes: [2, 1], status: .completed)))
        let model = LiveEventsModel()

        let first = Task { await model.run(session: session) }
        let primed = try await eventually { model.state.poll?.id == "p1" }
        #expect(primed)
        #expect(model.isPruneScheduled)

        // Probe reset so the replacement's re-arm is observable.
        model.suspend()
        #expect(!model.isPruneScheduled)

        // A rapid switch away and back: the replacement subscribes and
        // re-arms the timer before the first run's cancellation lands.
        let second = Task { await model.run(session: session) }
        let rearmed = try await eventually { model.isPruneScheduled }
        #expect(rearmed)

        // The first run now exits. It no longer owns the timers, so it
        // must not suspend the replacement's.
        first.cancel()
        await first.value
        #expect(model.isPruneScheduled)
        #expect(await session.liveEventSubscribers.count == 1)

        second.cancel()
        await second.value
        #expect(!model.isPruneScheduled)
        #expect(await session.liveEventSubscribers.isEmpty)
    }
}
