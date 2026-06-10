import Testing
import Foundation
import ChatModel
@testable import Features

/// Tests for `TabChatModel`'s pure reply/thread/snippet helpers. These are the
/// static, side-effect-free pieces of the model — the parts that decide how a
/// reply chip is built and where a message sits in a thread. They're the
/// highest-confidence things to pin down because the renderer and the
/// thread-view sheet both depend on their exact output.
///
/// NOTE: the optimistic-send echo-reconciliation state machine (`apply`,
/// `upgradeOptimistic`, `cleanupPending`) and the 500-line ring buffer (`cap`,
/// `appendLines`) are `private` and driven by `ChannelSession.ChannelEvent`.
/// Covering them needs either a small visibility relaxation (`private` →
/// `internal`) or extraction of the pure matching decision out of `apply`.
/// That's the natural next increment now that this target exists.
@Suite("TabChatModel reply & snippet helpers")
@MainActor
struct TabChatModelReplyTests {

    // MARK: - snippet(from:cap:)

    @Test("Word runs join with single spaces, no ellipsis")
    func snippetShortText() {
        let runs: [LineRun] = [.text("hello"), .text("there")]
        #expect(TabChatModel.snippet(from: runs, cap: 80) == "hello there")
    }

    @Test("A legacy multi-word run passes through unchanged")
    func snippetLegacyMultiWordRun() {
        // Pre-word-runs ChatLines (e.g. persisted fixtures) may still
        // carry whitespace inside a single run — snippet must not
        // double-space or mangle them.
        let runs: [LineRun] = [.text("hello there")]
        #expect(TabChatModel.snippet(from: runs, cap: 80) == "hello there")
    }

    @Test("Over-cap text is truncated with an ellipsis")
    func snippetTruncates() {
        let runs: [LineRun] = [.text(String(repeating: "a", count: 100))]
        let out = TabChatModel.snippet(from: runs, cap: 80)
        #expect(out.hasSuffix("…"))
        // 80 chars + the ellipsis character.
        #expect(out.count == 81)
    }

    @Test("Mention runs render as @login")
    func snippetMention() {
        let runs: [LineRun] = [.text("hey"), .mention(login: "xqc", isMe: false)]
        #expect(TabChatModel.snippet(from: runs, cap: 80) == "hey @xqc")
    }

    @Test("Emote runs render as their name")
    func snippetCheermote() {
        let runs: [LineRun] = [.text("nice"), .cheermote(prefix: "cheer", bits: 100, tier: 1)]
        #expect(TabChatModel.snippet(from: runs, cap: 80) == "nice cheer100")
    }

    @Test("Grapheme-cluster emoji at the cut boundary doesn't crash or split")
    func snippetGraphemeSafety() {
        // Family emoji is a single Character but many scalars — prefix(cap)
        // must cut on Character boundaries, never mid-cluster.
        let runs: [LineRun] = [.text(String(repeating: "👨‍👩‍👧‍👦", count: 50))]
        let out = TabChatModel.snippet(from: runs, cap: 10)
        #expect(out.hasSuffix("…"))
        #expect(out.count == 11)
    }

    @Test("Empty runs produce an empty snippet")
    func snippetEmpty() {
        #expect(TabChatModel.snippet(from: [], cap: 80) == "")
    }

    // MARK: - threadRoot(of:)

    @Test("A non-reply line is its own thread root candidate")
    func threadRootForRootLine() {
        let line = ChatLine(id: "m1", authorDisplayName: "alice", runs: [.text("hi")])
        #expect(TabChatModel.threadRoot(of: line) == "m1")
    }

    @Test("A reply line's thread root is the parent's threadRootMessageId")
    func threadRootForReplyLine() {
        let reply = ChatLine.ReplyParent(
            parentMessageId: "m1",
            parentAuthorDisplayName: "alice",
            parentBody: "hi",
            threadRootMessageId: "root-0"
        )
        let line = ChatLine(id: "m2", authorDisplayName: "bob", runs: [.text("yo")], replyParent: reply)
        #expect(TabChatModel.threadRoot(of: line) == "root-0")
    }

    // MARK: - replyContext(for:)

    @Test("Replying to a root message roots the thread at that message")
    func replyContextFromRoot() {
        let line = ChatLine(id: "m1", authorDisplayName: "alice", runs: [.text("the question")])
        let ctx = TabChatModel.replyContext(for: line)
        #expect(ctx.parentMessageId == "m1")
        #expect(ctx.parentAuthorDisplayName == "alice")
        #expect(ctx.parentSnippet == "the question")
        // First reply: the line itself is the thread root.
        #expect(ctx.threadRootMessageId == "m1")
    }

    @Test("Replying mid-thread preserves the existing thread root")
    func replyContextMidThread() {
        let reply = ChatLine.ReplyParent(
            parentMessageId: "m1",
            parentAuthorDisplayName: "alice",
            parentBody: "the question",
            threadRootMessageId: "root-0"
        )
        let line = ChatLine(id: "m2", authorDisplayName: "bob", runs: [.text("an answer")], replyParent: reply)
        let ctx = TabChatModel.replyContext(for: line)
        #expect(ctx.parentMessageId == "m2")
        // Continuation must stay anchored to the original root, not re-root at m2.
        #expect(ctx.threadRootMessageId == "root-0")
    }

    @Test("Reply snippet is capped at 80 characters")
    func replyContextSnippetCapped() {
        let long = String(repeating: "x", count: 200)
        let line = ChatLine(id: "m1", authorDisplayName: "alice", runs: [.text(long)])
        let ctx = TabChatModel.replyContext(for: line)
        #expect(ctx.parentSnippet.count == 81) // 80 + ellipsis
    }
}
