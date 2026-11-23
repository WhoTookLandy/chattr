import Testing
import Foundation
import ChatModel
@testable import Features

/// `ChatRow`'s hand-written `==` is what lets SwiftUI skip re-rendering rows
/// whose inputs didn't change — and, since the list stopped forcing fresh row
/// identity on input changes, also what makes a row pick up a callback it
/// gained (e.g. Delete once mod status is learned). Closures are compared by
/// presence, never identity.
@Suite("ChatRow equality")
@MainActor
struct ChatRowEquatableTests {

    private let line = ChatLine(id: "m1", authorDisplayName: "alice", runs: [.text("hi")])

    @Test("Fresh closures with the same presence compare equal")
    func freshClosuresAreEqual() {
        let a = ChatRow(line: line, badgeEntries: [], onReply: {}, onDelete: {})
        let b = ChatRow(line: line, badgeEntries: [], onReply: {}, onDelete: {})
        #expect(a == b)
    }

    @Test("Gaining a callback (mod status learned → Delete) makes the row unequal")
    func gainingDeleteIsAChange() {
        let before = ChatRow(line: line, badgeEntries: [], onReply: {})
        let after = ChatRow(line: line, badgeEntries: [], onReply: {}, onDelete: {})
        #expect(before != after)
    }

    @Test("Losing a callback makes the row unequal")
    func losingReportIsAChange() {
        let before = ChatRow(line: line, badgeEntries: [], onBlock: {}, onReport: { _ in })
        let after = ChatRow(line: line, badgeEntries: [], onBlock: {})
        #expect(before != after)
    }

    @Test("Gaining or losing onAuthorTapped makes the row unequal")
    func togglingAuthorTapIsAChange() {
        let without = ChatRow(line: line, badgeEntries: [])
        let withTap = ChatRow(line: line, badgeEntries: [], onAuthorTapped: {})
        #expect(without != withTap)
        #expect(withTap == ChatRow(line: line, badgeEntries: [], onAuthorTapped: {}))
    }

    @Test("Line, badges and quote suppression still participate")
    func dataFieldsParticipate() {
        let base = ChatRow(line: line, badgeEntries: [])
        let otherLine = ChatRow(line: line.markingDeleted(), badgeEntries: [])
        let quoteless = ChatRow(line: line, badgeEntries: [], showsQuotedReply: false)
        #expect(base != otherLine)
        #expect(base != quoteless)
        #expect(base == ChatRow(line: line, badgeEntries: []))
    }
}
