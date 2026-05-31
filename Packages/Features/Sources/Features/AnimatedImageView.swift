import SwiftUI
import ImageIO
import Core
import Nuke
import os

#if canImport(UIKit)
import UIKit
#endif

private let logger = AppLogger.make("Features.AnimatedImage")

/// Renders an animated emote (7TV WebP, BTTV GIF, Twitch animated, APNG)
/// by decoding its frames with ImageIO and cycling them via a throttled
/// `TimelineView`. Falls back to a static image when the source has a
/// single frame or when Reduce Motion is on.
///
/// ## Why not NukeUI's LazyImage
///
/// NukeUI's SwiftUI `LazyImage` produces a static `SwiftUI.Image` (the
/// first frame) — Nuke 13 leaves animation to a `makeImageView` UIKit
/// hook. Since 7TV serves animated **WebP** (not GIF), a GIF-only lib
/// (Gifu) wouldn't cover the dominant emote provider. ImageIO decodes
/// WebP, GIF, and APNG uniformly on iOS, so one path handles every
/// animated emote format.
///
/// ## Performance
///
/// - Only used for emotes flagged `isAnimated` — the static majority keep
///   the cheap `LazyImage` path.
/// - Bytes come from Nuke's pipeline (`data(for:)`), which hits the warm
///   disk cache we prefetched, so there's no extra network on the hot path.
/// - Frame decode runs OFF the main thread (a detached task) so a chat
///   full of animated emotes doesn't hitch on decode.
/// - `TimelineView(.animation(minimumInterval:))` caps redraws at ~25fps
///   instead of the 120fps ProMotion default — plenty for emote motion,
///   a fraction of the cost. SwiftUI also pauses TimelineView updates
///   for off-screen rows (LazyVStack only renders visible cells).
/// - Reduce Motion → static first frame (respects the accessibility
///   setting; SwiftUI symbol effects do the same).
struct AnimatedImageView<Placeholder: View>: View {
    let url: URL?
    /// The frame the view occupies. Emotes are small fixed boxes.
    let width: CGFloat
    let height: CGFloat
    @ViewBuilder let placeholder: () -> Placeholder

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var decoded: DecodedAnimation?
    @State private var failed = false

    var body: some View {
        content
            .frame(maxWidth: width, maxHeight: height)
            .task(id: url) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let decoded {
            if decoded.frameCount > 1 && !reduceMotion {
                // Animated path. `.animation(minimumInterval:)` throttles
                // the redraw cadence; `frame(at:)` is a cheap cumulative-
                // duration lookup.
                TimelineView(.animation(minimumInterval: 1.0 / 25.0)) { timeline in
                    image(decoded.frame(at: timeline.date.timeIntervalSinceReferenceDate))
                }
            } else {
                // Single frame OR Reduce Motion → show the first frame.
                image(decoded.firstFrame)
            }
        } else {
            placeholder()
        }
    }

    private func image(_ cg: CGImage) -> some View {
        Image(decorative: cg, scale: 1)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
    }

    private func load() async {
        // Reset for a new URL (id-keyed .task re-runs on url change).
        decoded = nil
        failed = false
        guard let url else { return }

        do {
            let (data, _) = try await ImagePipeline.shared.data(for: ImageRequest(url: url))
            // Decode off-main — CGImageSource frame extraction is CPU work.
            let result = await Task.detached(priority: .utility) {
                DecodedAnimation(data: data)
            }.value
            guard !Task.isCancelled else { return }
            if let result {
                decoded = result
            } else {
                failed = true
            }
        } catch {
            // A url change or view teardown cancels the `.task(id:)`, which
            // cancels the in-flight pipeline fetch — that's expected churn,
            // not a real failure, so don't flip to the error state.
            guard !Task.isCancelled else { return }
            logger.debug("Animated decode load failed for \(url.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            failed = true
        }
    }
}

/// Decoded animation frames + per-frame durations, extracted from
/// animated image data via ImageIO. Handles GIF, animated WebP, and APNG.
///
/// `@unchecked Sendable` because it's built on a background task and
/// handed to the MainActor view: `CGImage` is immutable + thread-safe to
/// pass, and the arrays are never mutated after init.
struct DecodedAnimation: @unchecked Sendable {
    private let frames: [CGImage]
    private let durations: [Double]
    private let totalDuration: Double

    var frameCount: Int { frames.count }
    var firstFrame: CGImage { frames[0] }

    init?(data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }

        var frames: [CGImage] = []
        var durations: [Double] = []
        frames.reserveCapacity(count)
        durations.reserveCapacity(count)
        for i in 0..<count {
            guard let cg = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }
            frames.append(cg)
            durations.append(Self.frameDuration(source: source, index: i))
        }
        guard !frames.isEmpty else { return nil }

        self.frames = frames
        self.durations = durations
        self.totalDuration = durations.reduce(0, +)
    }

    /// The frame to show at an absolute time (seconds). Loops via modulo
    /// over the total animation duration.
    func frame(at time: TimeInterval) -> CGImage {
        guard totalDuration > 0, frames.count > 1 else { return frames[0] }
        var t = time.truncatingRemainder(dividingBy: totalDuration)
        for (i, d) in durations.enumerated() {
            if t < d { return frames[i] }
            t -= d
        }
        return frames[frames.count - 1]
    }

    /// Per-frame delay in seconds, read from the format-specific
    /// properties. Falls back to ~10fps when no delay is present.
    private static func frameDuration(source: CGImageSource, index: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else {
            return 0.1
        }
        // GIF — prefer the unclamped delay (browsers clamp to 0.1 min,
        // but emotes often run faster).
        if let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
            if let d = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double, d > 0 { return d }
            if let d = gif[kCGImagePropertyGIFDelayTime] as? Double, d > 0 { return d }
        }
        // Animated WebP (7TV's format).
        if let webp = props[kCGImagePropertyWebPDictionary] as? [CFString: Any] {
            if let d = webp[kCGImagePropertyWebPUnclampedDelayTime] as? Double, d > 0 { return d }
            if let d = webp[kCGImagePropertyWebPDelayTime] as? Double, d > 0 { return d }
        }
        // APNG.
        if let png = props[kCGImagePropertyPNGDictionary] as? [CFString: Any] {
            if let d = png[kCGImagePropertyAPNGUnclampedDelayTime] as? Double, d > 0 { return d }
            if let d = png[kCGImagePropertyAPNGDelayTime] as? Double, d > 0 { return d }
        }
        return 0.1
    }
}
