import Testing
import Foundation
import ChatModel
@testable import Features

@Suite("Stream metadata formatting")
struct StreamFormattingTests {

    @Test("VOD durations parse to seconds", arguments: [
        ("3h2m1s", 3 * 3600 + 2 * 60 + 1),
        ("45m10s", 45 * 60 + 10),
        ("12s", 12),
        ("2h", 7200),
        ("", 0),
    ])
    func vodDuration(input: String, expected: Int) {
        #expect(ChannelStatusStore.seconds(inTwitchDuration: input) == TimeInterval(expected))
    }

    @Test("uptime is compact hours + minutes")
    func uptime() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(StreamFormatting.uptime(since: now, now: now) == "<1m")
        #expect(StreamFormatting.uptime(since: now.addingTimeInterval(-45 * 60), now: now) == "45m")
        #expect(StreamFormatting.uptime(since: now.addingTimeInterval(-2 * 3600), now: now) == "2h")
        #expect(StreamFormatting.uptime(since: now.addingTimeInterval(-(2 * 3600 + 50 * 60)), now: now) == "2h 50m")
    }

    @Test("last-live short form steps through units")
    func lastLiveShort() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        #expect(StreamFormatting.lastLiveShort(now.addingTimeInterval(-30), now: now) == "1m ago")
        #expect(StreamFormatting.lastLiveShort(now.addingTimeInterval(-7 * 3600), now: now) == "7h ago")
        #expect(StreamFormatting.lastLiveShort(now.addingTimeInterval(-2 * 86_400), now: now) == "2d ago")
        #expect(StreamFormatting.lastLiveShort(now.addingTimeInterval(-15 * 86_400), now: now) == "2w ago")
    }

    @Test("thumbnail template fills width and height")
    func thumbnail() {
        let url = StreamFormatting.thumbnailURL("https://x/live_user_a-{width}x{height}.jpg", width: 640, height: 360)
        #expect(url?.absoluteString == "https://x/live_user_a-640x360.jpg")
    }

    @Test("a preview's cache identity holds for its lifetime, then changes")
    func thumbnailCacheIdentity() throws {
        let url = try #require(URL(string: "https://x/live_user_a-640x360.jpg"))
        let windowStart = Date(timeIntervalSince1970: 1_000 * StreamFormatting.thumbnailLifetime)
        let first = StreamFormatting.thumbnailCacheIdentity(for: url, now: windowStart)
        let sameWindow = StreamFormatting.thumbnailCacheIdentity(
            for: url, now: windowStart.addingTimeInterval(StreamFormatting.thumbnailLifetime - 1)
        )
        let nextWindow = StreamFormatting.thumbnailCacheIdentity(
            for: url, now: windowStart.addingTimeInterval(StreamFormatting.thumbnailLifetime)
        )
        #expect(first == sameWindow)
        #expect(first != nextWindow)
        #expect(first.hasPrefix(url.absoluteString))
    }

    @Test("a malformed preview template yields no request")
    func thumbnailRequestRejectsBadTemplate() {
        #expect(StreamFormatting.thumbnailRequest("", width: 640, height: 360) == nil)
        #expect(StreamFormatting.thumbnailRequest("https://x/a-{width}x{height}.jpg", width: 640, height: 360) != nil)
    }
}

@Suite("Compact bot rendering")
@MainActor
struct CompactBotRenderingTests {

    @Test("banner decoration is stripped, letters kept")
    func stripsDecoration() {
        #expect(ChatRow.stripDecoration("❀────SHOUTOUT────❀") == "SHOUTOUT")
        #expect(ChatRow.stripDecoration("───") == "")
        #expect(ChatRow.stripDecoration("hello") == "hello")
    }

    @Test("decoration-only words drop out and links survive")
    func compactBody() {
        let runs: [LineRun] = [
            .text("❀────"), .text("Big"), .text("shoutout"), .text("──"),
            .text("www.twitch.tv/tandeeze"), .text(","),
        ]
        let body = ChatRow.compactBotAttributedBody(runs)
        #expect(String(body.characters) == "Big shoutout www.twitch.tv/tandeeze ,")
        let linked = body.runs.compactMap { $0.link }
        #expect(linked == [URL(string: "https://www.twitch.tv/tandeeze")!])
    }
}
