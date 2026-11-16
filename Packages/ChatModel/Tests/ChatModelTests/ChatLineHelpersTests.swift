import Testing
import Foundation
@testable import ChatModel
import EmoteSources

/// The small value helpers ChatModel offers its consumers: the delivery-state
/// copy the optimistic-send lifecycle uses, and the run → plain-text mapping
/// shared by reply snippets and VoiceOver labels.
@Suite("ChatLine / LineRun helpers")
struct ChatLineHelpersTests {

    private func sendingLine() -> ChatLine {
        ChatLine(
            id: "pending-1",
            kind: .message,
            authorUserId: "me-1",
            authorDisplayName: "デレク",
            authorUserLogin: "derek",
            authorColor: "#FF69B4",
            runs: [.text("hello"), .mention(login: "chat", isMe: false)],
            isHighlighted: true,
            timestamp: Date(timeIntervalSince1970: 42),
            deliveryState: .sending,
            replyParent: ChatLine.ReplyParent(
                parentMessageId: "p",
                parentAuthorDisplayName: "Alice",
                parentBody: "question",
                threadRootMessageId: "root"
            )
        )
    }

    // MARK: - with(deliveryState:id:)

    @Test("A state-only change keeps the id and every other field")
    func stateOnlyCopy() {
        let original = sendingLine()
        let failed = original.with(deliveryState: .failed(reason: "slow mode", retryText: "hello @chat"))

        #expect(failed.id == original.id)
        #expect(failed.deliveryState == .failed(reason: "slow mode", retryText: "hello @chat"))
        var expected = original
        expected.deliveryState = failed.deliveryState
        #expect(failed == expected, "only deliveryState may change")
    }

    @Test("A re-key moves the row to the new id and keeps its content, styling and thread")
    func rekeyedCopy() {
        let original = sendingLine()
        let settled = original.with(deliveryState: .delivered, id: "msg-1")

        #expect(settled.id == "msg-1")
        #expect(settled.deliveryState == .delivered)
        #expect(settled.runs == original.runs)
        #expect(settled.authorDisplayName == original.authorDisplayName)
        #expect(settled.authorUserLogin == original.authorUserLogin)
        #expect(settled.authorColor == original.authorColor)
        #expect(settled.isHighlighted == original.isHighlighted)
        #expect(settled.timestamp == original.timestamp)
        #expect(settled.replyParent == original.replyParent)
        #expect(settled.isHistorical == original.isHistorical)
        #expect(settled.hasLocalizedDisplayName == original.hasLocalizedDisplayName)
    }

    @Test("Passing the line's own id is a state-only change")
    func sameIdIsStateOnly() {
        let original = sendingLine()
        #expect(original.with(deliveryState: .delivered, id: original.id)
            == original.with(deliveryState: .delivered))
    }

    // MARK: - LineRun.plainText

    private let emote = Emote(
        id: "7tv:pog",
        name: "POGGERS",
        urls: [.x2: URL(string: "https://example.com/pog.webp")!],
        isAnimated: false,
        isZeroWidth: false,
        source: .sevenTV
    )

    @Test("Visual style: words, emote names, @mentions, compact cheermotes")
    func visualPlainText() {
        #expect(LineRun.text("hello").plainText() == "hello")
        #expect(LineRun.emote(emote).plainText() == "POGGERS")
        #expect(LineRun.mention(login: "xqc", isMe: false).plainText() == "@xqc")
        #expect(LineRun.cheermote(prefix: "cheer", bits: 100, tier: 1).plainText() == "cheer100")
    }

    @Test("Spoken style differs only for cheermotes, which spell out the bits")
    func spokenPlainText() {
        #expect(LineRun.text("hello").plainText(.spoken) == "hello")
        #expect(LineRun.emote(emote).plainText(.spoken) == "POGGERS")
        #expect(LineRun.mention(login: "xqc", isMe: true).plainText(.spoken) == "@xqc")
        #expect(LineRun.cheermote(prefix: "cheer", bits: 100, tier: 1).plainText(.spoken) == "cheer 100 bits")
    }
}
