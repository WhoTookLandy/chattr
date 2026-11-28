import Foundation
import CoreMedia
import Testing
#if os(iOS)
import AVFoundation
#endif
@testable import Features

@Suite("Playback latency profile and telemetry")
struct PlaybackLatencyTests {
    private func seconds(_ value: Double) -> CMTime {
        CMTime(seconds: value, preferredTimescale: 600)
    }

    @Test("Standard and low-latency profiles resolve expected offset and forward buffer")
    func profileResolution() {
        let standard = PlaybackLatencyProfile.resolve(lowLatency: false)
        #expect(standard == .standard)
        #expect(standard.liveOffsetSeconds == 6)
        #expect(standard.forwardBufferDuration == 0)
        #expect(!standard.isLowLatency)

        let low = PlaybackLatencyProfile.resolve(lowLatency: true)
        #expect(low == .lowLatency)
        #expect(low.liveOffsetSeconds == 2)
        #expect(low.forwardBufferDuration == 2)
        #expect(low.isLowLatency)
    }

    @Test("Computes e2e, live-edge lag, forward buffer, offsets, and cumulative stalls")
    func snapshotMetricsCalculation() {
        let now = Date(timeIntervalSince1970: 1_700_000_010)
        let programDate = Date(timeIntervalSince1970: 1_700_000_002.6)
        let snapshot = PlaybackLatencySnapshot.make(
            channelLogin: "hasanabi",
            mode: .audioOnly,
            isLowLatency: true,
            currentTime: seconds(125.5),
            currentDate: programDate,
            now: now,
            seekableRanges: [CMTimeRange(start: seconds(100), duration: seconds(30))],
            loadedRanges: [
                CMTimeRange(start: seconds(100), duration: seconds(10)),
                CMTimeRange(start: seconds(122), duration: seconds(5.5)),
            ],
            configuredTimeOffsetFromLive: seconds(2),
            recommendedTimeOffsetFromLive: seconds(4.5),
            preferredForwardBufferDuration: 2,
            stallCounts: [-1, 1, 2]
        )

        #expect(snapshot.endToEndSeconds != nil)
        #expect(abs((snapshot.endToEndSeconds ?? 0) - 7.4) < 0.001)
        #expect(abs((snapshot.liveEdgeLagSeconds ?? 0) - 4.5) < 0.001)
        #expect(abs((snapshot.bufferedAheadSeconds ?? 0) - 2.0) < 0.001)
        #expect(snapshot.configuredOffsetSeconds == 2.0)
        #expect(snapshot.recommendedOffsetSeconds == 4.5)
        #expect(snapshot.preferredForwardBufferSeconds == 2.0)
        #expect(snapshot.stallCount == 3)

        let hud = snapshot.compactHUDLine()
        #expect(hud == "play:aud(LL) e2e:7.4s lag:4.5s buf:2.0s cfg:2.0s rec:4.5s stl:3")

        let otherChannelHUD = snapshot.compactHUDLine(showChannel: true)
        #expect(otherChannelHUD.hasPrefix("play:@hasanabi aud(LL) "))

        #expect(snapshot.logSummary.contains("channel=@hasanabi"))
        #expect(snapshot.logSummary.contains("mode=aud"))
        #expect(snapshot.logSummary.contains("profile=LL"))
        #expect(snapshot.logSummary.contains("fwdCap=2.0s"))
        #expect(snapshot.logSummary.contains("stalls=3"))
    }

    @Test("Ignores non-numeric CMTime ranges and out-of-bounds program dates")
    func snapshotHandlesMissingAndInvalidValues() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let futureDate = Date(timeIntervalSince1970: 1_700_000_050)
        let snapshot = PlaybackLatencySnapshot.make(
            channelLogin: "xqc",
            mode: .video,
            isLowLatency: false,
            currentTime: .invalid,
            currentDate: futureDate,
            now: now,
            seekableRanges: [CMTimeRange(start: seconds(10), duration: .indefinite)],
            loadedRanges: [],
            configuredTimeOffsetFromLive: .invalid,
            recommendedTimeOffsetFromLive: .indefinite,
            preferredForwardBufferDuration: 0,
            stallCounts: nil
        )

        #expect(snapshot.endToEndSeconds == nil)
        #expect(snapshot.liveEdgeLagSeconds == nil)
        #expect(snapshot.bufferedAheadSeconds == nil)
        #expect(snapshot.configuredOffsetSeconds == nil)
        #expect(snapshot.recommendedOffsetSeconds == nil)
        #expect(snapshot.stallCount == nil)
        #expect(snapshot.compactHUDLine() == "play:vid(std)")
        #expect(snapshot.logSummary.contains("fwdCap=auto"))
    }

    @Test("Formats web engine snapshots concisely")
    func webSnapshotFormatting() {
        let snapshot = PlaybackLatencySnapshot(
            channelLogin: "lirik",
            mode: .web,
            isLowLatency: false,
            endToEndSeconds: nil,
            liveEdgeLagSeconds: nil,
            bufferedAheadSeconds: nil,
            configuredOffsetSeconds: nil,
            recommendedOffsetSeconds: nil,
            preferredForwardBufferSeconds: 0,
            stallCount: nil
        )
        #expect(snapshot.compactHUDLine() == "play:web (WKWebView HLS)")
        #expect(snapshot.compactHUDLine(showChannel: true) == "play:@lirik web (WKWebView HLS)")
        #expect(snapshot.logSummary == "channel=@lirik mode=web")
    }

    #if os(iOS)
    @MainActor
    @Test("applyLatencyProfile updates AVPlayerItem offset and forward buffer live")
    func applyLatencyProfileUpdatesPlayerItem() {
        let item = AVPlayerItem(asset: AVMutableComposition())
        let player = AVPlayer(playerItem: item)
        defer {
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
        let controller = StreamPlayerController()
        controller.avPlayer = player

        controller.applyLatencyProfile(.lowLatency)
        #expect(item.automaticallyPreservesTimeOffsetFromLive == true)
        #expect(item.configuredTimeOffsetFromLive == PlaybackLatencyProfile.lowLatency.liveOffset)
        #expect(item.preferredForwardBufferDuration == 2)

        controller.applyLatencyProfile(.standard)
        #expect(item.configuredTimeOffsetFromLive == PlaybackLatencyProfile.standard.liveOffset)
        #expect(item.preferredForwardBufferDuration == 0)
    }
    #endif
}
