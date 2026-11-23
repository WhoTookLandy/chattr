import Testing
import Foundation
import ChatModel
@testable import Features

/// `UserCardTarget` snapshots the tapped author's recent messages once, when
/// the card is opened.
@Suite("User card recent lines")
struct UserCardRecentLinesTests {

    private func message(_ id: String, by userId: String) -> ChatLine {
        ChatLine(
            id: id,
            authorUserId: userId,
            authorDisplayName: userId,
            authorUserLogin: userId,
            runs: [.text(id)]
        )
    }

    @Test("Only the author's messages, newest first")
    func filtersAndReverses() {
        let transcript = [
            message("a1", by: "alice"),
            message("b1", by: "bob"),
            message("a2", by: "alice"),
            message("a3", by: "alice"),
        ]
        let recent = UserCardTarget.recentLines(byAuthor: "alice", in: transcript, limit: 50)
        #expect(recent.map(\.id) == ["a3", "a2", "a1"])
    }

    @Test("Keeps the newest `limit` messages")
    func capsAtLimit() {
        let transcript = (1...10).map { message("m\($0)", by: "alice") }
        let recent = UserCardTarget.recentLines(byAuthor: "alice", in: transcript, limit: 3)
        #expect(recent.map(\.id) == ["m10", "m9", "m8"])
    }

    @Test("Deleted placeholders and bubbles don't count")
    func skipsNonMessages() {
        let bubble = ChatLine(
            id: "s1",
            kind: .systemBubble(text: "alice subscribed"),
            authorUserId: "alice",
            authorDisplayName: "alice",
            runs: []
        )
        let transcript = [
            message("a1", by: "alice"),
            message("a2", by: "alice").markingDeleted(),
            bubble,
        ]
        let recent = UserCardTarget.recentLines(byAuthor: "alice", in: transcript, limit: 50)
        #expect(recent.map(\.id) == ["a1"])
    }

    @Test("The target carries the snapshot taken at init")
    func targetSnapshotsAtInit() {
        let tapped = message("a2", by: "alice")
        let target = UserCardTarget(
            line: tapped,
            transcript: [message("a1", by: "alice"), message("b1", by: "bob"), tapped]
        )
        #expect(target.id == "a2")
        #expect(target.recentLines.map(\.id) == ["a2", "a1"])
    }

    @Test("Compact subtitle combines handle, join year, and message count cleanly")
    func compactSubtitleFormatting() {
        let joined = Date(timeIntervalSince1970: 1_577_836_800) // 2020-01-01 UTC
        let localized = UserCardSheet.compactSubtitle(
            displayName: "정서이",
            login: "jeongseoi",
            joinedAt: joined,
            recentCount: 3
        )
        #expect(localized.contains("@jeongseoi"))
        #expect(localized.contains("Joined "))
        #expect(localized.contains("3 msgs"))

        let sameHandle = UserCardSheet.compactSubtitle(
            displayName: "Alice",
            login: "alice",
            joinedAt: nil,
            recentCount: 1
        )
        #expect(sameHandle == "1 msg")
    }
}
