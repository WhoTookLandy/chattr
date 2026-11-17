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

    @Test("a disabled kind never pops open")
    func disabledKind() {
        LiveEventsSettings.setEnabled(false, for: .poll)
        defer { UserDefaults.standard.removeObject(forKey: LiveEventsSettings.pollsKey) }
        let model = LiveEventsModel()
        model.receive(LiveEventsState(poll: poll()))
        #expect(model.expanded == nil)
    }
}
