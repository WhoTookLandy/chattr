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
    /// False = decode the animation but display only its poster frame.
    /// This is the "Animated Emotes off" path: it must NOT fall back to a
    /// generic first-frame decode (Nuke/LazyImage), because delta-encoded
    /// WebPs open on a blank frame — the poster pick needs the full frame
    /// list to choose from.
    var animate: Bool = true
    @ViewBuilder let placeholder: () -> Placeholder

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var decoded: DecodedAnimation?

    var body: some View {
        content
            .frame(maxWidth: width, maxHeight: height)
            .task(id: url) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let decoded {
            if decoded.frameCount > 1 && animate && !reduceMotion {
                #if canImport(UIKit)
                // Core-Animation path: frame cycling runs on the render
                // server (a separate process), so the main thread spends
                // nothing per frame. This replaced a per-emote TimelineView
                // that rebuilt a SwiftUI Image ~25×/sec — with N animated
                // emotes visible that was N×25 main-thread view rebuilds per
                // second, even while chat sat idle.
                //
                // Explicit aspect-fitted frame: the backing UIView has no
                // intrinsic size, so under FlowLayout's (width, nil) measuring
                // proposal the representable would otherwise collapse to
                // SwiftUI's 10pt unspecified-dimension fallback instead of
                // filling the emote box like the static Image branch does.
                let size = decoded.displaySize(fitting: CGSize(width: width, height: height))
                CAAnimatedImage(animation: decoded)
                    .frame(width: size.width, height: size.height)
                #else
                // AppKit / other platforms keep the TimelineView fallback.
                // `.animation(minimumInterval:)` throttles the redraw cadence;
                // `frame(at:)` is a cheap cumulative-duration lookup.
                TimelineView(.animation(minimumInterval: 1.0 / 25.0)) { timeline in
                    image(decoded.frame(at: timeline.date.timeIntervalSinceReferenceDate))
                }
                #endif
            } else {
                // Single frame, animations off, or Reduce Motion → show the
                // poster frame (first VISIBLE frame, not frame 0 — see
                // `DecodedAnimation.posterIndex`).
                image(decoded.posterFrame)
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
            // A nil result means the bytes weren't decodable as an animation;
            // leave `decoded` nil so the caller's placeholder (the emote name)
            // stays — the same fallback the loading state already shows. There
            // is no distinct error treatment, so we don't track a failure flag.
            if let result {
                DecodedAnimationCache.shared.store(result, for: url)
                decoded = result
            }
        } catch {
            // A url change or view teardown cancels the `.task(id:)`, which
            // cancels the in-flight pipeline fetch — that's expected churn,
            // not a real failure. Either way `decoded` stays nil and the
            // placeholder remains; nothing to record.
            guard !Task.isCancelled else { return }
            logger.debug("Animated decode load failed for \(url.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)")
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

    /// Index of the frame used for any STATIC display of this animation
    /// (Reduce Motion, animated-emotes-off, and the layer's model contents
    /// behind the keyframe animation). Delta-encoded WebPs — 7TV's SHEESH
    /// is the canonical case — open on a transparent/near-blank frame, so
    /// "show frame 0" renders the emote as empty space. This is the first
    /// frame with meaningful alpha coverage instead.
    let posterIndex: Int

    var frameCount: Int { frames.count }
    var firstFrame: CGImage { frames[0] }
    var posterFrame: CGImage { frames[posterIndex] }

    /// Frame boundaries normalized to 0...1 for a discrete
    /// `CAKeyframeAnimation`: frame i is held from `[i]` to `[i+1]`, so the
    /// array carries `frames.count + 1` entries — first 0, last 1.0. CA
    /// requires exactly that count for `.discrete` mode and silently falls
    /// back to even spacing (ignoring real frame durations) otherwise.
    var normalizedKeyTimes: [NSNumber] {
        guard totalDuration > 0 else { return [] }
        var times: [NSNumber] = []
        times.reserveCapacity(durations.count + 1)
        var elapsed = 0.0
        for duration in durations {
            times.append(NSNumber(value: elapsed / totalDuration))
            elapsed += duration
        }
        times.append(1.0)
        return times
    }

    /// True when both values share the same decoded frame objects — i.e.
    /// they are the same `DecodedAnimationCache` entry. Lets
    /// `AnimatedEmoteView.configure` no-op (instead of restarting the frame
    /// cycle) when SwiftUI re-delivers an unchanged animation through
    /// `updateUIView`. Reference identity is the right notion of "same":
    /// re-decodes of identical bytes produce new CGImages and genuinely
    /// reset the view.
    func hasSameFrames(as other: DecodedAnimation) -> Bool {
        frameCount == other.frameCount && frames.first === other.frames.first
    }

    /// Aspect-fit size of the frames within `box` — what `.scaledToFit()`
    /// computes for the static `Image` branch. The Core-Animation branch
    /// needs it spelled out because its backing `UIView` has no intrinsic
    /// size for SwiftUI/FlowLayout to measure.
    func displaySize(fitting box: CGSize) -> CGSize {
        let frame = posterFrame
        guard frame.width > 0, frame.height > 0 else { return box }
        let aspect = CGFloat(frame.width) / CGFloat(frame.height)
        let width = min(box.width, box.height * aspect)
        return CGSize(width: width, height: width / aspect)
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
        self.posterIndex = Self.findPosterIndex(in: frames)
    }

    /// First frame with ≥5% non-transparent pixels, scanned over the first
    /// few frames only (the blank-opener pattern resolves within 2–3 frames;
    /// scanning a 378-frame animation end-to-end would waste the decode
    /// thread). Falls back to frame 0 when nothing in the window qualifies —
    /// an all-blank animation has nothing better to offer anyway.
    ///
    /// Runs at init time, which `AnimatedImageView.load` already keeps off
    /// the main thread, and the result is cached with the decoded frames.
    private static func findPosterIndex(in frames: [CGImage]) -> Int {
        for (index, frame) in frames.prefix(10).enumerated() {
            if alphaCoverage(of: frame) >= 0.05 { return index }
        }
        return 0
    }

    /// Fraction of pixels with non-negligible alpha, via a downsampled
    /// render: drawing into a 16×16 context samples the frame uniformly,
    /// so the cost is constant regardless of source dimensions.
    private static func alphaCoverage(of image: CGImage) -> Double {
        let side = 16
        guard let ctx = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 1 }   // can't measure → assume visible, frame 0 wins
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = ctx.data else { return 1 }
        let buffer = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        var visible = 0
        for pixel in 0..<(side * side) where buffer[pixel * 4 + 3] > 8 { visible += 1 }
        return Double(visible) / Double(side * side)
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
///
/// ## Animation persistence
///
/// Core Animation silently REMOVES all animations from a layer whenever it
/// leaves the layer tree (collection-view cell recycling, view detach) or
/// the app backgrounds. Without re-attachment the layer falls back to its
/// model `contents` — and for delta-encoded WebPs whose opening frame is
/// blank, the emote turns into invisible-but-space-reserving nothing. So:
///   - the model `contents` is the POSTER frame (always visible), and
///   - `didMoveToWindow` + `didBecomeActiveNotification` re-add the
///     keyframe animation whenever CA has stripped it.
final class AnimatedEmoteView: UIView {
    private static let animationKey = "emoteFrameCycle"

    /// Retained so the re-attach paths can rebuild the keyframe animation
    /// after CA strips it. The frames are shared, immutable CGImages out
    /// of `DecodedAnimationCache` — no extra memory beyond the reference.
    private var animation: DecodedAnimation?

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Backgrounding strips layer animations process-wide; restart the
        // frame cycle when the app comes back. Selector-based observation
        // is auto-removed on dealloc, so no teardown bookkeeping.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reattachAnimationIfNeeded),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(with animation: DecodedAnimation) {
        // SwiftUI calls `updateUIView` (→ here) on every re-evaluation of
        // the representable — appearance/environment changes, row updates.
        // Tearing down and re-adding the keyframe animation for the SAME
        // content would snap every visible emote back to frame 0 on each
        // benign update, so an unchanged animation only re-attaches if CA
        // stripped it (detach/background) and otherwise no-ops.
        if let current = self.animation, current.hasSameFrames(as: animation) {
            reattachAnimationIfNeeded()
            return
        }
        self.animation = animation
        layer.contentsGravity = .resizeAspect
        // Trilinear filtering ≈ SwiftUI's `.interpolation(.high)` — keeps
        // emotes crisp when down-sampled into the small chat-row box.
        layer.magnificationFilter = .trilinear
        layer.minificationFilter = .trilinear
        layer.removeAnimation(forKey: Self.animationKey)
        // Poster frame (not frame 0) as the model value: this is what shows
        // whenever the animation isn't running, so it must be visible.
        layer.contents = animation.posterFrame
        addFrameCycleAnimation()
    }

    /// Re-attach after the cell/view re-enters a window — the detach that
    /// preceded this is exactly when CA removed the animation.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { reattachAnimationIfNeeded() }
    }

    @objc private func reattachAnimationIfNeeded() {
        guard window != nil, layer.animation(forKey: Self.animationKey) == nil else { return }
        addFrameCycleAnimation()
    }

    private func addFrameCycleAnimation() {
        guard let animation, animation.frameCount > 1, animation.totalDuration > 0 else { return }
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
