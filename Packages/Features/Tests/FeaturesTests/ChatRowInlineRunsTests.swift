import Testing
import Foundation
import SwiftUI
import ChatModel
import EmoteSources
@testable import Features

/// The pure decisions behind how `ChatRow` lays a message's runs out: which
/// rows collapse into one `Text`, what that text says, and which zero-width
/// emotes stack on the emote before them.
@Suite("ChatRow inline runs")
@MainActor
struct ChatRowInlineRunsTests {

    private func emote(_ name: String, zeroWidth: Bool = false) -> LineRun {
        .emote(Emote(
            id: "7tv:\(name)",
            name: name,
            urls: [:],
            isAnimated: false,
            isZeroWidth: zeroWidth,
            source: .sevenTV
        ))
    }

    // MARK: - Single-Text rows

    @Test("Words, mentions and cheermotes are text-only; any emote is not")
    func textOnly() throws {
        #expect(ChatRow.isTextOnly([]))
        #expect(ChatRow.isTextOnly([
            .text("hi"),
            .mention(login: "xqc", isMe: false),
            .cheermote(prefix: "cheer", bits: 100, tier: 1),
        ]))
        #expect(!ChatRow.isTextOnly([.text("hi"), emote("Pog")]))

        let reference = try #require(AnonymousChatReader.twitchEmoteReference(id: "25"))
        #expect(!ChatRow.isTextOnly([.twitchEmote(reference: reference, displayName: "Kappa")]))
    }

    @Test("Runs join with single spaces, each kind in its visual form")
    func attributedBodyText() {
        let body = ChatRow.attributedBody(
            [
                .text("hello"),
                .mention(login: "xqc", isMe: false),
                .text("there"),
                .text("friend"),
                .cheermote(prefix: "cheer", bits: 100, tier: 1),
            ],
            font: .body
        )
        #expect(String(body.characters) == "hello @xqc there friend cheer100")
    }

    @Test("A link word keeps its URL; the words around it carry none")
    func attributedBodyLink() {
        let body = ChatRow.attributedBody(
            [.text("see"), .text("twitch.tv/xqc"), .text("now")],
            font: .body
        )
        #expect(String(body.characters) == "see twitch.tv/xqc now")

        let linked = body.runs.filter { $0.link != nil }
        #expect(linked.count == 1)
        #expect(linked.first?.link?.absoluteString == "https://twitch.tv/xqc")
        if let run = linked.first {
            #expect(String(body[run.range].characters) == "twitch.tv/xqc")
        }
    }

    @Test("No runs make an empty body")
    func attributedBodyEmpty() {
        #expect(ChatRow.attributedBody([], font: .body).characters.isEmpty)
    }

    // MARK: - Zero-width emotes

    @Test("A zero-width emote after an emote stacks on it")
    func overlayStacksOnPrecedingEmote() {
        let runs: [LineRun] = [.text("look"), emote("Pog"), emote("RainTime", zeroWidth: true), .text("wow")]
        #expect(!ChatRow.isStackedOverlay(runs, at: 1))
        #expect(ChatRow.isStackedOverlay(runs, at: 2))
        #expect(ChatRow.stackedOverlays(runs, after: 1) == 2..<3)
        #expect(ChatRow.stackedOverlays(runs, after: 0).isEmpty)
        #expect(ChatRow.stackedOverlays(runs, after: 3).isEmpty)
    }

    @Test("Several zero-width emotes in a row share one base")
    func consecutiveOverlaysShareTheBase() {
        let runs: [LineRun] = [
            emote("Pog"),
            emote("RainTime", zeroWidth: true),
            emote("PETPET", zeroWidth: true),
            emote("Clap"),
        ]
        #expect(ChatRow.stackedOverlays(runs, after: 0) == 1..<3)
        #expect(ChatRow.isStackedOverlay(runs, at: 1))
        #expect(ChatRow.isStackedOverlay(runs, at: 2))
        #expect(!ChatRow.isStackedOverlay(runs, at: 3))
        #expect(ChatRow.stackedOverlays(runs, after: 3).isEmpty)
    }

    @Test("A zero-width emote stacks on a Twitch emote too")
    func overlayStacksOnTwitchEmote() throws {
        let reference = try #require(AnonymousChatReader.twitchEmoteReference(id: "25"))
        let runs: [LineRun] = [
            LineRun.twitchEmote(reference: reference, displayName: "Kappa"),
            emote("RainTime", zeroWidth: true),
        ]
        #expect(ChatRow.isStackedOverlay(runs, at: 1))
        #expect(ChatRow.stackedOverlays(runs, after: 0) == 1..<2)
    }

    @Test("With no emote before it, a zero-width emote renders as a normal emote")
    func overlayWithoutBaseStandsAlone() {
        let leading: [LineRun] = [emote("RainTime", zeroWidth: true), .text("hi")]
        #expect(!ChatRow.isStackedOverlay(leading, at: 0))
        #expect(ChatRow.stackedOverlays(leading, after: 0).isEmpty)

        let afterText: [LineRun] = [.text("hi"), emote("RainTime", zeroWidth: true)]
        #expect(!ChatRow.isStackedOverlay(afterText, at: 1))
    }

    @Test("A stand-alone zero-width emote is the base for the ones after it")
    func standAloneOverlayIsABase() {
        let runs: [LineRun] = [
            .text("hi"),
            emote("RainTime", zeroWidth: true),
            emote("PETPET", zeroWidth: true),
        ]
        #expect(!ChatRow.isStackedOverlay(runs, at: 1))
        #expect(ChatRow.isStackedOverlay(runs, at: 2))
        #expect(ChatRow.stackedOverlays(runs, after: 1) == 2..<3)
    }
}
