import Testing
import Foundation
import Channels
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
}
