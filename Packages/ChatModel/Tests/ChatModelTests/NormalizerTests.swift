import Testing
import Foundation
@testable import ChatModel
import EmoteSources
import TwitchKit

// Normalizer is a pure sync function — these tests are trivial fixture-in /
// expectation-out. Each test exercises one tokenization rule:
//
//   - text fragments → split + emote-resolve
//   - emote fragments → twitchEmote runs
//   - mention fragments → mention runs with isMe flag
//   - cheermote fragments → cheermote runs
//   - adjacent-text coalescing
//   - highlight keyword detection
//   - self-mention highlight
//
// No mock URLSession needed — the Normalizer takes a plain `[String: Emote]`
// dictionary as the emote source, so tests construct fixture emotes inline.

// MARK: - Fixture helpers

/// Build a minimal `Emote` for the tests. Most fields don't matter for
/// the tokenizer (it only reads `name`); we fill in URLs to satisfy the
/// constructor.
private func makeEmote(_ name: String, source: Emote.Source = .sevenTV) -> Emote {
    Emote(
        id: "test:\(name)",
        name: name,
        urls: [.x2: URL(string: "https://example.com/\(name).webp")!],
        isAnimated: false,
        isZeroWidth: false,
        source: source,
        ownerChannelId: nil
    )
}

/// TwitchKit value types only expose the synthesized `Decodable.init` —
/// they're meant to be parsed from real EventSub JSON. So our test
/// helpers build JSON fixtures and decode them, which has the bonus of
/// exercising the same code path that runs in production.

private struct FragmentSpec {
    enum Kind: String { case text, emote, mention, cheermote }
    let kind: Kind
    let text: String
    let emoteId: String?
    let mentionLogin: String?
    let mentionUserName: String?
}

private func textSpec(_ s: String) -> FragmentSpec {
    FragmentSpec(kind: .text, text: s, emoteId: nil, mentionLogin: nil, mentionUserName: nil)
}

private func emoteSpec(_ text: String, id: String = "twitch1") -> FragmentSpec {
    FragmentSpec(kind: .emote, text: text, emoteId: id, mentionLogin: nil, mentionUserName: nil)
}

private func mentionSpec(_ text: String, login: String, userName: String? = nil) -> FragmentSpec {
    FragmentSpec(
        kind: .mention,
        text: text,
        emoteId: nil,
        mentionLogin: login,
        mentionUserName: userName ?? login
    )
}

/// Build a `ChatMessage` by JSON-decoding a real EventSub-shaped fixture.
/// Only the fields the Normalizer reads are populated meaningfully; the
/// others get safe defaults so the struct decodes.
private func makeMessage(
    messageId: String = "m1",
    chatterUserName: String = "tester",
    fragments: [FragmentSpec]
) -> ChatMessage {
    let fragmentsJSON = fragments.map { spec -> [String: Any] in
        var dict: [String: Any] = ["type": spec.kind.rawValue, "text": spec.text]
        switch spec.kind {
        case .emote:
            dict["emote"] = [
                "id": spec.emoteId ?? "",
                "emote_set_id": "0",
            ]
        case .mention:
            dict["mention"] = [
                "user_id": "0",
                "user_login": spec.mentionLogin ?? "",
                "user_name": spec.mentionUserName ?? "",
            ]
        case .text, .cheermote:
            break
        }
        return dict
    }
    let messageJSON: [String: Any] = [
        "message_id": messageId,
        "broadcaster_user_id": "1",
        "broadcaster_user_login": "broadcaster",
        "broadcaster_user_name": "Broadcaster",
        "chatter_user_id": "2",
        "chatter_user_login": chatterUserName.lowercased(),
        "chatter_user_name": chatterUserName,
        "message": [
            "text": fragments.map(\.text).joined(),
            "fragments": fragmentsJSON,
        ],
        "color": "",
        "badges": [],
        "message_type": "text",
    ]
    let data = try! JSONSerialization.data(withJSONObject: messageJSON)
    // TwitchKit decodes EventSub payloads with `convertFromSnakeCase`.
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try! decoder.decode(ChatMessage.self, from: data)
}

// MARK: - Tests

@Suite("Normalizer tokenization")
struct NormalizerTokenizationTests {

    @Test("Plain text becomes one text run")
    func plainText() {
        let message = makeMessage(fragments: [textSpec("hello world")])
        let line = Normalizer.normalize(
            message: message,
            emoteSnapshot: [:],
            currentUserLogin: "me"
        )
        #expect(line.runs == [.text("hello world")])
        #expect(line.isHighlighted == false)
    }

    @Test("Twitch native emote between text words")
    func twitchEmoteInline() {
        let message = makeMessage(fragments: [
            textSpec("hi "),
            emoteSpec("Kappa"),
            textSpec(" wave"),
        ])
        let line = Normalizer.normalize(
            message: message,
            emoteSnapshot: [:],
            currentUserLogin: "me"
        )
        // Expect 3 runs: "hi ", twitchEmote(Kappa), " wave".
        try? #require(line.runs.count == 3)
        if case .text(let s) = line.runs[0] { #expect(s == "hi ") } else { Issue.record("run 0 not text") }
        if case .twitchEmote(let ref, let name) = line.runs[1] {
            #expect(ref.id == "twitch1")
            #expect(name == "Kappa")
        } else { Issue.record("run 1 not twitchEmote") }
        if case .text(let s) = line.runs[2] { #expect(s == " wave") } else { Issue.record("run 2 not text") }
    }

    @Test("3rd-party emote in text fragment is upgraded")
    func thirdPartyEmoteUpgrade() {
        let poggers = makeEmote("poggers")
        let message = makeMessage(fragments: [textSpec("lul poggers w")])
        let line = Normalizer.normalize(
            message: message,
            emoteSnapshot: ["poggers": poggers],
            currentUserLogin: "me"
        )
        // Expect: "lul ", emote(poggers), " w"
        try? #require(line.runs.count == 3)
        if case .text(let s) = line.runs[0] { #expect(s == "lul ") }
        if case .emote(let e) = line.runs[1] { #expect(e.name == "poggers") } else { Issue.record("middle run not emote") }
        if case .text(let s) = line.runs[2] { #expect(s == " w") }
    }

    @Test("Self-mention sets isMe and isHighlighted")
    func selfMention() {
        let message = makeMessage(fragments: [
            mentionSpec("@me", login: "me"),
            textSpec(" how are you"),
        ])
        let line = Normalizer.normalize(
            message: message,
            emoteSnapshot: [:],
            currentUserLogin: "me"
        )
        try? #require(line.runs.count == 2)
        if case .mention(let login, let isMe) = line.runs[0] {
            #expect(login == "me")
            #expect(isMe == true)
        } else { Issue.record("run 0 not mention") }
        #expect(line.isHighlighted == true)
    }

    @Test("Mention of another user has isMe = false and does not highlight")
    func mentionOther() {
        let message = makeMessage(fragments: [
            mentionSpec("@xqc", login: "xqc"),
            textSpec(" gg"),
        ])
        let line = Normalizer.normalize(
            message: message,
            emoteSnapshot: [:],
            currentUserLogin: "me"
        )
        if case .mention(_, let isMe) = line.runs[0] { #expect(isMe == false) }
        #expect(line.isHighlighted == false)
    }

    @Test("All-emote message produces alternating emote + text runs")
    func allEmote() {
        let kekw = makeEmote("KEKW")
        let lulw = makeEmote("LULW")
        let pog  = makeEmote("POG")
        let message = makeMessage(fragments: [textSpec("KEKW LULW POG")])
        let line = Normalizer.normalize(
            message: message,
            emoteSnapshot: ["KEKW": kekw, "LULW": lulw, "POG": pog],
            currentUserLogin: "me"
        )
        // Expect: [emote(KEKW), text(" "), emote(LULW), text(" "), emote(POG)]
        try? #require(line.runs.count == 5)
        if case .emote(let e) = line.runs[0] { #expect(e.name == "KEKW") }
        if case .text(let s)  = line.runs[1] { #expect(s == " ") }
        if case .emote(let e) = line.runs[2] { #expect(e.name == "LULW") }
        if case .text(let s)  = line.runs[3] { #expect(s == " ") }
        if case .emote(let e) = line.runs[4] { #expect(e.name == "POG") }
    }

    @Test("Highlight keyword detection (case-insensitive substring)")
    func keywordHighlight() {
        let message = makeMessage(fragments: [textSpec("guys watch this Clip right now")])
        let line = Normalizer.normalize(
            message: message,
            emoteSnapshot: [:],
            currentUserLogin: "me",
            highlightKeywords: ["clip"]   // lowercase
        )
        // "Clip" (capital C) in message; "clip" in keyword list. Case-insensitive substring match.
        #expect(line.isHighlighted == true)
    }

    @Test("Keyword in emote token does NOT highlight (emotes don't appear in text runs)")
    func keywordInsideEmoteIgnored() {
        let pog = makeEmote("clipit")  // "clip" is a substring of the emote NAME
        let message = makeMessage(fragments: [textSpec("clipit hello")])
        let line = Normalizer.normalize(
            message: message,
            emoteSnapshot: ["clipit": pog],
            currentUserLogin: "me",
            highlightKeywords: ["clip"]
        )
        // Token "clipit" matched the emote map → became .emote run, NOT a text run.
        // So the highlight check (which only scans text runs) shouldn't fire.
        #expect(line.isHighlighted == false)
    }

    @Test("Empty fragments produce empty runs")
    func emptyFragments() {
        let message = makeMessage(fragments: [])
        let line = Normalizer.normalize(
            message: message,
            emoteSnapshot: [:],
            currentUserLogin: "me"
        )
        #expect(line.runs.isEmpty)
    }

    @Test("Adjacent text from sequential text fragments is coalesced")
    func adjacentTextCoalesced() {
        // Two separate `.text` fragments arrive back-to-back. After
        // normalization they should collapse into one `.text` run, not stay
        // as two.
        let message = makeMessage(fragments: [
            textSpec("hello "),
            textSpec("world"),
        ])
        let line = Normalizer.normalize(
            message: message,
            emoteSnapshot: [:],
            currentUserLogin: "me"
        )
        #expect(line.runs == [.text("hello world")])
    }

    @Test("Whitespace preservation: trailing space before emote stays in text run")
    func trailingSpacePreserved() {
        let kappa = makeEmote("Kappa")
        let message = makeMessage(fragments: [textSpec("hi Kappa")])
        let line = Normalizer.normalize(
            message: message,
            emoteSnapshot: ["Kappa": kappa],
            currentUserLogin: "me"
        )
        // Expect: ["hi ", emote(Kappa)] — the space MUST be retained
        // (otherwise the renderer shows "hiKappa")
        try? #require(line.runs.count == 2)
        if case .text(let s) = line.runs[0] { #expect(s == "hi ") } else { Issue.record("expected text run") }
    }
}
