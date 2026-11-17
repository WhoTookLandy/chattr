import Testing
import Foundation
import ChatModel
@testable import Features

/// `ThreadView.replyTarget` picks what a send from the thread sheet replies
/// to. It must be a message Twitch knows: never the user's own undelivered
/// row (id `pending-…`), never a deleted placeholder.
@Suite("Thread sheet reply target")
@MainActor
struct ThreadReplyTargetTests {

    private let rootId = "root"

    private func root(kind: ChatLine.Kind = .message) -> ChatLine {
        ChatLine(
            id: rootId,
            kind: kind,
            authorUserId: "u-root",
            authorDisplayName: "Rooty",
            authorUserLogin: "rooty",
            runs: [.text("original")]
        )
    }

    private func reply(
        _ id: String,
        author: String = "Replier",
        kind: ChatLine.Kind = .message,
        state: ChatLine.DeliveryState = .delivered,
        parentId: String? = nil
    ) -> ChatLine {
        ChatLine(
            id: id,
            kind: kind,
            authorUserId: "u-\(author)",
            authorDisplayName: author,
            authorUserLogin: author.lowercased(),
            runs: [.text("reply")],
            deliveryState: state,
            replyParent: ChatLine.ReplyParent(
                parentMessageId: parentId ?? rootId,
                parentAuthorDisplayName: "Rooty",
                parentBody: "original",
                threadRootMessageId: rootId
            )
        )
    }

    @Test("Targets the latest delivered message")
    func latestDelivered() {
        let target = ThreadView.replyTarget(
            in: [root(), reply("r1"), reply("r2", author: "Second")],
            rootMessageId: rootId
        )
        #expect(target?.parentMessageId == "r2")
        #expect(target?.parentAuthorDisplayName == "Second")
        #expect(target?.threadRootMessageId == rootId)
    }

    @Test("Skips the user's own sending and failed rows")
    func skipsUndeliveredRows() {
        let lines = [
            root(),
            reply("r1"),
            reply("pending-1", author: "Me", state: .failed(reason: "dropped", retryText: "reply")),
            reply("pending-2", author: "Me", state: .sending),
        ]
        let target = ThreadView.replyTarget(in: lines, rootMessageId: rootId)
        #expect(target?.parentMessageId == "r1")
    }

    @Test("Skips deleted placeholders")
    func skipsDeleted() {
        let lines = [root(), reply("r1"), reply("r2").markingDeleted()]
        let target = ThreadView.replyTarget(in: lines, rootMessageId: rootId)
        #expect(target?.parentMessageId == "r1")
    }

    @Test("Falls back to the thread root when nothing else is deliverable")
    func fallsBackToRoot() {
        let lines = [
            root().markingDeleted(),
            reply("pending-1", author: "Me", state: .failed(reason: "dropped", retryText: "reply")),
        ]
        let target = ThreadView.replyTarget(in: lines, rootMessageId: rootId)
        #expect(target?.parentMessageId == rootId)
        #expect(target?.parentAuthorDisplayName == "Rooty")
        #expect(target?.threadRootMessageId == rootId)
    }

    @Test("A root that aged out is still the fallback, named from a direct reply")
    func fallsBackToAgedOutRoot() {
        let lines = [
            reply("r1").markingDeleted(),
            reply("pending-1", author: "Me", state: .sending, parentId: "r1"),
        ]
        let target = ThreadView.replyTarget(in: lines, rootMessageId: rootId)
        #expect(target?.parentMessageId == rootId)
        #expect(target?.parentAuthorDisplayName == "Rooty")
        #expect(target?.parentSnippet == "original")
        #expect(target?.threadRootMessageId == rootId)
    }

    @Test("An empty thread has no target")
    func emptyThread() {
        #expect(ThreadView.replyTarget(in: [], rootMessageId: rootId) == nil)
    }
}
