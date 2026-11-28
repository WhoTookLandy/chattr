import Foundation
import Testing
@testable import Features

@Suite("Twitch LL-HLS proxy, CMAF framer, and playlist translator")
struct LLHLSProxyTests {

    // MARK: - Binary MP4 test builders

    private func u32(_ value: UInt32) -> Data {
        var big = value.bigEndian
        return Data(bytes: &big, count: 4)
    }

    private func box(_ fourCC: String, payload: Data) -> Data {
        var out = Data()
        out.append(u32(UInt32(8 + payload.count)))
        out.append(contentsOf: fourCC.utf8)
        out.append(payload)
        return out
    }

    private func tkhd(trackID: UInt32) -> Data {
        // version 0: 4 (ver+flags) + 4 (create) + 4 (mod) + 4 (trackID) + 4 (reserved) = 20 bytes
        var payload = Data(count: 12)
        payload.append(u32(trackID))
        payload.append(Data(count: 4))
        return box("tkhd", payload: payload)
    }

    private func mdhd(timescale: UInt32) -> Data {
        // version 0: 4 (ver+flags) + 4 (create) + 4 (mod) + 4 (timescale) + 4 (duration) = 20 bytes
        var payload = Data(count: 12)
        payload.append(u32(timescale))
        payload.append(Data(count: 4))
        return box("mdhd", payload: payload)
    }

    private func hdlr(handlerType: String) -> Data {
        // 4 (ver+flags) + 4 (pre_defined) + 4 (handler_type) + 12 (reserved)
        var payload = Data(count: 8)
        payload.append(contentsOf: handlerType.utf8)
        payload.append(Data(count: 12))
        return box("hdlr", payload: payload)
    }

    private func initSegment(tracks: [(id: UInt32, handler: String, timescale: UInt32)]) -> Data {
        var moovPayload = Data()
        for track in tracks {
            let mdia = box("mdia", payload: mdhd(timescale: track.timescale) + hdlr(handlerType: track.handler))
            let trak = box("trak", payload: tkhd(trackID: track.id) + mdia)
            moovPayload.append(trak)
        }
        return box("ftyp", payload: Data("isom\0\0\0\0".utf8)) + box("moov", payload: moovPayload)
    }

    private func moofChunk(
        trackID: UInt32,
        sampleDurations: [UInt32],
        firstSampleFlags: UInt32?,
        mdatPayloadSize: Int = 32
    ) -> Data {
        // tfhd with default-base-is-moof (0x020000)
        let tfhdPayload = u32(0x0002_0000) + u32(trackID)
        let tfhd = box("tfhd", payload: tfhdPayload)

        // trun with sample_duration_present (0x100) + optional sample_flags_present (0x400)
        var trunFlags: UInt32 = 0x0000_0100
        if firstSampleFlags != nil { trunFlags |= 0x0000_0400 }
        var trunPayload = u32(trunFlags) + u32(UInt32(sampleDurations.count))
        for (idx, dur) in sampleDurations.enumerated() {
            trunPayload.append(u32(dur))
            if let firstSampleFlags {
                trunPayload.append(u32(idx == 0 ? firstSampleFlags : 0x0101_0000))
            }
        }
        let trun = box("trun", payload: trunPayload)
        let traf = box("traf", payload: tfhd + trun)
        let moof = box("moof", payload: traf)
        let mdat = box("mdat", payload: Data(repeating: 0xAA, count: mdatPayloadSize))
        return moof + mdat
    }

    // MARK: - CMAFInitInfo & CMAFChunkFramer tests

    @Test("Parses video + audio track timescales and identifies video as primary")
    func parsesVideoInitSegment() {
        let data = initSegment(tracks: [
            (id: 1, handler: "soun", timescale: 48_000),
            (id: 2, handler: "vide", timescale: 1_000_000),
        ])
        let info = CMAFInitInfo.parse(initSegment: data)
        #expect(info != nil)
        #expect(info?.videoTrackID == 2)
        #expect(info?.primaryTrackID == 2)
        #expect(info?.isAudioOnly == false)
        #expect(info?.trackTimescales == [1: 48_000, 2: 1_000_000])
    }

    @Test("Parses audio-only init segment with audio track as primary")
    func parsesAudioOnlyInitSegment() {
        let data = initSegment(tracks: [
            (id: 1, handler: "soun", timescale: 48_000),
        ])
        let info = CMAFInitInfo.parse(initSegment: data)
        #expect(info != nil)
        #expect(info?.videoTrackID == nil)
        #expect(info?.primaryTrackID == 1)
        #expect(info?.isAudioOnly == true)
        #expect(info?.primaryTimescale == 48_000)
    }

    @Test("Frames incremental CMAF bytes into exact chunks with duration and IDR flags")
    func framesChunkedVideoStream() throws {
        let info = CMAFInitInfo(
            trackTimescales: [1: 48_000, 2: 1_000_000],
            videoTrackID: 2,
            primaryTrackID: 2
        )
        let emsg = box("emsg", payload: Data(repeating: 0x11, count: 16))
        // 6 frames @ 16667µs ≈ 0.100002s, IDR sync flag (bit 16 == 0)
        let chunk1Raw = moofChunk(
            trackID: 2,
            sampleDurations: Array(repeating: 16_667, count: 6),
            firstSampleFlags: 0x0200_0000
        )
        // 6 frames @ 16667µs, non-sync P-frame (bit 16 == 1 -> 0x0101_0000)
        let chunk2Raw = moofChunk(
            trackID: 2,
            sampleDurations: Array(repeating: 16_667, count: 6),
            firstSampleFlags: 0x0101_0000
        )

        let fullStream = emsg + chunk1Raw + chunk2Raw
        var framer = CMAFChunkFramer(initInfo: info)
        var emitted: [CMAFChunk] = []

        // Feed in tiny 7-byte slices to verify incremental reassembly across boundaries.
        var cursor = fullStream.startIndex
        while cursor < fullStream.endIndex {
            let next = min(cursor + 7, fullStream.endIndex)
            emitted.append(contentsOf: framer.append(Data(fullStream[cursor..<next])))
            cursor = next
        }

        try #require(emitted.count == 2)
        #expect(emitted[0].data == emsg + chunk1Raw)
        #expect(abs(emitted[0].duration - 0.100002) < 0.0001)
        #expect(emitted[0].isIndependent == true)

        #expect(emitted[1].data == chunk2Raw)
        #expect(abs(emitted[1].duration - 0.100002) < 0.0001)
        #expect(emitted[1].isIndependent == false)
    }

    @Test("Audio-only CMAF chunks are all marked independently decodable")
    func framesAudioOnlyChunksAsIndependent() throws {
        let info = CMAFInitInfo(trackTimescales: [1: 48_000], videoTrackID: nil, primaryTrackID: 1)
        // 5 AAC frames × 1024 samples / 48000 Hz = 0.106667s
        let c1 = moofChunk(trackID: 1, sampleDurations: Array(repeating: 1024, count: 5), firstSampleFlags: nil)
        let c2 = moofChunk(trackID: 1, sampleDurations: Array(repeating: 1024, count: 5), firstSampleFlags: nil)
        var framer = CMAFChunkFramer(initInfo: info)
        let chunks = framer.append(c1 + c2)
        try #require(chunks.count == 2)
        #expect(chunks.allSatisfy { $0.isIndependent })
        #expect(abs(chunks[0].duration - (5120.0 / 48_000.0)) < 0.0001)
    }

    // MARK: - Master & Media playlist rewriting tests

    @Test("Rewrites master playlist variant URIs while preserving tags")
    func rewritesMasterPlaylist() {
        let masterURL = URL(string: "https://usher.ttvnw.net/api/channel/hls/test.m3u8?sig=1")!
        let master = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=VIDEO,GROUP-ID="1080p60",NAME="1080p60",AUTOSELECT=YES,DEFAULT=YES
        #EXT-X-STREAM-INF:BANDWIDTH=8000000,RESOLUTION=1920x1080,CODECS="avc1.4D401F,mp4a.40.2",VIDEO="1080p60"
        https://video-weaver.example.net/v1/playlist/1080.m3u8
        #EXT-X-MEDIA:TYPE=VIDEO,GROUP-ID="audio_only",NAME="audio_only",AUTOSELECT=NO,DEFAULT=NO
        #EXT-X-STREAM-INF:BANDWIDTH=160000,CODECS="mp4a.40.2",VIDEO="audio_only"
        https://video-weaver.example.net/v1/playlist/audio.m3u8
        """

        var count = 0
        let rewritten = TwitchMasterPlaylistRewriter.rewrite(text: master, relativeTo: masterURL) { _ in
            count += 1
            return URL(string: "http://127.0.0.1:9999/tok/media/v\(count).m3u8")!
        }

        #expect(count == 2)
        #expect(rewritten.contains("http://127.0.0.1:9999/tok/media/v1.m3u8"))
        #expect(rewritten.contains("http://127.0.0.1:9999/tok/media/v2.m3u8"))
        #expect(rewritten.contains("RESOLUTION=1920x1080"))
        #expect(rewritten.contains("VIDEO=\"audio_only\""))
    }

    @Test("Translates Twitch fMP4 playlist + prefetch parts into Apple LL-HLS")
    func translatesTwitchPlaylistToLLHLS() {
        let mediaURL = URL(string: "https://video-weaver.example.net/v1/playlist/1080.m3u8")!
        let raw = """
        #EXTM3U
        #EXT-X-VERSION:6
        #EXT-X-TARGETDURATION:6
        #EXT-X-MEDIA-SEQUENCE:8069
        #EXT-X-MAP:URI="https://cdn.example.net/init.mp4"
        #EXT-X-PROGRAM-DATE-TIME:2026-11-28T04:48:54.693Z
        #EXTINF:2.000,live
        https://cdn.example.net/seg-8069.mp4
        #EXT-X-PROGRAM-DATE-TIME:2026-11-28T04:48:56.693Z
        #EXTINF:2.000,live
        https://cdn.example.net/seg-8070.mp4
        #EXT-X-TWITCH-PREFETCH:https://cdn.example.net/seg-8071.mp4
        #EXT-X-TWITCH-PREFETCH:https://cdn.example.net/seg-8072.mp4
        """

        let parsed = TwitchMediaPlaylist.parse(raw, relativeTo: mediaURL)
        #expect(parsed.mediaSequence == 8069)
        #expect(parsed.declaredTargetDuration == 6)
        #expect(parsed.segments.count == 2)
        #expect(parsed.lastFinalizedMSN == 8070)
        #expect(parsed.prefetchURIs.count == 2)
        #expect(parsed.supportsLLHLS == true)

        let parts: [Int: LLHLSSegmentParts] = [
            8071: LLHLSSegmentParts(
                msn: 8071,
                parts: [
                    LLHLSPartDescriptor(partIndex: 0, duration: 0.500, isIndependent: true, uri: "http://127.0.0.1:9999/t/part/v1/8071/0.mp4"),
                    LLHLSPartDescriptor(partIndex: 1, duration: 0.500, isIndependent: false, uri: "http://127.0.0.1:9999/t/part/v1/8071/1.mp4"),
                    LLHLSPartDescriptor(partIndex: 2, duration: 0.500, isIndependent: false, uri: "http://127.0.0.1:9999/t/part/v1/8071/2.mp4"),
                    LLHLSPartDescriptor(partIndex: 3, duration: 0.500, isIndependent: false, uri: "http://127.0.0.1:9999/t/part/v1/8071/3.mp4"),
                ],
                isComplete: true,
                segmentURI: "http://127.0.0.1:9999/t/seg/v1/8071.mp4"
            ),
            8072: LLHLSSegmentParts(
                msn: 8072,
                parts: [
                    LLHLSPartDescriptor(partIndex: 0, duration: 0.500, isIndependent: true, uri: "http://127.0.0.1:9999/t/part/v1/8072/0.mp4"),
                    LLHLSPartDescriptor(partIndex: 1, duration: 0.500, isIndependent: false, uri: "http://127.0.0.1:9999/t/part/v1/8072/1.mp4"),
                ],
                isComplete: false,
                segmentURI: "http://127.0.0.1:9999/t/seg/v1/8072.mp4"
            ),
        ]

        let pinned = [8071: "http://127.0.0.1:9999/t/seg/v1/8071.mp4"]
        let rendered = parsed.renderLLHLS(
            segmentPartsByMSN: parts,
            pinnedSegmentURIs: pinned,
            preloadHintURI: "http://127.0.0.1:9999/t/part/v1/8072/2.mp4"
        )

        #expect(rendered.contains("#EXT-X-VERSION:7"))
        // TARGETDURATION stays stable across reloads (covers 5.5–6s stitched ads).
        #expect(rendered.contains("#EXT-X-TARGETDURATION:6"))
        #expect(rendered.contains("#EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=1.680,HOLD-BACK=18.000"))
        #expect(rendered.contains("#EXT-X-PART-INF:PART-TARGET=0.560"))
        // Promoted segment 8071 gets extrapolated program date-time (+2.000s from 04:48:56.693Z)
        #expect(rendered.contains("#EXT-X-PROGRAM-DATE-TIME:2026-11-28T04:48:58.693Z"))
        #expect(rendered.contains("http://127.0.0.1:9999/t/seg/v1/8071.mp4"))
        #expect(rendered.contains("#EXT-X-PART:DURATION=0.500,URI=\"http://127.0.0.1:9999/t/part/v1/8072/0.mp4\",INDEPENDENT=YES"))
        #expect(rendered.contains("#EXT-X-PART:DURATION=0.500,URI=\"http://127.0.0.1:9999/t/part/v1/8072/1.mp4\""))
        #expect(rendered.contains("#EXT-X-PRELOAD-HINT:TYPE=PART,URI=\"http://127.0.0.1:9999/t/part/v1/8072/2.mp4\""))
        #expect(!rendered.contains("EXT-X-TWITCH-PREFETCH"))

        // Once Twitch publishes MSN 8071 in upstream #EXTINF, the pinned /seg/ URI stays stable.
        let finalizedUpstream = """
        #EXTM3U
        #EXT-X-VERSION:6
        #EXT-X-TARGETDURATION:6
        #EXT-X-MEDIA-SEQUENCE:8070
        #EXT-X-MAP:URI="https://cdn.example.net/init.mp4"
        #EXTINF:2.000,live
        https://cdn.example.net/seg-8070.mp4
        #EXTINF:2.000,live
        https://cdn.example.net/seg-8071.mp4
        """
        let reparsed = TwitchMediaPlaylist.parse(finalizedUpstream, relativeTo: mediaURL)
        let rerendered = reparsed.renderLLHLS(segmentPartsByMSN: parts, pinnedSegmentURIs: pinned)
        #expect(rerendered.contains("http://127.0.0.1:9999/t/seg/v1/8071.mp4"))
        #expect(!rerendered.contains("https://cdn.example.net/seg-8071.mp4"))
    }

    @Test("Safely handles non-finite EXTINF durations without trapping")
    func handlesNonFiniteDuration() {
        let mediaURL = URL(string: "https://video-weaver.example.net/v1/playlist/bad.m3u8")!
        let bad = """
        #EXTM3U
        #EXT-X-VERSION:6
        #EXT-X-TARGETDURATION:6
        #EXT-X-MEDIA-SEQUENCE:1
        #EXTINF:inf,live
        https://cdn.example.net/seg-1.mp4
        """
        let parsed = TwitchMediaPlaylist.parse(bad, relativeTo: mediaURL)
        #expect(parsed.segments.first?.duration == 2.0)
        let rendered = parsed.renderLLHLS()
        #expect(rendered.contains("#EXT-X-TARGETDURATION:6"))
    }

    @Test("Keeps TARGETDURATION >= longest ad segment and disables LL-HLS on legacy .ts")
    func respectsAdDurationsAndLegacyTS() {
        let mediaURL = URL(string: "https://video-weaver.example.net/v1/playlist/ad.m3u8")!
        let adPlaylist = """
        #EXTM3U
        #EXT-X-VERSION:6
        #EXT-X-TARGETDURATION:6
        #EXT-X-MEDIA-SEQUENCE:10
        #EXT-X-DISCONTINUITY
        #EXTINF:5.500,Amazon
        https://cdn.example.net/ad-10.ts
        #EXT-X-TWITCH-PREFETCH:https://cdn.example.net/live-11.ts
        """
        let parsed = TwitchMediaPlaylist.parse(adPlaylist, relativeTo: mediaURL)
        #expect(parsed.supportsLLHLS == false)

        let rendered = parsed.renderLLHLS()
        #expect(rendered.contains("#EXT-X-TARGETDURATION:6"))
        #expect(rendered.contains("#EXT-X-DISCONTINUITY"))
        #expect(!rendered.contains("EXT-X-PART-INF"))
        #expect(!rendered.contains("EXT-X-PRELOAD-HINT"))
    }

    // MARK: - Local HTTP request parser

    @Test("Parses LL-HLS blocking reload query parameters and keep-alive header")
    func parsesLocalHTTPRequest() {
        let raw = "GET /abc123/media/v1.m3u8?_HLS_msn=8072&_HLS_part=3 HTTP/1.1\r\nHost: 127.0.0.1:50000\r\nConnection: keep-alive\r\n\r\n"
        let req = LocalHTTPRequest.parse(headerData: Data(raw.utf8))
        #expect(req?.method == "GET")
        #expect(req?.path == "/abc123/media/v1.m3u8")
        #expect(req?.queryItems["_HLS_msn"] == "8072")
        #expect(req?.queryItems["_HLS_part"] == "3")
        #expect(req?.wantsKeepAlive == true)

        let closeRaw = "GET /abc123/part/v1/8072/3.mp4 HTTP/1.1\r\nConnection: close\r\n\r\n"
        let closeReq = LocalHTTPRequest.parse(headerData: Data(closeRaw.utf8))
        #expect(closeReq?.wantsKeepAlive == false)
    }

    #if os(iOS)
    @Test("Loopback proxy binds on 127.0.0.1 and rejects unauthenticated requests")
    func loopbackProxyBindsAndEnforcesToken() async throws {
        let proxy = TwitchLLHLSProxy()
        let master = URL(string: "https://usher.ttvnw.net/api/channel/hls/test.m3u8?sig=1&token=2")!
        let playlist = StreamPlaylist(url: master, isAudioOnlyRendition: false)
        let proxied = await proxy.proxiedURL(for: playlist)

        #expect(proxied != nil)
        #expect(proxied?.host == "127.0.0.1")
        #expect(proxied?.path.contains("/master/") == true)

        if let port = proxied?.port,
           let badURL = URL(string: "http://127.0.0.1:\(port)/wrong-token/master/m1.m3u8") {
            let (_, response) = try await URLSession.shared.data(from: badURL)
            #expect((response as? HTTPURLResponse)?.statusCode == 403)
        }
        await proxy.stopAll()
    }
    #endif
}
