import Testing
import Foundation
@testable import EmoteSources

// Decoding-only tests for the three providers. Each test pipes a captured
// JSON fixture through the provider's internal decoding shapes via a
// `URLProtocol`-mocked URLSession so we exercise the real
// `globalEmotes()` / `channelEmotes(...)` codepaths without hitting the
// network.
//
// The fixtures are deliberately minimal — just enough JSON to verify the
// decoding contract, not an exhaustive snapshot of upstream responses. If
// a provider changes its schema, these tests should fail loudly so we
// catch the drift in CI rather than at runtime.

// MARK: - URLProtocol mock
//
// Swift Testing runs tests in parallel by default. A naive "single static
// handler" mock races: two tests assign their own handler concurrently,
// and whichever one wins the race serves both requests. We saw this:
// 7TV decoder fed BTTV's array-JSON because a BTTV test stomped the
// handler mid-flight.
//
// Fix: key responses by absolute URL. Each test pre-registers its
// expected URL → (data, status), and `MockURLProtocol.startLoading`
// looks up the URL it sees. URLs are distinct across tests (different
// providers, different endpoints), so registrations never collide.

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    // Registration table. Lock-protected for cross-thread safety —
    // tests register from a Task, the URLProtocol callback may fire on
    // a Foundation-owned thread.
    nonisolated(unsafe) static var responses: [URL: (Data, Int)] = [:]
    static let lock = NSLock()

    static func register(_ url: URL, data: Data, statusCode: Int) {
        lock.lock(); defer { lock.unlock() }
        responses[url] = (data, statusCode)
    }

    static func lookup(_ url: URL) -> (Data, Int)? {
        lock.lock(); defer { lock.unlock() }
        return responses[url]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let (data, statusCode) = Self.lookup(url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Build a URLSession that routes through MockURLProtocol.
/// The caller must `MockURLProtocol.register(...)` the expected URL
/// before invoking the provider.
private func mockedSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
}

/// Convenience: register a URL response and return the mocked session in
/// one call. Each provider's well-known endpoint URL is what the test
/// passes as the first argument.
private func mockedSession(
    url: String,
    statusCode: Int = 200,
    data: Data
) -> URLSession {
    MockURLProtocol.register(URL(string: url)!, data: data, statusCode: statusCode)
    return mockedSession()
}

// MARK: - 7TV

@Suite("7TV decoding", .serialized)
struct SevenTVDecodingTests {

    @Test("Parses a non-zero-width emote with WebP variants")
    func parsesPlainEmote() async throws {
        let json = """
        {
          "emotes": [
            {
              "id": "01F6N4N3R0000G2CW7XHM",
              "name": "PepePoint",
              "flags": 0,
              "data": {
                "animated": false,
                "host": {
                  "url": "//cdn.7tv.app/emote/01F6N4N3R0000G2CW7XHM",
                  "files": [
                    {"name": "1x.webp", "format": "WEBP"},
                    {"name": "2x.webp", "format": "WEBP"},
                    {"name": "4x.webp", "format": "WEBP"},
                    {"name": "1x.avif", "format": "AVIF"}
                  ]
                }
              }
            }
          ]
        }
        """.data(using: .utf8)!
        let provider = SevenTVProvider(urlSession: mockedSession(
            url: "https://7tv.io/v3/emote-sets/global",
            data: json
        ))
        let emotes = try await provider.globalEmotes()
        try #require(emotes.count == 1)
        let e = emotes[0]
        #expect(e.name == "PepePoint")
        #expect(e.source == .sevenTV)
        #expect(e.isAnimated == false)
        #expect(e.isZeroWidth == false)
        // Protocol-relative URL should be normalized to https://.
        #expect(e.urls[.x2]?.absoluteString == "https://cdn.7tv.app/emote/01F6N4N3R0000G2CW7XHM/2x.webp")
        // AVIF variants are filtered out — we only keep WebP.
        #expect(e.urls.count == 3)
    }

    @Test("Parses a zero-width animated emote with flags=1")
    func parsesZeroWidthAnimated() async throws {
        let json = """
        {
          "emotes": [
            {
              "id": "Z0001",
              "name": "RainTime",
              "flags": 1,
              "data": {
                "animated": true,
                "host": {
                  "url": "https://cdn.7tv.app/emote/Z0001",
                  "files": [{"name": "2x.webp", "format": "WEBP"}]
                }
              }
            }
          ]
        }
        """.data(using: .utf8)!
        let provider = SevenTVProvider(urlSession: mockedSession(
            url: "https://7tv.io/v3/emote-sets/global",
            data: json
        ))
        let emotes = try await provider.globalEmotes()
        try #require(emotes.count == 1)
        #expect(emotes[0].isZeroWidth == true)
        #expect(emotes[0].isAnimated == true)
    }

    @Test("Carries the file dimensions through as an aspect ratio")
    func parsesAspectRatio() async throws {
        // A "wide" emote: 96×32 at 1x → aspect 3.0. The 7TV API reports
        // width/height per file; ratio is identical across size variants.
        let json = """
        {
          "emotes": [
            {
              "id": "W0001",
              "name": "WideBoi",
              "data": {
                "animated": false,
                "host": {
                  "url": "https://cdn.7tv.app/emote/W0001",
                  "files": [
                    {"name": "1x.webp", "format": "WEBP", "width": 96, "height": 32},
                    {"name": "2x.webp", "format": "WEBP", "width": 192, "height": 64}
                  ]
                }
              }
            }
          ]
        }
        """.data(using: .utf8)!
        let provider = SevenTVProvider(urlSession: mockedSession(
            url: "https://7tv.io/v3/emote-sets/global",
            data: json
        ))
        let emotes = try await provider.globalEmotes()
        try #require(emotes.count == 1)
        #expect(emotes[0].aspectRatio == 3.0)
    }

    @Test("Missing file dimensions yield nil aspect ratio")
    func missingDimensionsYieldNilAspect() async throws {
        let json = """
        {
          "emotes": [
            {
              "id": "N0001",
              "name": "NoDims",
              "data": {
                "host": {
                  "url": "https://cdn.7tv.app/emote/N0001",
                  "files": [{"name": "1x.webp", "format": "WEBP"}]
                }
              }
            }
          ]
        }
        """.data(using: .utf8)!
        let provider = SevenTVProvider(urlSession: mockedSession(
            url: "https://7tv.io/v3/emote-sets/global",
            data: json
        ))
        let emotes = try await provider.globalEmotes()
        try #require(emotes.count == 1)
        #expect(emotes[0].aspectRatio == nil)
    }

    @Test("Drops emotes with no usable variants")
    func dropsEmoteWithNoUsableVariants() async throws {
        let json = """
        {
          "emotes": [
            {
              "id": "X0001",
              "name": "OnlyAVIF",
              "data": {
                "host": {
                  "url": "https://cdn.7tv.app/emote/X0001",
                  "files": [{"name": "1x.avif", "format": "AVIF"}]
                }
              }
            }
          ]
        }
        """.data(using: .utf8)!
        let provider = SevenTVProvider(urlSession: mockedSession(
            url: "https://7tv.io/v3/emote-sets/global",
            data: json
        ))
        let emotes = try await provider.globalEmotes()
        #expect(emotes.isEmpty)
    }
}

// MARK: - BTTV

@Suite("BTTV decoding", .serialized)
struct BTTVDecodingTests {

    @Test("Parses global PNG emote")
    func parsesGlobalPng() async throws {
        let json = """
        [
          {"id": "54fa90b80", "code": "POGGERS", "imageType": "png"}
        ]
        """.data(using: .utf8)!
        let provider = BTTVProvider(urlSession: mockedSession(
            url: "https://api.betterttv.net/3/cached/emotes/global",
            data: json
        ))
        let emotes = try await provider.globalEmotes()
        try #require(emotes.count == 1)
        let e = emotes[0]
        #expect(e.name == "POGGERS")
        #expect(e.isAnimated == false)
        #expect(e.source == .bttv)
        #expect(e.urls[.x4]?.absoluteString == "https://cdn.betterttv.net/emote/54fa90b80/3x")
    }

    @Test("Parses GIF as animated")
    func parsesGifAsAnimated() async throws {
        let json = """
        [
          {"id": "g0001", "code": "WiggleParrot", "imageType": "gif"}
        ]
        """.data(using: .utf8)!
        let provider = BTTVProvider(urlSession: mockedSession(
            url: "https://api.betterttv.net/3/cached/emotes/global",
            data: json
        ))
        let emotes = try await provider.globalEmotes()
        try #require(emotes.count == 1)
        #expect(emotes[0].isAnimated == true)
    }

    @Test("404 on channel endpoint returns empty (not throws)")
    func returnsEmptyOn404() async throws {
        let provider = BTTVProvider(urlSession: mockedSession(
            url: "https://api.betterttv.net/3/cached/users/twitch/123",
            statusCode: 404,
            data: Data()
        ))
        let emotes = try await provider.channelEmotes(broadcasterId: "123", broadcasterLogin: "x")
        #expect(emotes.isEmpty)
    }

    @Test("Channel endpoint merges channelEmotes + sharedEmotes")
    func mergesChannelAndShared() async throws {
        let json = """
        {
          "channelEmotes": [{"id": "c1", "code": "myCh", "imageType": "png"}],
          "sharedEmotes":  [{"id": "s1", "code": "sharedCh", "imageType": "png"}]
        }
        """.data(using: .utf8)!
        let provider = BTTVProvider(urlSession: mockedSession(
            url: "https://api.betterttv.net/3/cached/users/twitch/123",
            data: json
        ))
        let emotes = try await provider.channelEmotes(broadcasterId: "123", broadcasterLogin: "x")
        #expect(emotes.count == 2)
        #expect(emotes.contains { $0.name == "myCh" })
        #expect(emotes.contains { $0.name == "sharedCh" })
    }
}

// MARK: - FFZ

@Suite("FFZ decoding", .serialized)
struct FFZDecodingTests {

    @Test("Uses urls when animated is absent")
    func usesStaticUrls() async throws {
        let json = """
        {
          "sets": {
            "3": {
              "emoticons": [
                {
                  "id": 100,
                  "name": "ZreknarF",
                  "urls": {"1": "//cdn.frankerfacez.com/emote/100/1", "2": "//cdn.frankerfacez.com/emote/100/2", "4": "//cdn.frankerfacez.com/emote/100/4"}
                }
              ]
            }
          }
        }
        """.data(using: .utf8)!
        let provider = FFZProvider(urlSession: mockedSession(
            url: "https://api.frankerfacez.com/v1/set/global",
            data: json
        ))
        let emotes = try await provider.globalEmotes()
        try #require(emotes.count == 1)
        let e = emotes[0]
        #expect(e.name == "ZreknarF")
        #expect(e.isAnimated == false)
        #expect(e.source == .ffz)
        #expect(e.urls[.x2]?.absoluteString == "https://cdn.frankerfacez.com/emote/100/2")
    }

    @Test("Prefers animated URLs when both present")
    func prefersAnimated() async throws {
        let json = """
        {
          "sets": {
            "3": {
              "emoticons": [
                {
                  "id": 200,
                  "name": "DanceMan",
                  "urls":     {"1": "//cdn.frankerfacez.com/emote/200/static/1"},
                  "animated": {"1": "//cdn.frankerfacez.com/emote/200/animated/1"}
                }
              ]
            }
          }
        }
        """.data(using: .utf8)!
        let provider = FFZProvider(urlSession: mockedSession(
            url: "https://api.frankerfacez.com/v1/set/global",
            data: json
        ))
        let emotes = try await provider.globalEmotes()
        try #require(emotes.count == 1)
        let e = emotes[0]
        #expect(e.isAnimated == true)
        #expect(e.urls[.x1]?.absoluteString.contains("/animated/") == true)
    }

    @Test("404 on channel endpoint returns empty")
    func returnsEmptyOn404() async throws {
        let provider = FFZProvider(urlSession: mockedSession(
            url: "https://api.frankerfacez.com/v1/room/noone",
            statusCode: 404,
            data: Data()
        ))
        let emotes = try await provider.channelEmotes(broadcasterId: "1", broadcasterLogin: "noone")
        #expect(emotes.isEmpty)
    }

    @Test("Carries emoticon dimensions through as an aspect ratio")
    func parsesAspectRatio() async throws {
        // FFZ reports width/height at the emoticon level (1x dimensions).
        let json = """
        {
          "sets": {
            "3": {
              "emoticons": [
                {
                  "id": 300,
                  "name": "WideZulul",
                  "width": 56,
                  "height": 28,
                  "urls": {"1": "//cdn.frankerfacez.com/emote/300/1"}
                }
              ]
            }
          }
        }
        """.data(using: .utf8)!
        let provider = FFZProvider(urlSession: mockedSession(
            url: "https://api.frankerfacez.com/v1/set/global",
            data: json
        ))
        let emotes = try await provider.globalEmotes()
        try #require(emotes.count == 1)
        #expect(emotes[0].aspectRatio == 2.0)
    }
}

// MARK: - HTTP status handling

@Suite("Provider HTTP status handling")
struct ProviderHTTPStatusTests {

    @Test("5xx on a channel endpoint is a provider error, not a decode error")
    func serverErrorThrowsHTTPStatus() async throws {
        let provider = BTTVProvider(urlSession: mockedSession(
            url: "https://api.betterttv.net/3/cached/users/twitch/50300",
            statusCode: 503,
            data: Data("<html>Service Unavailable</html>".utf8)
        ))
        await #expect(throws: EmoteProviderError.httpStatus(503)) {
            _ = try await provider.channelEmotes(broadcasterId: "50300", broadcasterLogin: "x")
        }
    }

    @Test("429 on a channel endpoint is a provider error")
    func rateLimitThrowsHTTPStatus() async throws {
        let provider = FFZProvider(urlSession: mockedSession(
            url: "https://api.frankerfacez.com/v1/room/ratelimited",
            statusCode: 429,
            data: Data()
        ))
        await #expect(throws: EmoteProviderError.httpStatus(429)) {
            _ = try await provider.channelEmotes(broadcasterId: "1", broadcasterLogin: "ratelimited")
        }
    }

    @Test("404 on a 7TV channel stays an empty result")
    func sevenTVNotFoundIsEmpty() async throws {
        let provider = SevenTVProvider(urlSession: mockedSession(
            url: "https://7tv.io/v3/users/twitch/40400",
            statusCode: 404,
            data: Data()
        ))
        let emotes = try await provider.channelEmotes(broadcasterId: "40400", broadcasterLogin: "x")
        #expect(emotes.isEmpty)
    }

    @Test("5xx on a 7TV channel throws")
    func sevenTVServerErrorThrows() async throws {
        let provider = SevenTVProvider(urlSession: mockedSession(
            url: "https://7tv.io/v3/users/twitch/50200",
            statusCode: 502,
            data: Data()
        ))
        await #expect(throws: EmoteProviderError.httpStatus(502)) {
            _ = try await provider.channelEmotes(broadcasterId: "50200", broadcasterLogin: "x")
        }
    }
}
