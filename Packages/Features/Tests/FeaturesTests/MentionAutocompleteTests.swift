import Foundation
import Testing
import ChatModel
@testable import Features

@Suite("MentionAutocomplete")
struct MentionAutocompleteTests {
    private typealias C = MentionAutocomplete.Candidate

    private func msg(_ login: String, display: String? = nil, color: String = "") -> ChatLine {
        ChatLine(
            id: UUID().uuidString,
            authorUserId: login,
            authorDisplayName: display ?? login,
            authorUserLogin: login,
            authorColor: color,
            runs: [.text("hi")]
        )
    }

    // MARK: activeQuery

    @Test("Detects a mention as the draft's last token")
    func activeQuery() {
        #expect(MentionAutocomplete.activeQuery(in: "@") == "")
        #expect(MentionAutocomplete.activeQuery(in: "@sim") == "sim")
        #expect(MentionAutocomplete.activeQuery(in: "hey @Sim8") == "Sim8")
    }

    @Test("No mention once a space follows, or for non-mention tokens")
    func noActiveQuery() {
        #expect(MentionAutocomplete.activeQuery(in: "") == nil)
        #expect(MentionAutocomplete.activeQuery(in: "@sim88 ") == nil)
        #expect(MentionAutocomplete.activeQuery(in: "hello") == nil)
        #expect(MentionAutocomplete.activeQuery(in: "me@mail") == nil)
        #expect(MentionAutocomplete.activeQuery(in: "@@x") == nil)
    }

    // MARK: pool

    @Test("Pool is newest chatter first, deduped, without self, broadcaster appended")
    func pool() {
        let lines = [msg("alice"), msg("bob"), msg("me"), msg("alice", display: "Alice")]
        let pool = MentionAutocomplete.pool(
            from: lines, broadcasterLogin: "streamer", broadcasterDisplayName: "Streamer",
            excludingLogin: "me"
        )
        #expect(pool.map(\.login) == ["alice", "bob", "streamer"])
        #expect(pool.first?.displayName == "Alice")
    }

    @Test("Broadcaster who has chatted keeps their recency slot")
    func broadcasterNotDuplicated() {
        let pool = MentionAutocomplete.pool(
            from: [msg("streamer"), msg("bob")], broadcasterLogin: "Streamer",
            broadcasterDisplayName: "Streamer", excludingLogin: ""
        )
        #expect(pool.map(\.login) == ["bob", "streamer"])
    }

    @Test("Non-message lines are ignored")
    func ignoresNonMessages() {
        let system = ChatLine(id: "s", kind: .systemBubble(text: "x"), authorDisplayName: "", authorUserLogin: "sys", runs: [])
        let pool = MentionAutocomplete.pool(
            from: [system], broadcasterLogin: "", broadcasterDisplayName: "", excludingLogin: ""
        )
        #expect(pool.isEmpty)
    }

    // MARK: suggestions

    @Test("Prefix matches rank before substring matches; case-insensitive")
    func ranking() {
        let pool = [C(login: "xsimx", displayName: "xSimx", color: ""),
                    C(login: "sim88", displayName: "Sim88", color: ""),
                    C(login: "bob", displayName: "Bob", color: "")]
        let result = MentionAutocomplete.suggestions(for: "SIM", in: pool)
        #expect(result.map(\.login) == ["sim88", "xsimx"])
    }

    @Test("Empty query suggests the most recent chatters, capped")
    func emptyQuery() {
        let pool = (0..<20).map { C(login: "u\($0)", displayName: "u\($0)", color: "") }
        #expect(MentionAutocomplete.suggestions(for: "", in: pool, limit: 3).map(\.login) == ["u0", "u1", "u2"])
    }

    // MARK: complete

    @Test("Completion replaces the trailing @query and adds a space")
    func complete() {
        let sim = C(login: "sim88", displayName: "Sim88", color: "")
        #expect(MentionAutocomplete.complete("hey @si", with: sim) == "hey @Sim88 ")
        #expect(MentionAutocomplete.complete("@", with: sim) == "@Sim88 ")
    }

    @Test("Localized display names insert the login")
    func localizedInsertsLogin() {
        let c = C(login: "jeongseoi_", displayName: "정서이_", color: "")
        #expect(c.insertionName == "jeongseoi_")
        #expect(MentionAutocomplete.complete("@정", with: c) == "@jeongseoi_ ")
    }

    @Test("Completion is a no-op when no mention is being typed")
    func completeNoop() {
        let sim = C(login: "sim88", displayName: "Sim88", color: "")
        #expect(MentionAutocomplete.complete("hello ", with: sim) == "hello ")
    }
}
