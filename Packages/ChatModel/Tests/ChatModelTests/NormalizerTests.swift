import Testing
import Foundation
@testable import ChatModel
import EmoteSources
import TwitchKit

// Normalizer is a pure sync function — these tests are trivial fixture-in /
// expectation-out. Each test exercises one tokenization rule:
//
//   - text fragments → split into per-word runs + emote-resolve
//   - emote fragments → twitchEmote runs
//   - mention fragments → mention runs with isMe flag
//   - cheermote fragments → cheermote runs
//   - cross-fragment text buffering (no word split at fragment seams)
//   - highlight keyword detection (incl. phrases spanning words)
//   - self-mention highlight
//
// Text runs are WORD-LEVEL and never contain whitespace: the renderer's
// FlowLayout wraps between runs, so every word must be its own run for
// chat lines to wrap naturally. Inter-word spacing is the layout's job
// (FlowLayout spacing), not the data's.
//
// No mock URLSession needed — the Normalizer takes a plain `[String: Emote]`
// dictionary as the emote source, so tests construct fixture emotes inline.

// MARK: - Fixture helpers

/// Fixed send time for every normalized fixture — the Normalizer no longer
/// reads the clock, so lines built from the same message compare equal.
private let testStamp = Date(timeIntervalSince1970: 1_700_000_000)

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
    fragments: [FragmentSpec],
    replyToLogin: String? = nil
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
    var messageJSON: [String: Any] = [
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
    if let replyToLogin {
        messageJSON["reply"] = [
            "parent_message_id": "parent1",
            "parent_message_body": "the parent body",
            "parent_user_id": "9",
            "parent_user_login": replyToLogin,
            "parent_user_name": replyToLogin,
            "thread_message_id": "thread1",
            "thread_user_id": "9",
            "thread_user_login": replyToLogin,
            "thread_user_name": replyToLogin,
        ]
    }
    let data = try! JSONSerialization.data(withJSONObject: messageJSON)
    // TwitchKit decodes EventSub payloads with `convertFromSnakeCase`.
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try! decoder.decode(ChatMessage.self, from: data)
}

// MARK: - Tests

@Suite("Normalizer tokenization")
struct NormalizerTokenizationTests {

    @Test("Plain text becomes one run per word, no whitespace runs")
    func plainText() {
        let message = makeMessage(fragments: [textSpec("hello world")])
        let line = Normalizer.normalize(
            message: message,
            emoteSnapshot: [:],
            currentUserLogin: "me", timestamp: testStamp
        )
        #expect(line.runs == [.text("hello"), .text("world")])
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
            currentUserLogin: "me", timestamp: testStamp
        )
        // Expect 3 runs: "hi", twitchEmote(Kappa), "wave" — surrounding
        // whitespace is dropped (FlowLayout spacing renders the gaps).
        try? #require(line.runs.count == 3)
        if case .text(let s) = line.runs[0] { #expect(s == "hi") } else { Issue.record("run 0 not text") }
        if case .twitchEmote(let ref, let name) = line.runs[1] {
            #expect(ref.id == "twitch1")
            #expect(name == "Kappa")
        } else { Issue.record("run 1 not twitchEmote") }
        if case .text(let s) = line.runs[2] { #expect(s == "wave") } else { Issue.record("run 2 not text") }
    }

    @Test("3rd-party emote in text fragment is upgraded")
    func thirdPartyEmoteUpgrade() {
        let poggers = makeEmote("poggers")
        let message = makeMessage(fragments: [textSpec("lul poggers w")])
        let line = Normalizer.normalize(
            message: message,
            emoteSnapshot: ["poggers": poggers],
            currentUserLogin: "me", timestamp: testStamp
        )
        // Expect: "lul", emote(poggers), "w"
        try? #require(line.runs.count == 3)
        if case .text(let s) = line.runs[0] { #expect(s == "lul") }
        if case .emote(let e) = line.runs[1] { #expect(e.name == "poggers") } else { Issue.record("middle run not emote") }
        if case .text(let s) = line.runs[2] { #expect(s == "w") }
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
            currentUserLogin: "me", timestamp: testStamp
        )
        try? #require(line.runs.count == 4)  // mention + "how" + "are" + "you"
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
            currentUserLogin: "me", timestamp: testStamp
        )
        if case .mention(_, let isMe) = line.runs[0] { #expect(isMe == false) }
        #expect(line.isHighlighted == false)
    }

    @Test("All-emote message produces only emote runs — no whitespace runs")
    func allEmote() {
        let kekw = makeEmote("KEKW")
        let lulw = makeEmote("LULW")
        let pog  = makeEmote("POG")
        let message = makeMessage(fragments: [textSpec("KEKW LULW POG")])
        let line = Normalizer.normalize(
            message: message,
            emoteSnapshot: ["KEKW": kekw, "LULW": lulw, "POG": pog],
            currentUserLogin: "me", timestamp: testStamp
        )
        // Expect: [emote(KEKW), emote(LULW), emote(POG)]
        try? #require(line.runs.count == 3)
        if case .emote(let e) = line.runs[0] { #expect(e.name == "KEKW") }
        if case .emote(let e) = line.runs[1] { #expect(e.name == "LULW") }
        if case .emote(let e) = line.runs[2] { #expect(e.name == "POG") }
    }

    @Test("Highlight keyword detection (case-insensitive substring)")
    func keywordHighlight() {
        let message = makeMessage(fragments: [textSpec("guys watch this Clip right now")])
        let line = Normalizer.normalize(
            message: message,
            emoteSnapshot: [:],
            currentUserLogin: "me", timestamp: testStamp,
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
            currentUserLogin: "me", timestamp: testStamp,
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
            currentUserLogin: "me", timestamp: testStamp
        )
        #expect(line.runs.isEmpty)
    }

    @Test("Adjacent text fragments tokenize as one stream — words at the seam don't split")
    func adjacentTextFragmentsBuffered() {
        // Two `.text` fragments back-to-back: the word boundary comes
        // from whitespace in the CONTENT, not from the fragment seam.
        let message = makeMessage(fragments: [
            textSpec("hello "),
            textSpec("world"),
        ])
        let line = Normalizer.normalize(
            message: message,
            emoteSnapshot: [:],
            currentUserLogin: "me", timestamp: testStamp
        )
        #expect(line.runs == [.text("hello"), .text("world")])

        // A word split MID-WORD across a fragment seam must reassemble.
        let split = makeMessage(fragments: [textSpec("hel"), textSpec("lo")])
        let splitLine = Normalizer.normalize(
            message: split,
            emoteSnapshot: [:],
            currentUserLogin: "me", timestamp: testStamp
        )
        #expect(splitLine.runs == [.text("hello")])
    }

    @Test("No whitespace-only or whitespace-padded runs are ever emitted")
    func noWhitespaceRuns() {
        let kappa = makeEmote("Kappa")
        let message = makeMessage(fragments: [textSpec("  hi   Kappa  bye ")])
        let line = Normalizer.normalize(
            message: message,
            emoteSnapshot: ["Kappa": kappa],
            currentUserLogin: "me", timestamp: testStamp
        )
        #expect(line.runs == [.text("hi"), .emote(kappa), .text("bye")])
    }

    @Test("Highlight phrase spanning multiple words still matches")
    func phraseHighlightAcrossWords() {
        let message = makeMessage(fragments: [textSpec("get free crypto now")])
        let line = Normalizer.normalize(
            message: message,
            emoteSnapshot: [:],
            currentUserLogin: "me", timestamp: testStamp,
            highlightKeywords: ["free crypto"]
        )
        #expect(line.isHighlighted == true)
    }

    @Test("Highlight phrase does NOT match across an emote boundary")
    func phraseBrokenByEmote() {
        let kekw = makeEmote("KEKW")
        let message = makeMessage(fragments: [textSpec("free KEKW crypto")])
        let line = Normalizer.normalize(
            message: message,
            emoteSnapshot: ["KEKW": kekw],
            currentUserLogin: "me", timestamp: testStamp,
            highlightKeywords: ["free crypto"]
        )
        // "free" and "crypto" are separated by an emote run — they were
        // never adjacent in the message, so the phrase must not match.
        #expect(line.isHighlighted == false)
    }

    @Test("Reply: leading @parent mention is stripped, body tokenizes as words")
    func replyMentionStripped() {
        let message = makeMessage(
            fragments: [
                mentionSpec("@xqc", login: "xqc"),
                textSpec(" hello there"),
            ],
            replyToLogin: "xqc"
        )
        let line = Normalizer.normalize(
            message: message,
            emoteSnapshot: [:],
            currentUserLogin: "me", timestamp: testStamp
        )
        #expect(line.runs == [.text("hello"), .text("there")])
        #expect(line.replyParent?.parentMessageId == "parent1")
    }

    @Test("wordRuns helper tokenizes a plain string (optimistic-send path)")
    func wordRunsHelper() {
        let kappa = makeEmote("Kappa")
        let runs = Normalizer.wordRuns(
            text: " hello  Kappa world ",
            emoteSnapshot: ["Kappa": kappa]
        )
        #expect(runs == [.text("hello"), .emote(kappa), .text("world")])
    }

    @Test("Chatter login is carried onto the ChatLine")
    func carriesLogin() {
        // makeMessage derives chatter_user_login as chatterUserName.lowercased()
        let message = makeMessage(chatterUserName: "Tester", fragments: [textSpec("hi")])
        let line = Normalizer.normalize(
            message: message,
            emoteSnapshot: [:],
            currentUserLogin: "someoneelse", timestamp: testStamp
        )
        #expect(line.authorUserLogin == "tester")
        #expect(line.authorDisplayName == "Tester")
    }

    // MARK: - Timestamps & stable identity

    @Test("The caller's timestamp lands on the line; re-normalizing is equal")
    func timestampIsCallerSupplied() {
        let message = makeMessage(fragments: [textSpec("hello")])
        let first = Normalizer.normalize(
            message: message, emoteSnapshot: [:], currentUserLogin: "me", timestamp: testStamp
        )
        let second = Normalizer.normalize(
            message: message, emoteSnapshot: [:], currentUserLogin: "me", timestamp: testStamp
        )
        #expect(first.timestamp == testStamp)
        // No hidden clock read: the same inputs produce the same line.
        #expect(first == second)
    }

    @Test("Raid lines use the caller-minted id and timestamp")
    func raidLineIdentityIsCallerMinted() throws {
        let json = """
        {
            "from_broadcaster_user_id": "77",
            "from_broadcaster_user_login": "raider",
            "from_broadcaster_user_name": "Raider",
            "to_broadcaster_user_id": "1",
            "to_broadcaster_user_login": "broadcaster",
            "to_broadcaster_user_name": "Broadcaster",
            "viewers": 42
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let raid = try decoder.decode(EventSubRaid.self, from: Data(json.utf8))

        let id = Normalizer.raidLineID(fromBroadcasterUserId: raid.fromBroadcasterUserId, receivedAt: testStamp)
        #expect(id == "raid-77-1700000000000")
        let a = Normalizer.line(from: raid, id: id, timestamp: testStamp)
        let b = Normalizer.line(from: raid, id: id, timestamp: testStamp)
        #expect(a.id == id)
        #expect(a.timestamp == testStamp)
        #expect(a == b)
    }

    // MARK: - Announcement notifications

    @Test("Announcement notification tokenizes Twitch + third-party emotes, mentions, badges, and color")
    func announcementTokenizesEmotesAndCarriesMetadata() throws {
        let json = """
        {
            "broadcaster_user_id": "1",
            "broadcaster_user_login": "hello_kiko",
            "broadcaster_user_name": "hello_kiko",
            "chatter_user_id": "1001",
            "chatter_user_login": "streamelements",
            "chatter_user_name": "StreamElements",
            "color": "#5B99FF",
            "badges": [
                { "set_id": "moderator", "id": "1", "info": "" }
            ],
            "system_message": "",
            "message_id": "ann-1",
            "message": {
                "text": "Check out @Landy keekoLove KEKW",
                "fragments": [
                    { "type": "text", "text": "Check out " },
                    {
                        "type": "mention",
                        "text": "@Landy",
                        "mention": {
                            "user_id": "42",
                            "user_login": "landy",
                            "user_name": "Landy"
                        }
                    },
                    { "type": "text", "text": " " },
                    {
                        "type": "emote",
                        "text": "keekoLove",
                        "emote": {
                            "id": "emotesv2_abc123",
                            "emote_set_id": "999",
                            "owner_id": "1",
                            "format": ["static"]
                        }
                    },
                    { "type": "text", "text": " KEKW" }
                ]
            },
            "notice_type": "announcement",
            "announcement": { "color": "PURPLE" }
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let notification = try decoder.decode(EventSubChatNotification.self, from: Data(json.utf8))

        let kekw = makeEmote("KEKW")
        let line = try #require(Normalizer.line(
            from: notification,
            emoteSnapshot: ["KEKW": kekw],
            currentUserLogin: "landy",
            timestamp: testStamp
        ))

        #expect(line.id == "ann-1")
        #expect(line.kind == .announcementBubble(.init(color: .purple)))
        #expect(line.authorUserId == "1001")
        #expect(line.authorUserLogin == "streamelements")
        #expect(line.authorDisplayName == "StreamElements")
        #expect(line.authorColor == "#5B99FF")
        #expect(line.originalBadges.count == 1)
        #expect(line.originalBadges.first?.setId == "moderator")
        #expect(line.isHighlighted == true)
        #expect(line.runs.count == 5)
        #expect(line.runs[0] == .text("Check"))
        #expect(line.runs[1] == .text("out"))
        #expect(line.runs[2] == .mention(login: "landy", isMe: true))
        if case .twitchEmote(let ref, let name) = line.runs[3] {
            #expect(ref.id == "emotesv2_abc123")
            #expect(name == "keekoLove")
        } else {
            Issue.record("Expected Twitch emote at index 3, got \(line.runs[3])")
        }
        #expect(line.runs[4] == .emote(kekw))
    }

    @Test("Announcement falls back to plain message.text with third-party emotes when fragments are empty")
    func announcementFallbackWithoutFragments() throws {
        let json = """
        {
            "broadcaster_user_id": "1",
            "broadcaster_user_login": "hello_kiko",
            "broadcaster_user_name": "hello_kiko",
            "chatter_user_id": "1001",
            "chatter_user_login": "modbot",
            "chatter_user_name": "ModBot",
            "badges": [],
            "system_message": "",
            "message_id": "ann-2",
            "message": {
                "text": "Welcome KEKW",
                "fragments": []
            },
            "notice_type": "announcement",
            "announcement": { "color": "BLUE" }
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let notification = try decoder.decode(EventSubChatNotification.self, from: Data(json.utf8))

        let kekw = makeEmote("KEKW")
        let line = try #require(Normalizer.line(
            from: notification,
            emoteSnapshot: ["KEKW": kekw],
            timestamp: testStamp
        ))

        #expect(line.kind == .announcementBubble(.init(color: .blue)))
        #expect(line.runs == [.text("Welcome"), .emote(kekw)])
    }

    @Test("Announcement accent colors map Twitch strings case-insensitively and default to primary")
    func announcementAccentColors() {
        #expect(ChatLine.AnnouncementBubble.AccentColor(twitchColor: "PRIMARY") == .primary)
        #expect(ChatLine.AnnouncementBubble.AccentColor(twitchColor: "BLUE") == .blue)
        #expect(ChatLine.AnnouncementBubble.AccentColor(twitchColor: "green") == .green)
        #expect(ChatLine.AnnouncementBubble.AccentColor(twitchColor: "ORANGE") == .orange)
        #expect(ChatLine.AnnouncementBubble.AccentColor(twitchColor: "PURPLE") == .purple)
        #expect(ChatLine.AnnouncementBubble.AccentColor(twitchColor: nil) == .primary)
        #expect(ChatLine.AnnouncementBubble.AccentColor(twitchColor: "UNKNOWN") == .primary)
    }

    // MARK: - Tokenizer paths

    @Test("ASCII whitespace of every kind separates words (byte fast path)")
    func asciiWhitespaceKinds() {
        let runs = Normalizer.wordRuns(text: "a\tb\nc\r\nd\u{0B}e\u{0C}f  g")
        #expect(runs == [.text("a"), .text("b"), .text("c"), .text("d"), .text("e"), .text("f"), .text("g")])
    }

    @Test("Non-ASCII text takes the Character path: NBSP splits, emoji survive")
    func nonASCIITokenization() {
        let runs = Normalizer.wordRuns(text: "héllo\u{00A0}wörld 👋🏽 ok")
        #expect(runs == [.text("héllo"), .text("wörld"), .text("👋🏽"), .text("ok")])
    }

    @Test("A combining mark on a space stays one whitespace grapheme")
    func combiningMarkOnSpace() {
        // " \u{301}" is ONE Character whose first scalar is whitespace, so the
        // whole cluster separates — the mark doesn't leak into the next word.
        let runs = Normalizer.wordRuns(text: "a \u{301}b")
        #expect(runs == [.text("a"), .text("b")])
    }

    @Test("ASCII fast path resolves third-party emotes per word")
    func asciiFastPathEmotes() {
        let kappa = makeEmote("Kappa")
        let runs = Normalizer.wordRuns(text: "Kappa\tKappa x", emoteSnapshot: ["Kappa": kappa])
        #expect(runs == [.emote(kappa), .emote(kappa), .text("x")])
    }
}

// MARK: - HighlightMatcher

@Suite("HighlightMatcher")
struct HighlightMatcherTests {

    private func words(_ text: String) -> [LineRun] {
        Normalizer.wordRuns(text: text)
    }

    @Test("An empty keyword list (or only empty keywords) never matches")
    func emptyMatcher() {
        #expect(HighlightMatcher(keywords: []).isEmpty)
        #expect(HighlightMatcher(keywords: [""]).isEmpty)
        #expect(!HighlightMatcher(keywords: []).matches(words("anything at all")))
    }

    @Test("Single-word keywords match case-insensitively inside a word")
    func singleWordSubstring() {
        let matcher = HighlightMatcher(keywords: ["CLIP"])
        #expect(matcher.matches(words("watch this clipped thing")))
        #expect(!matcher.matches(words("nothing here")))
    }

    @Test("Phrases match across adjacent words, not across non-text runs")
    func phraseSpans() {
        let matcher = HighlightMatcher(keywords: ["Free Crypto"])
        #expect(matcher.matches(words("get free crypto now")))
        let kekw = makeEmote("KEKW")
        #expect(!matcher.matches([.text("free"), .emote(kekw), .text("crypto")]))
    }

    @Test("Mentions and emote names are invisible to keywords")
    func nonTextRunsIgnored() {
        let matcher = HighlightMatcher(keywords: ["xqc"])
        #expect(!matcher.matches([.mention(login: "xqc", isMe: false), .text("hi")]))
    }

    @Test("Non-ASCII keywords fall back to Foundation case folding")
    func nonASCIIFallback() {
        let matcher = HighlightMatcher(keywords: ["ÉCOLE"])
        #expect(matcher.matches(words("à l'école demain")))
        // ASCII keyword against non-ASCII text uses the same fallback, so
        // Foundation's folding ("ß" ~ "ss") is preserved exactly.
        let sharpS = HighlightMatcher(keywords: ["strasse"])
        #expect(sharpS.matches(words("die Straße")) == ("die Straße".range(of: "strasse", options: .caseInsensitive) != nil))
    }
}
