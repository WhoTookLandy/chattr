import Foundation
import Testing
@testable import Features

@Suite("RecentEmotes")
struct RecentEmotesTests {
    private func emote(_ name: String) -> PickerEmote {
        PickerEmote(id: "test-\(name)", name: name)
    }

    @Test("Newest goes first and a reused emote moves to the front")
    func ordering() {
        var list: [PickerEmote] = []
        list = RecentEmotes.inserting(emote("A"), into: list)
        list = RecentEmotes.inserting(emote("B"), into: list)
        list = RecentEmotes.inserting(emote("A"), into: list)
        #expect(list.map(\.name) == ["A", "B"])
    }

    @Test("Keeps at most the limit")
    func cap() {
        var list: [PickerEmote] = []
        for i in 0..<(RecentEmotes.limit + 5) {
            list = RecentEmotes.inserting(emote("E\(i)"), into: list)
        }
        #expect(list.count == RecentEmotes.limit)
        #expect(list.first?.name == "E\(RecentEmotes.limit + 4)")
    }

    @Test("Round-trips through storage, per channel")
    func persistence() throws {
        let suite = "RecentEmotesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        RecentEmotes.record(emote("Kappa"), channel: "Alpha", defaults: defaults)
        RecentEmotes.record(emote("PogU"), channel: "alpha", defaults: defaults)

        #expect(RecentEmotes.load(channel: "alpha", defaults: defaults).map(\.name) == ["PogU", "Kappa"])
        #expect(RecentEmotes.load(channel: "beta", defaults: defaults).isEmpty)
    }
}

@Suite("SlowModeCooldown")
struct SlowModeCooldownTests {
    private let start = Date(timeIntervalSince1970: 1_000)

    @Test("Counts down and ends after the wait")
    func countdown() {
        let cooldown = SlowModeCooldown(startedAt: start, seconds: 30)
        #expect(cooldown.isActive(at: start))
        #expect(cooldown.remaining(at: start.addingTimeInterval(11.2)) == 19)
        #expect(cooldown.fractionRemaining(at: start.addingTimeInterval(15)) == 0.5)
        #expect(!cooldown.isActive(at: start.addingTimeInterval(30)))
        #expect(cooldown.remaining(at: start.addingTimeInterval(40)) == 0)
        #expect(cooldown.fractionRemaining(at: start.addingTimeInterval(40)) == 0)
    }
}
