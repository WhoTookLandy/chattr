import Testing
import ChatModel
@testable import Features

@Suite("BlockFilter")
struct BlockFilterTests {
    private func line(_ author: String, kind: ChatLine.Kind = .message) -> ChatLine {
        ChatLine(
            id: "m-\(author)-\(kind)",
            kind: kind,
            authorUserId: author,
            authorDisplayName: author,
            runs: []
        )
    }

    @Test("Empty block set is the identity")
    func emptyIsIdentity() {
        let lines = [line("a"), line("b")]
        #expect(BlockFilter.apply(lines: lines, blockedIds: []) == lines)
    }

    @Test("Removes every line from a blocked author, any kind")
    func removesBlockedAuthorAllKinds() {
        let lines = [
            line("a"),
            line("villain"),
            line("villain", kind: .raidBubble(.init(fromBroadcasterDisplayName: "villain", viewers: 10))),
            line("b"),
        ]
        let result = BlockFilter.apply(lines: lines, blockedIds: ["villain"])
        #expect(result.map { $0.authorUserId } == ["a", "b"])
    }

    @Test("Lines from non-blocked authors pass through")
    func keepsUnblocked() {
        let lines = [line("a"), line("b")]
        #expect(BlockFilter.apply(lines: lines, blockedIds: ["villain"]) == lines)
    }
}
