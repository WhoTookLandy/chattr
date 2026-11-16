import Testing
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Features

@Suite("DecodedAnimation poster frame")
struct DecodedAnimationTests {

    /// Build a small animated PNG in memory. Each entry in `alphas` becomes
    /// one frame filled with red at that alpha — so a 0 produces a fully
    /// transparent frame, mirroring the delta-encoded WebPs (e.g. 7TV's
    /// SHEESH) whose first frame is blank. `delays` (parallel to `alphas`,
    /// padded with 0.05) sets per-frame durations for timing tests, and
    /// `width`/`height` shape the frames for aspect-fit tests.
    static func apng(
        alphas: [CGFloat],
        delays: [Double] = [],
        width: Int = 8,
        height: Int = 8
    ) -> Data {
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, alphas.count, nil
        )!
        CGImageDestinationSetProperties(dest, [
            kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 0]
        ] as CFDictionary)
        for (i, alpha) in alphas.enumerated() {
            let ctx = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: alpha))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let delay = i < delays.count ? delays[i] : 0.05
            CGImageDestinationAddImage(dest, ctx.makeImage()!, [
                kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: delay]
            ] as CFDictionary)
        }
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    @Test("Transparent first frame is skipped in favor of the first visible frame")
    func skipsBlankLeadingFrames() throws {
        let data = Self.apng(alphas: [0, 0, 1, 1])
        let decoded = try #require(DecodedAnimation(data: data))
        #expect(decoded.frameCount == 4)
        #expect(decoded.posterIndex == 2)
    }

    @Test("Visible first frame stays the poster")
    func keepsVisibleFirstFrame() throws {
        let data = Self.apng(alphas: [1, 0, 1])
        let decoded = try #require(DecodedAnimation(data: data))
        #expect(decoded.posterIndex == 0)
    }

    @Test("All-transparent animation falls back to frame zero")
    func allBlankFallsBackToZero() throws {
        let data = Self.apng(alphas: [0, 0])
        let decoded = try #require(DecodedAnimation(data: data))
        #expect(decoded.posterIndex == 0)
    }
}

@Suite("DecodedAnimation keyframe timing")
struct DecodedAnimationKeyTimeTests {

    /// CAKeyframeAnimation's `.discrete` mode requires `values.count + 1`
    /// keyTimes, with the final entry at 1.0 — frame i is held from
    /// keyTimes[i] to keyTimes[i+1]. With only `values.count` entries CA
    /// ignores keyTimes entirely and falls back to even spacing, which
    /// breaks variable-duration animations.
    @Test("Discrete keyTimes carry one more entry than frames, ending at 1.0")
    func keyTimesHaveTrailingSentinel() throws {
        // 0.1 + 0.3 + 0.1 + 0.5 = 1.0s total → boundaries 0, 0.1, 0.4, 0.5, 1.0
        let data = DecodedAnimationTests.apng(alphas: [1, 1, 1, 1], delays: [0.1, 0.3, 0.1, 0.5])
        let decoded = try #require(DecodedAnimation(data: data))
        let times = decoded.normalizedKeyTimes.map(\.doubleValue)

        #expect(times.count == decoded.frameCount + 1)
        let expected = [0, 0.1, 0.4, 0.5, 1.0]
        #expect(times.count == expected.count)
        for (t, e) in zip(times, expected) {
            #expect(abs(t - e) < 0.001, "keyTime \(t) ≠ expected \(e)")
        }
    }
}

@Suite("DecodedAnimation content identity")
struct DecodedAnimationIdentityTests {

    /// `AnimatedEmoteView.configure` must be able to no-op when SwiftUI
    /// re-delivers the same cached animation — otherwise every benign
    /// `updateUIView` restarts the frame cycle at t=0. Identity is by
    /// frame-object reference: the same `DecodedAnimation` value out of
    /// `DecodedAnimationCache` shares its CGImage instances.
    @Test("Same decoded instance compares as same content")
    func sameInstanceIsSameContent() throws {
        let data = DecodedAnimationTests.apng(alphas: [1, 1])
        let decoded = try #require(DecodedAnimation(data: data))
        let copy = decoded
        #expect(decoded.hasSameFrames(as: copy))
    }

    @Test("Independent decodes of identical data are different content")
    func separateDecodesDiffer() throws {
        let data = DecodedAnimationTests.apng(alphas: [1, 1])
        let a = try #require(DecodedAnimation(data: data))
        let b = try #require(DecodedAnimation(data: data))
        #expect(!a.hasSameFrames(as: b))
    }
}

@Suite("DecodedAnimation display sizing")
struct DecodedAnimationDisplaySizeTests {

    /// `CAAnimatedImage` wraps a plain UIView with no intrinsic size, so
    /// the SwiftUI side must compute the aspect-fitted box explicitly —
    /// mirroring what `.scaledToFit()` gives the static-image branch.
    @Test("Square frames fit the shorter box edge")
    func squareFitsShortEdge() throws {
        let data = DecodedAnimationTests.apng(alphas: [1, 1], width: 32, height: 32)
        let decoded = try #require(DecodedAnimation(data: data))
        let size = decoded.displaySize(fitting: CGSize(width: 28, height: 24))
        #expect(size == CGSize(width: 24, height: 24))
    }

    @Test("Wide frames cap at box width")
    func wideCapsAtWidth() throws {
        let data = DecodedAnimationTests.apng(alphas: [1, 1], width: 64, height: 32)
        let decoded = try #require(DecodedAnimation(data: data))
        let size = decoded.displaySize(fitting: CGSize(width: 28, height: 24))
        #expect(size == CGSize(width: 28, height: 14))
    }

    @Test("Tall frames cap at box height")
    func tallCapsAtHeight() throws {
        let data = DecodedAnimationTests.apng(alphas: [1, 1], width: 16, height: 32)
        let decoded = try #require(DecodedAnimation(data: data))
        let size = decoded.displaySize(fitting: CGSize(width: 28, height: 24))
        #expect(size == CGSize(width: 12, height: 24))
    }
}

@Suite("DecodedAnimation downsampling and frame cap")
struct DecodedAnimationBudgetTests {

    @Test("maxPixelSize decodes frames as thumbnails bounded by the longer side")
    func downsamplesToMaxPixelSize() throws {
        let data = DecodedAnimationTests.apng(alphas: [1, 1], width: 64, height: 32)
        let decoded = try #require(DecodedAnimation(data: data, maxPixelSize: 16))
        #expect(decoded.frameCount == 2)
        #expect(decoded.firstFrame.width == 16)
        #expect(decoded.firstFrame.height == 8)
        // Cache cost tracks the downsampled bitmap, not the source.
        #expect(decoded.byteCost == 2 * 16 * 8 * 4)
    }

    @Test("Without maxPixelSize frames keep their native size")
    func nilMaxPixelSizeKeepsNativeSize() throws {
        let data = DecodedAnimationTests.apng(alphas: [1, 1], width: 64, height: 32)
        let decoded = try #require(DecodedAnimation(data: data))
        #expect(decoded.firstFrame.width == 64)
        #expect(decoded.firstFrame.height == 32)
    }

    @Test("Long animations are capped and keep their total loop duration")
    func capsFrameCountPreservingDuration() throws {
        let frameCount = 300
        let data = DecodedAnimationTests.apng(
            alphas: Array(repeating: 1, count: frameCount),
            delays: Array(repeating: 0.05, count: frameCount))
        let decoded = try #require(DecodedAnimation(data: data, maxPixelSize: 16))
        #expect(decoded.frameCount <= DecodedAnimation.maxFrameCount)
        #expect(decoded.frameCount == 100)                       // every 3rd frame of 300
        #expect(abs(decoded.totalDuration - Double(frameCount) * 0.05) < 0.01)
        #expect(decoded.normalizedKeyTimes.count == decoded.frameCount + 1)
    }

    @Test("Animations within the cap keep every frame")
    func underCapKeepsAllFrames() throws {
        let data = DecodedAnimationTests.apng(alphas: Array(repeating: 1, count: 120))
        let decoded = try #require(DecodedAnimation(data: data, maxPixelSize: 16))
        #expect(decoded.frameCount == 120)
    }
}

@Suite("AnimatedEmoteDecoder pixel-size buckets")
struct AnimatedEmoteDecoderBucketTests {

    @Test("Pixel size is the box's longer side × scale, rounded up to 16")
    func bucketsLongerSide() {
        // 28×24pt at @3x → 84px → bucket 96.
        #expect(AnimatedEmoteDecoder.maxPixelSize(for: CGSize(width: 28, height: 24), scale: 3) == 96)
        // 24×24pt at @2x → 48px, already a multiple of 16.
        #expect(AnimatedEmoteDecoder.maxPixelSize(for: CGSize(width: 24, height: 24), scale: 2) == 48)
        // Degenerate input still yields a usable minimum.
        #expect(AnimatedEmoteDecoder.maxPixelSize(for: .zero, scale: 0) == 16)
    }
}
