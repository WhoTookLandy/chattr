import Testing
import Foundation
@testable import Features

/// `HLSMasterPlaylist.audioOnlyVariant` — the one piece of Twitch's master
/// playlist the native player parses itself, to play audio-only without
/// pulling video.
@Suite("HLS master playlist: audio-only variant")
struct StreamPlaylistParserTests {
    static let master = URL(string: "https://usher.ttvnw.net/api/channel/hls/somechannel.m3u8?sig=abc&token=def")!

    static let lines = [
        "#EXTM3U",
        "#EXT-X-TWITCH-INFO:NODE=\"video-edge\",CLUSTER=\"xyz\"",
        "#EXT-X-MEDIA:TYPE=VIDEO,GROUP-ID=\"chunked\",NAME=\"1080p60 (source)\",AUTOSELECT=YES,DEFAULT=YES",
        "#EXT-X-STREAM-INF:BANDWIDTH=8534030,RESOLUTION=1920x1080,CODECS=\"avc1.64002A,mp4a.40.2\",VIDEO=\"chunked\",FRAME-RATE=60.000",
        "https://video-weaver.example.net/v1/playlist/chunked.m3u8",
        "#EXT-X-MEDIA:TYPE=VIDEO,GROUP-ID=\"160p30\",NAME=\"160p\",AUTOSELECT=YES,DEFAULT=YES",
        "#EXT-X-STREAM-INF:BANDWIDTH=230000,RESOLUTION=284x160,CODECS=\"avc1.4D400C,mp4a.40.2\",VIDEO=\"160p30\",FRAME-RATE=30.000",
        "https://video-weaver.example.net/v1/playlist/160p30.m3u8",
        "#EXT-X-MEDIA:TYPE=VIDEO,GROUP-ID=\"audio_only\",NAME=\"audio_only\",AUTOSELECT=NO,DEFAULT=NO",
        "#EXT-X-STREAM-INF:BANDWIDTH=160000,CODECS=\"mp4a.40.2\",VIDEO=\"audio_only\"",
        "https://video-weaver.example.net/v1/playlist/audio_only.m3u8",
    ]

    @Test("Picks the URI after the audio_only stream line, not the media line that names it")
    func findsAudioOnlyVariant() {
        let text = Self.lines.joined(separator: "\n")
        let variant = HLSMasterPlaylist.audioOnlyVariant(in: text, relativeTo: Self.master)
        #expect(variant?.absoluteString == "https://video-weaver.example.net/v1/playlist/audio_only.m3u8")
    }

    @Test("CRLF line endings parse the same")
    func handlesCarriageReturns() {
        let text = Self.lines.joined(separator: "\r\n") + "\r\n"
        let variant = HLSMasterPlaylist.audioOnlyVariant(in: text, relativeTo: Self.master)
        #expect(variant?.absoluteString == "https://video-weaver.example.net/v1/playlist/audio_only.m3u8")
    }

    @Test("A relative URI resolves against the master playlist")
    func resolvesRelativeURI() {
        let text = [
            "#EXTM3U",
            "#EXT-X-STREAM-INF:BANDWIDTH=160000,CODECS=\"mp4a.40.2\",VIDEO=\"audio_only\"",
            "audio_only.m3u8",
        ].joined(separator: "\n")
        let variant = HLSMasterPlaylist.audioOnlyVariant(in: text, relativeTo: Self.master)
        #expect(variant?.absoluteString == "https://usher.ttvnw.net/api/channel/hls/audio_only.m3u8")
    }

    @Test("No audio_only variant: nil, so the full stream plays")
    func noAudioOnlyVariant() {
        let text = Self.lines.prefix(8).joined(separator: "\n")
        #expect(HLSMasterPlaylist.audioOnlyVariant(in: text, relativeTo: Self.master) == nil)
    }

    @Test("A stream line with no URI after it: nil")
    func truncatedPlaylist() {
        let text = Self.lines.dropLast().joined(separator: "\n")
        #expect(HLSMasterPlaylist.audioOnlyVariant(in: text, relativeTo: Self.master) == nil)
    }

    @Test("Not a playlist at all (an error body): nil")
    func notAPlaylist() {
        let text = "[{\"error\":\"Not Found\",\"error_code\":\"not_found\"}]"
        #expect(HLSMasterPlaylist.audioOnlyVariant(in: text, relativeTo: Self.master) == nil)
    }
}

@Suite("Stream playlist cache")
struct StreamPlaylistCacheTests {
    static let master = URL(string: "https://usher.ttvnw.net/api/channel/hls/somechannel.m3u8?sig=abc&token=def")!
    static let audioOnly = URL(string: "https://video-weaver.example.net/v1/playlist/audio_only.m3u8")!

    @Test("Returns cached entry for matching channel and auth within TTL")
    func hitsWithinTTL() async {
        let cache = StreamPlaylistCache(ttl: .seconds(600))
        let t0 = ContinuousClock.now
        await cache.store(
            login: "SomeChannel",
            masterURL: Self.master,
            audioOnlyURL: nil,
            didProbeAudioOnly: false,
            authFingerprint: "client:tok",
            now: t0
        )

        let entry = await cache.entry(
            for: "somechannel",
            authFingerprint: "client:tok",
            now: t0.advanced(by: .seconds(300))
        )
        #expect(entry?.masterURL == Self.master)
        #expect(entry?.audioOnlyURL == nil)
        #expect(entry?.didProbeAudioOnly == false)
    }

    @Test("Records background audio_only probe on matching master URL")
    func recordsAudioOnlyProbe() async {
        let cache = StreamPlaylistCache(ttl: .seconds(600))
        let t0 = ContinuousClock.now
        await cache.store(
            login: "somechannel",
            masterURL: Self.master,
            audioOnlyURL: nil,
            didProbeAudioOnly: false,
            authFingerprint: "anon",
            now: t0
        )
        await cache.recordAudioOnlyProbe(
            login: "somechannel",
            masterURL: Self.master,
            audioOnlyURL: Self.audioOnly
        )

        let entry = await cache.entry(for: "somechannel", authFingerprint: "anon", now: t0)
        #expect(entry?.audioOnlyURL == Self.audioOnly)
        #expect(entry?.didProbeAudioOnly == true)
    }

    @Test("Expires entries past TTL and evicts on auth change or invalidation")
    func expiresAndEvicts() async {
        let cache = StreamPlaylistCache(ttl: .seconds(60))
        let t0 = ContinuousClock.now
        await cache.store(
            login: "somechannel",
            masterURL: Self.master,
            audioOnlyURL: Self.audioOnly,
            didProbeAudioOnly: true,
            authFingerprint: "client:a",
            now: t0
        )

        // Auth changed → evicted.
        #expect(await cache.entry(for: "somechannel", authFingerprint: "client:b", now: t0) == nil)

        // Past TTL → evicted.
        await cache.store(
            login: "somechannel",
            masterURL: Self.master,
            audioOnlyURL: Self.audioOnly,
            didProbeAudioOnly: true,
            authFingerprint: "client:b",
            now: t0
        )
        #expect(await cache.entry(for: "somechannel", authFingerprint: "client:b", now: t0.advanced(by: .seconds(61))) == nil)

        // Explicit invalidation.
        await cache.store(
            login: "somechannel",
            masterURL: Self.master,
            audioOnlyURL: Self.audioOnly,
            didProbeAudioOnly: true,
            authFingerprint: "client:b",
            now: t0
        )
        await cache.invalidate(login: "SOMECHANNEL")
        #expect(await cache.entry(for: "somechannel", authFingerprint: "client:b", now: t0) == nil)
    }
}
