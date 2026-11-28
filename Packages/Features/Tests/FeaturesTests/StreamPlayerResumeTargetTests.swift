#if os(iOS)
import AVFoundation
import CoreMedia
import Testing
@testable import Features

@MainActor
@Suite("Stream player live resume target")
struct StreamPlayerResumeTargetTests {
    private func seconds(_ value: Double) -> CMTime {
        CMTime(seconds: value, preferredTimescale: 600)
    }

    @Test("Seeks liveOffset behind the end of a normal seekable range")
    func normalLiveRange() {
        let range = CMTimeRange(start: seconds(100), duration: seconds(30))
        let target = StreamPlayerController.liveResumeTarget(for: range)
        #expect(target == seconds(124))
    }

    @Test("Respects a custom low-latency offset")
    func lowLatencyLiveRange() {
        let range = CMTimeRange(start: seconds(100), duration: seconds(30))
        let target = StreamPlayerController.liveResumeTarget(
            for: range,
            offset: PlaybackLatencyProfile.lowLatency.liveOffset
        )
        #expect(target == seconds(128))
    }

    @Test("Clamps to range start when the seekable window is shorter than liveOffset")
    func shortLiveRangeClampsToStart() {
        let range = CMTimeRange(start: seconds(100), duration: seconds(3))
        let target = StreamPlayerController.liveResumeTarget(for: range)
        #expect(target == seconds(100))
    }

    @Test("Seekable window matching liveOffset lands on range start")
    func exactOffsetWindow() {
        let range = CMTimeRange(start: seconds(10), duration: StreamPlayerController.liveOffset)
        let target = StreamPlayerController.liveResumeTarget(for: range)
        #expect(target == seconds(10))
    }

    @Test("Rejects invalid, empty, and negative-duration ranges")
    func rejectsInvalidAndEmptyRanges() {
        #expect(StreamPlayerController.liveResumeTarget(for: .invalid) == nil)
        #expect(StreamPlayerController.liveResumeTarget(for: .zero) == nil)
        #expect(StreamPlayerController.liveResumeTarget(
            for: CMTimeRange(start: seconds(50), duration: .zero)
        ) == nil)
        #expect(StreamPlayerController.liveResumeTarget(
            for: CMTimeRange(start: seconds(50), duration: seconds(-5))
        ) == nil)
        #expect(StreamPlayerController.liveResumeTarget(
            for: CMTimeRange(start: .invalid, duration: seconds(30))
        ) == nil)
        #expect(StreamPlayerController.liveResumeTarget(
            for: CMTimeRange(start: seconds(50), duration: .invalid)
        ) == nil)
    }

    @Test("Rejects indefinite and infinite live HLS ranges")
    func rejectsIndefiniteAndInfiniteRanges() {
        #expect(StreamPlayerController.liveResumeTarget(
            for: CMTimeRange(start: seconds(10), duration: .indefinite)
        ) == nil)
        #expect(StreamPlayerController.liveResumeTarget(
            for: CMTimeRange(start: .indefinite, duration: seconds(30))
        ) == nil)
        #expect(StreamPlayerController.liveResumeTarget(
            for: CMTimeRange(start: .indefinite, duration: .indefinite)
        ) == nil)
        #expect(StreamPlayerController.liveResumeTarget(
            for: CMTimeRange(start: seconds(10), duration: .positiveInfinity)
        ) == nil)
        #expect(StreamPlayerController.liveResumeTarget(
            for: CMTimeRange(start: .positiveInfinity, duration: seconds(30))
        ) == nil)
        #expect(StreamPlayerController.liveResumeTarget(
            for: CMTimeRange(start: .negativeInfinity, duration: seconds(30))
        ) == nil)
    }

    @Test("Rejects ranges whose end overflows to non-numeric")
    func rejectsOverflowingRangeEnd() {
        // Timescale 1 prevents CoreMedia from halving the timescale to avoid Int64 overflow.
        let hugeStart = CMTime(value: Int64.max - 10, timescale: 1)
        let range = CMTimeRange(start: hugeStart, duration: CMTime(value: 30, timescale: 1))
        #expect(StreamPlayerController.liveResumeTarget(for: range) == nil)
    }

    @Test("Resuming an AVPlayer whose item is not ready does not throw")
    func resumeWithUnreadyPlayerItemDoesNotCrash() {
        let item = AVPlayerItem(asset: AVMutableComposition())
        let player = AVPlayer(playerItem: item)
        defer {
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
        let controller = StreamPlayerController()
        controller.avPlayer = player

        controller.resume()
        controller.togglePlay()
        controller.togglePlay()
    }
}
#endif
