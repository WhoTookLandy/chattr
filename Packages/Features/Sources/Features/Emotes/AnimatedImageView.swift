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
                #if canImport(UIKit)
                // Core-Animation path: frame cycling runs on the render
                // server (a separate process), so the main thread spends
                // nothing per frame. This replaced a per-emote TimelineView
                // that rebuilt a SwiftUI Image ~25×/sec — with N animated
                // emotes visible that was N×25 main-thread view rebuilds per
                // second, even while chat sat idle.
                CAAnimatedImage(animation: decoded)
                #else
                // AppKit / other platforms keep the TimelineView fallback.
                // `.animation(minimumInterval:)` throttles the redraw cadence;
                // `frame(at:)` is a cheap cumulative-duration lookup.
                TimelineView(.animation(minimumInterval: 1.0 / 25.0)) { timeline in
                    image(decoded.frame(at: timeline.date.timeIntervalSinceReferenceDate))
                }
                #endif
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

        // Cache hit: skip BOTH the network/disk fetch and the frame decode.
        // Re-scrolling to a previously-seen animated emote is now instant
        // instead of re-running CGImageSource frame extraction on every
        // appearance (the decoded CGImages are immutable + safe to share).
        if let cached = DecodedAnimationCache.shared.decoded(for: url) {
            decoded = cached
            return
        }

        do {
            let (data, _) = try await ImagePipeline.shared.data(for: ImageRequest(url: url))
            // Decode off-main — CGImageSource frame extraction is CPU work.
            let result = await Task.detached(priority: .utility) {
                DecodedAnimation(data: data)
            }.value
            guard !Task.isCancelled else { return }
            if let result {
                DecodedAnimationCache.shared.store(result, for: url)
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
    /// `internal` (not `private`) so the Core-Animation bridge below can
    /// hand the frames straight to a `CAKeyframeAnimation`.
    let frames: [CGImage]
    private let durations: [Double]
    let totalDuration: Double

    var frameCount: Int { frames.count }
    var firstFrame: CGImage { frames[0] }

    /// Cumulative per-frame start times normalized to 0...1, one entry per
    /// frame (first is 0). Drives a discrete `CAKeyframeAnimation` so each
    /// frame is held for its real duration.
    var normalizedKeyTimes: [NSNumber] {
        guard totalDuration > 0 else { return [] }
        var times: [NSNumber] = []
        times.reserveCapacity(durations.count)
        var elapsed = 0.0
        for duration in durations {
            times.append(NSNumber(value: elapsed / totalDuration))
            elapsed += duration
        }
        return times
    }

    /// Approximate decoded-bytes footprint. Used as the `NSCache` cost so
    /// the cache sheds the largest animations first under memory pressure.
    var byteCost: Int {
        guard let first = frames.first else { return 0 }
        return frames.count * first.width * first.height * 4
    }

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

// MARK: - Decoded-animation cache

/// Process-wide cache of decoded animations, keyed by source URL.
///
/// Decoding (CGImageSource frame extraction) is the expensive part, and a
/// view's `@State decoded` is thrown away when its row leaves the
/// `LazyVStack` buffer — so without this, scrolling back to a seen emote
/// re-fetched AND re-decoded it. Frames are immutable `CGImage`s, safe to
/// share across views and actors. `NSCache` evicts under memory pressure
/// using each entry's `byteCost`.
///
/// `@unchecked Sendable`: `NSCache` is internally thread-safe, and the
/// cached `DecodedAnimation` is itself immutable.
final class DecodedAnimationCache: @unchecked Sendable {
    static let shared = DecodedAnimationCache()

    private final class Entry {
        let value: DecodedAnimation
        init(_ value: DecodedAnimation) { self.value = value }
    }

    private let cache = NSCache<NSURL, Entry>()

    init() {
        // ~64 MB ceiling on decoded frames. Tuned for "a few hundred distinct
        // animated emotes in a session"; NSCache evicts the rest as needed.
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    func decoded(for url: URL) -> DecodedAnimation? {
        cache.object(forKey: url as NSURL)?.value
    }

    func store(_ animation: DecodedAnimation, for url: URL) {
        cache.setObject(Entry(animation), forKey: url as NSURL, cost: animation.byteCost)
    }
}

// MARK: - Core Animation bridge

#if canImport(UIKit)
/// SwiftUI bridge to a `CALayer`-backed view that cycles emote frames via a
/// discrete `CAKeyframeAnimation`.
///
/// The whole point: Core Animation runs the frame cycling on the render
/// server, so the main thread does **zero** work per frame. The
/// `TimelineView` path this replaced re-ran a SwiftUI body (rebuilding an
/// `Image`) on every tick, for every visible animated emote — the dominant
/// cost in emote-heavy channels.
struct CAAnimatedImage: UIViewRepresentable {
    let animation: DecodedAnimation

    func makeUIView(context: Context) -> AnimatedEmoteView { AnimatedEmoteView() }

    func updateUIView(_ view: AnimatedEmoteView, context: Context) {
        view.configure(with: animation)
    }
}

/// Bare `UIView` whose backing layer holds the emote frames and the
/// repeating keyframe animation. Sizing comes from the SwiftUI `.frame`
/// applied to the representable; `.resizeAspect` fits the image inside the
/// box, matching the old `.scaledToFit()`.
final class AnimatedEmoteView: UIView {
    private static let animationKey = "emoteFrameCycle"

    func configure(with animation: DecodedAnimation) {
        layer.contentsGravity = .resizeAspect
        // Trilinear filtering ≈ SwiftUI's `.interpolation(.high)` — keeps
        // emotes crisp when down-sampled into the small chat-row box.
        layer.magnificationFilter = .trilinear
        layer.minificationFilter = .trilinear
        layer.removeAnimation(forKey: Self.animationKey)
        layer.contents = animation.firstFrame

        guard animation.frameCount > 1, animation.totalDuration > 0 else { return }

        let keyframes = CAKeyframeAnimation(keyPath: "contents")
        keyframes.values = animation.frames as [Any]
        keyframes.keyTimes = animation.normalizedKeyTimes
        keyframes.duration = animation.totalDuration
        // `.discrete` = hard frame switches with no cross-fade blending,
        // which is what frame-based animation (GIF/WebP/APNG) wants.
        keyframes.calculationMode = .discrete
        keyframes.repeatCount = .infinity
        layer.add(keyframes, forKey: Self.animationKey)
    }
}
#endif
