import Testing
import CoreGraphics
@testable import Features

@Suite("Emote display width")
struct EmoteDisplayMetricsTests {

    /// Without provider dimensions we keep the historical 28×24 box —
    /// existing BTTV emotes (no dims in their API) render unchanged.
    @Test("Unknown aspect falls back to the legacy 28:24 box")
    func nilAspectKeepsLegacyBox() {
        #expect(EmoteDisplayMetrics.width(aspectRatio: nil, height: 24) == 28)
    }

    @Test("Square emotes get a square box")
    func squareIsSquare() {
        #expect(EmoteDisplayMetrics.width(aspectRatio: 1.0, height: 24) == 24)
    }

    @Test("Wide emotes get their natural width at fixed height")
    func wideGetsNaturalWidth() {
        #expect(EmoteDisplayMetrics.width(aspectRatio: 3.0, height: 24) == 72)
    }

    @Test("Width is capped at 4× height for absurdly wide emotes")
    func absurdWidthIsCapped() {
        #expect(EmoteDisplayMetrics.width(aspectRatio: 10.0, height: 24) == 96)
    }

    @Test("Width is floored for degenerate sliver emotes")
    func sliverWidthIsFloored() {
        #expect(EmoteDisplayMetrics.width(aspectRatio: 0.05, height: 24) == 6)
    }

    @Test("Scaled height scales the width with it")
    func scalesWithHeight() {
        // 1.5× text scale → height 36, wide 2:1 emote → 72.
        #expect(EmoteDisplayMetrics.width(aspectRatio: 2.0, height: 36) == 72)
    }
}

@Suite("Emote display box")
struct EmoteDisplayBoxTests {

    @Test("Inline box is metadata width × line height")
    func boxFromMetadata() {
        #expect(EmoteDisplayMetrics.size(aspectRatio: 2.0, height: 24) == CGSize(width: 48, height: 24))
        #expect(EmoteDisplayMetrics.size(aspectRatio: nil, height: 24) == CGSize(width: 28, height: 24))
    }

    @Test("Twitch native emotes get a square box")
    func twitchIsSquare() {
        let box = EmoteDisplayMetrics.size(
            aspectRatio: EmoteDisplayMetrics.twitchAspectRatio,
            height: EmoteDisplayMetrics.lineHeight)
        #expect(box == CGSize(width: 24, height: 24))
    }
}
