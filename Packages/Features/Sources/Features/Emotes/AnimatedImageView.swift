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
/// by decoding its frames with ImageIO and cycling them via Core Animation.
/// Falls back to a static image when the source has a single frame or
/// when Reduce Motion is on.
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
/// - Decoding goes through `AnimatedEmoteDecoder`: one in-flight fetch +
///   decode per (URL, pixel size) no matter how many rows show the emote,
///   run off the main thread two at a time, with frames downsampled to the
///   display box and capped in count and bytes (see
///   `DecodedAnimation.maxFrameCount` / `maxByteCost`).
/// - Reduce Motion → static poster frame (respects the accessibility
///   setting; SwiftUI symbol effects do the same). Low Power Mode and a
///   serious or critical thermal state do the same for as long as they
///   last (`EmotePlaybackStore`).
///
/// ## Layout
///
/// The view is always exactly `width × height` — loading, failed, or
/// loaded. Callers size the box from emote metadata
/// (`EmoteDisplayMetrics`), so a row never reflows when the bitmap lands.
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
    /// Shown while loading (`failed == false`) and after a fetch/decode
    /// failure (`failed == true`).
    @ViewBuilder let placeholder: (_ failed: Bool) -> Placeholder

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale

    @State private var decoded: DecodedAnimation?
    @State private var failed = false
    /// The key `decoded` / `failed` were loaded for. A reused hosting cell
    /// can keep this view's @State across lines, so state loaded for a
    /// different key is never displayed.
    @State private var loadedKey: LoadKey?
    /// Holds a cache-hit animation for as long as this view shows it. A
    /// plain reference box, so filling it is not a state change: the body
    /// already drew those frames from the cache, and a second pass to draw
    /// them again was pure overhead.
    @State private var held = HeldAnimation()

    /// Re-decode when the URL, the target pixel size (text-size setting,
    /// display scale) or the playback mode changes.
    private struct LoadKey: Equatable {
        let url: URL?
        let maxPixelSize: Int
        /// Only the poster will ever be shown (animations off / Reduce
        /// Motion / power or heat saving), so decode just that frame
        /// instead of the whole animation — see
        /// `DecodedAnimation.init(data:maxPixelSize:posterOnly:)`.
        let posterOnly: Bool
    }

    /// See `held`. Only ever touched from this view's main-actor code.
    private final class HeldAnimation {
        private var heldKey: LoadKey?
        private var heldAnimation: DecodedAnimation?

        func animation(for key: LoadKey) -> DecodedAnimation? {
            heldKey == key ? heldAnimation : nil
        }

        func hold(_ animation: DecodedAnimation?, for key: LoadKey?) {
            heldKey = key
            heldAnimation = animation
        }
    }

    var body: some View {
        // Read here, not in `content`, so a change re-keys the load below:
        // the poster-only decode is a different (much smaller) cache entry.
        let animates = animate && !reduceMotion && !EmotePlaybackStore.shared.suspendsAnimation
        let key = LoadKey(
            url: url,
            maxPixelSize: AnimatedEmoteDecoder.maxPixelSize(
                for: CGSize(width: width, height: height), scale: displayScale),
            posterOnly: !animates)
        // A synchronous cache hit renders the final view on the FIRST pass.
        // Waiting for `.task` meant every animated emote in every new or
        // reused row drew its placeholder for a frame, then ran a second body
        // pass — dozens of times a second in a busy chat.
        content(shownAnimation(for: key), failed: loadedKey == key && failed, animates: animates)
            .frame(width: width, height: height)
            .task(id: key) { await load(key) }
    }

    /// The frames to draw for `key` on this pass: the ones loaded into
    /// state for it, else the ones this view already holds, else a cache
    /// hit — which is recorded in `held` (a plain box, so no state change)
    /// both to keep it alive and so `load` can tell "the body drew these"
    /// from "the cache filled after the body drew its placeholder".
    private func shownAnimation(for key: LoadKey) -> DecodedAnimation? {
        if loadedKey == key, let decoded { return decoded }
        if let kept = held.animation(for: key) { return kept }
        guard let cached = Self.cachedAnimation(for: key) else { return nil }
        held.hold(cached, for: key)
        return cached
    }

    /// The cached decode for `key`, if any. A poster-only view can also use
    /// an already-decoded full animation (its poster frame is the same one).
    private static func cachedAnimation(for key: LoadKey) -> DecodedAnimation? {
        guard let url = key.url else { return nil }
        let cache = DecodedAnimationCache.shared
        return cache.decoded(for: url, maxPixelSize: key.maxPixelSize, posterOnly: key.posterOnly)
            ?? (key.posterOnly ? cache.decoded(for: url, maxPixelSize: key.maxPixelSize, posterOnly: false) : nil)
    }

    @ViewBuilder
    private func content(_ decoded: DecodedAnimation?, failed: Bool, animates: Bool) -> some View {
        if let decoded {
            if decoded.frameCount > 1 && animates {
                #if canImport(UIKit)
                // Core-Animation path: frame cycling runs on the render
                // server (a separate process), so the main thread spends
                // nothing per frame. This replaced a per-emote TimelineView
                // that rebuilt a SwiftUI Image ~25×/sec — with N animated
                // emotes visible that was N×25 main-thread view rebuilds per
                // second, even while chat sat idle.
                //
                // The representable fills the fixed emote box (the backing
                // UIView has no intrinsic size); `.resizeAspect` on the layer
                // fits the frames inside it, matching `.scaledToFit()` on the
                // static branch — so the box never depends on the bitmap.
                CAAnimatedImage(animation: decoded)
                    .frame(width: width, height: height)
                #else
                // AppKit / other platforms keep the TimelineView fallback.
                // `.animation(minimumInterval:)` throttles the redraw cadence;
                // `frame(at:)` is a cheap cumulative-duration lookup.
                TimelineView(.animation(minimumInterval: 1.0 / 25.0)) { timeline in
                    image(decoded.frame(at: timeline.date.timeIntervalSinceReferenceDate))
                }
                #endif
            } else {
                // Single frame, animations off, Reduce Motion, or saving
                // power → show the poster frame (first VISIBLE frame, not
                // frame 0 — see `DecodedAnimation.posterIndex`).
                image(decoded.posterFrame)
            }
        } else {
            placeholder(failed)
        }
    }

    private func image(_ cg: CGImage) -> some View {
        Image(decorative: cg, scale: 1)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
    }

    private func load(_ key: LoadKey) async {
        // Re-appearance with the same key: already showing it.
        if loadedKey == key, decoded != nil { return }
        // The body drew these frames straight from the cache and holds them
        // (see `shownAnimation`), so an NSCache eviction can't blank a
        // visible emote: no fetch, no decode, and no state write — unless
        // frames loaded for an earlier key are still in state, which would
        // keep them in memory behind an emote that no longer shows them.
        if held.animation(for: key) != nil {
            if decoded != nil {
                decoded = nil
                failed = false
                loadedKey = nil
            }
            return
        }
        guard let url = key.url else {
            decoded = nil
            failed = true
            loadedKey = key
            return
        }

        // The cache filled between the body pass and this task (another
        // row's decode of the same emote landed), so the body drew the
        // placeholder: this hit needs the state write to get a second pass.
        // Still no fetch and no frame decode.
        if let cached = Self.cachedAnimation(for: key) {
            held.hold(nil, for: nil)
            decoded = cached
            failed = false
            loadedKey = key
            return
        }

        // Reset for a new key (id-keyed .task re-runs on change).
        held.hold(nil, for: nil)
        decoded = nil
        failed = false
        loadedKey = key

        do {
            // Shared, de-duplicated fetch + off-main decode: every row
            // showing this emote awaits the same task.
            let result = try await AnimatedEmoteDecoder.shared.animation(
                for: url, maxPixelSize: key.maxPixelSize, posterOnly: key.posterOnly)
            guard !Task.isCancelled else { return }
            if let result {
                decoded = result
            } else {
                // Bytes weren't decodable as an image.
                failed = true
            }
        } catch {
            // A key change or view teardown cancels the `.task(id:)` —
            // expected churn, not a failure.
            guard !Task.isCancelled else { return }
            failed = true
            logger.debug("Animated decode load failed for \(url.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Decoded animation frames + per-frame durations, extracted from
/// animated image data via ImageIO. Handles GIF, animated WebP, and APNG.
///
/// A class, not a struct, so every holder of one decode — the cache, each
/// view showing it, the Core-Animation layer — retains the SAME object:
/// that is what lets `DecodedAnimationCache` keep a weak reference and hand
/// a still-visible animation back after the cache evicted it, instead of
/// decoding a second copy.
///
/// `@unchecked Sendable` because it's built on a background task and
/// handed to the MainActor view: `CGImage` is immutable + thread-safe to
/// pass, and every stored property is a `let` set once in `init`.
final class DecodedAnimation: @unchecked Sendable {
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
    ///
    /// Computed once at decode time (off-main): the animation is re-attached
    /// on every cell display, window move and foreground return, and
    /// rebuilding up to 121 `NSNumber`s each time was pure churn.
    let normalizedKeyTimes: [NSNumber]

    /// Frame rate the animation actually needs — the rate of its SHORTEST
    /// frame, so no frame can be skipped — rounded up to a rate the display
    /// can present (see `presentableFrameRates`), 10...60. Handed to
    /// Core Animation so an emote cycling at 10–30 fps doesn't hold the
    /// render server at the display's full refresh rate.
    let peakFrameRate: Float

    private static func keyTimes(for durations: [Double], total: Double) -> [NSNumber] {
        guard total > 0 else { return [] }
        var times: [NSNumber] = []
        times.reserveCapacity(durations.count + 1)
        var elapsed = 0.0
        for duration in durations {
            times.append(NSNumber(value: elapsed / total))
            elapsed += duration
        }
        times.append(1.0)
        return times
    }

    /// Rates that divide both 60 Hz and 120 Hz evenly — what the display can
    /// actually run a layer at. A 25 fps request with a 25 Hz maximum lets the
    /// system settle on 20 Hz and drop frames, so the need is rounded UP to
    /// the next of these instead.
    private static let presentableFrameRates: [Double] = [10, 12, 15, 20, 30, 60]

    private static func peakFrameRate(for durations: [Double]) -> Float {
        guard let shortest = durations.filter({ $0 > 0 }).min() else { return 60 }
        let needed = 1 / shortest
        return Float(presentableFrameRates.first { $0 >= needed } ?? 60)
    }

    /// Where in its loop the animation is at `time`, for any clock every
    /// view reads the same way. Starting each view's frame cycle here
    /// (rather than at frame 0 whenever a row happens to appear) keeps the
    /// same emote in step across rows.
    func phase(at time: Double) -> Double {
        guard totalDuration > 0 else { return 0 }
        let offset = time.truncatingRemainder(dividingBy: totalDuration)
        return offset < 0 ? offset + totalDuration : offset
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

    /// Aspect-fit size of the frames within `box` — the rect `.scaledToFit()`
    /// (static branch) and `.resizeAspect` (Core-Animation branch) draw into
    /// inside the fixed emote box. Layout never uses it: the box comes from
    /// emote metadata so rows don't reflow when the bitmap arrives.
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

    /// Upper bound on retained frames. Long animations (some 7TV emotes
    /// ship 300+ frames) are sampled down to this by keeping every n-th
    /// frame and folding the skipped frames' delays into the kept one, so
    /// the loop length and pacing are preserved at a lower frame rate.
    /// 120 frames ≈ 4s at 30fps — beyond that, extra frames cost memory
    /// without being noticeable at emote size.
    static let maxFrameCount = 120

    /// Upper bound on one animation's decoded bytes. A square emote at the
    /// usual 64 px decode fits all `maxFrameCount` frames in half of this;
    /// wide emotes and larger text sizes have 3–4× the pixels per frame, and
    /// are sampled down (same frame-skipping as above) once a full decode
    /// would pass it. Without a per-entry bound a handful of long, wide
    /// emotes could take the whole cache — and visible ones stay in memory
    /// whatever the cache evicts.
    static let maxByteCost = 4 * 1024 * 1024

    /// How many frames of a `pixelWidth` × `pixelHeight` source may be
    /// kept when decoded at `maxPixelSize`: `maxFrameCount`, or fewer when
    /// that many would exceed `maxByteCost`.
    static func frameLimit(pixelWidth: Int, pixelHeight: Int, maxPixelSize: Int?) -> Int {
        guard pixelWidth > 0, pixelHeight > 0 else { return maxFrameCount }
        var width = Double(pixelWidth)
        var height = Double(pixelHeight)
        // Thumbnails are scaled to fit `maxPixelSize` and never upscaled.
        if let maxPixelSize, maxPixelSize > 0 {
            let scale = min(1, Double(maxPixelSize) / max(width, height))
            width = (width * scale).rounded(.up)
            height = (height * scale).rounded(.up)
        }
        let bytesPerFrame = max(1, Int(width) * Int(height) * 4)
        return min(maxFrameCount, max(1, maxByteCost / bytesPerFrame))
    }

    /// `frameLimit` for an image source, from its header (no frame decode).
    private static func frameLimit(source: CGImageSource, maxPixelSize: Int?) -> Int {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int
        else { return maxFrameCount }
        return frameLimit(pixelWidth: width, pixelHeight: height, maxPixelSize: maxPixelSize)
    }

    /// - Parameters:
    ///   - data: Encoded GIF / animated WebP / APNG (or a still image).
    ///   - maxPixelSize: When set, every frame is decoded straight to a
    ///     thumbnail whose longer side is at most this many pixels (the
    ///     display box × screen scale) instead of at full resolution — a
    ///     4x 7TV emote decoded for a 24pt row is ~10× fewer bytes per
    ///     frame. `nil` decodes at native size.
    ///   - posterOnly: Decode ONLY the poster frame (the first visible one —
    ///     see `posterIndex`), stopping as soon as it's found, and keep it as
    ///     a single-frame result. For views that will never animate
    ///     (Animated Emotes off, Reduce Motion): they show just the poster,
    ///     so decoding and retaining up to `maxFrameCount` frames for them
    ///     is wasted CPU and memory.
    ///
    /// Also `nil` when the calling task is cancelled part-way: the frame
    /// loops check between frames, so a decode nobody is waiting for any
    /// more stops instead of running out its (up to 120-frame) course.
    init?(data: Data, maxPixelSize: Int? = nil, posterOnly: Bool = false) {
        // Don't let the source keep its own decoded copy of every frame —
        // we hold the (downsampled) CGImages ourselves.
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }

        // Decode eagerly (on this background thread) rather than lazily at
        // first render, which would land on the main thread / render path.
        let frameOptions: CFDictionary
        if let maxPixelSize {
            frameOptions = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
            ] as [CFString: Any] as CFDictionary
        } else {
            frameOptions = [kCGImageSourceShouldCacheImmediately: true] as [CFString: Any] as CFDictionary
        }

        // Keep every `step`-th frame so the survivors fit both the frame
        // cap and the byte budget.
        let frameLimit = DecodedAnimation.frameLimit(source: source, maxPixelSize: maxPixelSize)
        let step = max(1, (count + frameLimit - 1) / frameLimit)

        func decodeFrame(at index: Int) -> CGImage? {
            if maxPixelSize != nil {
                CGImageSourceCreateThumbnailAtIndex(source, index, frameOptions)
            } else {
                CGImageSourceCreateImageAtIndex(source, index, frameOptions)
            }
        }

        if posterOnly {
            // Walk the same sampled frames, within the same window, that
            // `findPosterIndex` scans — so the poster matches the full
            // decode's — but stop at the first visible one.
            var fallback: CGImage?
            var poster: CGImage?
            for start in stride(from: 0, to: count, by: step).prefix(DecodedAnimation.posterScanWindow) {
                if Task.isCancelled { return nil }
                guard let image = decodeFrame(at: start) else { continue }
                if fallback == nil { fallback = image }
                if DecodedAnimation.alphaCoverage(of: image) >= DecodedAnimation.posterMinCoverage {
                    poster = image
                    break
                }
            }
            guard let chosen = poster ?? fallback else { return nil }
            self.frames = [chosen]
            self.durations = [0]
            self.totalDuration = 0
            self.normalizedKeyTimes = []
            self.peakFrameRate = 60
            self.posterIndex = 0
            return
        }

        var frames: [CGImage] = []
        var durations: [Double] = []
        frames.reserveCapacity(min(count, frameLimit))
        durations.reserveCapacity(min(count, frameLimit))
        for start in stride(from: 0, to: count, by: step) {
            if Task.isCancelled { return nil }
            guard let image = decodeFrame(at: start) else { continue }
            // The kept frame is held for the skipped frames' time too, so
            // the total loop duration is unchanged.
            var duration = 0.0
            for index in start..<min(start + step, count) {
                duration += DecodedAnimation.frameDuration(source: source, index: index)
            }
            frames.append(image)
            durations.append(duration)
        }
        guard !frames.isEmpty else { return nil }

        let total = durations.reduce(0, +)
        self.frames = frames
        self.durations = durations
        self.totalDuration = total
        self.normalizedKeyTimes = DecodedAnimation.keyTimes(for: durations, total: total)
        self.peakFrameRate = DecodedAnimation.peakFrameRate(for: durations)
        self.posterIndex = DecodedAnimation.findPosterIndex(in: frames)
    }

    /// First frame with ≥5% non-transparent pixels, scanned over the first
    /// few frames only (the blank-opener pattern resolves within 2–3 frames;
    /// scanning a 378-frame animation end-to-end would waste the decode
    /// thread). Falls back to frame 0 when nothing in the window qualifies —
    /// an all-blank animation has nothing better to offer anyway.
    ///
    /// Runs at init time, which `AnimatedEmoteDecoder` keeps off the main
    /// thread, and the result is cached with the decoded frames.
    private static func findPosterIndex(in frames: [CGImage]) -> Int {
        for (index, frame) in frames.prefix(posterScanWindow).enumerated() {
            if alphaCoverage(of: frame) >= posterMinCoverage { return index }
        }
        return 0
    }

    /// How many (sampled) frames the poster search looks at, and the alpha
    /// coverage a frame needs to count as visible. Shared by the full decode
    /// and the poster-only decode so both pick the same frame.
    private static let posterScanWindow = 10
    private static let posterMinCoverage = 0.05

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

    /// Shortest frame delay played as written. Anything shorter — and the
    /// 0 that many GIFs carry to mean "as fast as possible" — plays at
    /// 100 ms instead, the rule browsers apply (Chrome, Firefox and Safari
    /// all turn a delay of 10 ms or less into 100 ms), so an emote runs at
    /// the speed its author saw. Played literally, a 10 ms delay ran ten
    /// times too fast and asked the display for 60 Hz.
    static let minimumFrameDelay = 0.011

    /// The delay a frame is actually shown for, given the one its file
    /// declares (`nil` = none declared).
    static func clampedFrameDelay(_ declared: Double?) -> Double {
        guard let declared, declared >= minimumFrameDelay else { return 0.1 }
        return declared
    }

    /// Per-frame delay in seconds, read from the format-specific
    /// properties and clamped (see `clampedFrameDelay`). Falls back to
    /// ~10fps when no delay is present.
    private static func frameDuration(source: CGImageSource, index: Int) -> Double {
        let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        return clampedFrameDelay(props.flatMap { declaredFrameDelay(in: $0) })
    }

    private static func declaredFrameDelay(in props: [CFString: Any]) -> Double? {
        // GIF — prefer the unclamped delay (ImageIO's clamped value turns
        // everything under 50 ms into 100 ms, but emotes often run faster).
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
        return nil
    }
}

// MARK: - Decoded-animation cache

/// Process-wide cache of decoded animations, keyed by source URL + decode
/// pixel size (frames are downsampled to the display box, so the same URL
/// at two sizes is two entries).
///
/// Decoding (CGImageSource frame extraction) is the expensive part, and a
/// view's `@State decoded` is thrown away when its row leaves the
/// `LazyVStack` buffer — so without this, scrolling back to a seen emote
/// re-fetched AND re-decoded it. Frames are immutable `CGImage`s, safe to
/// share across views and actors. `NSCache` evicts under memory pressure
/// using each entry's `byteCost`.
///
/// ## Live table
///
/// Evicting an entry frees nothing while a view still shows it — the view
/// holds the same `DecodedAnimation` — and a new row asking for that emote
/// used to decode a second copy next to it. So every stored animation is
/// also tracked weakly under its cache key: a miss consults that table
/// first and re-adopts an animation that is still alive. Memory is then
/// bounded by "what is on screen" plus the cache limit, not by how often
/// the cache turned over.
///
/// `@unchecked Sendable`: `NSCache` is internally thread-safe, the cached
/// `DecodedAnimation` is itself immutable, and the live table is only
/// touched under `liveLock`.
final class DecodedAnimationCache: @unchecked Sendable {
    static let shared = DecodedAnimationCache()

    private let cache = NSCache<NSString, DecodedAnimation>()

    /// A live animation, without keeping it alive.
    private struct WeakAnimation {
        weak var animation: DecodedAnimation?
    }

    /// Guards `live` and `liveSweepThreshold`.
    private let liveLock = NSLock()
    private var live: [String: WeakAnimation] = [:]
    /// Entry count at which dead references are swept out of `live`.
    private var liveSweepThreshold = 256

    init() {
        // ~64 MB ceiling on decoded frames. Tuned for "a few hundred distinct
        // animated emotes in a session"; NSCache evicts the rest as needed.
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    /// Poster-only decodes are a separate entry from full ones: the same URL
    /// and size would otherwise hand a single-frame result to a view that
    /// wants to animate.
    static func key(url: URL, maxPixelSize: Int, posterOnly: Bool = false) -> String {
        "\(maxPixelSize)|\(posterOnly ? "poster" : "full")|\(url.absoluteString)"
    }

    /// Requested size bucket → the size the frames were actually decoded at
    /// (see `AnimatedEmoteDecoder.effectivePixelSize`), so a larger bucket
    /// resolves to the one cost-bearing entry instead of storing — and
    /// charging `totalCostLimit` for — the same frames twice. Tiny values;
    /// an evicted alias just costs a header read on the next decode request.
    private let aliases = NSCache<NSString, NSNumber>()

    func decoded(for url: URL, maxPixelSize: Int, posterOnly: Bool = false) -> DecodedAnimation? {
        let key = Self.key(url: url, maxPixelSize: maxPixelSize, posterOnly: posterOnly)
        if let hit = entry(forKey: key) { return hit }
        guard let effective = aliases.object(forKey: key as NSString)?.intValue, effective != maxPixelSize else { return nil }
        return entry(forKey: Self.key(url: url, maxPixelSize: effective, posterOnly: posterOnly))
    }

    /// The entry stored under `key` — from the cache, or, once evicted,
    /// from whichever view still holds it (which puts it back in the cache).
    private func entry(forKey key: String) -> DecodedAnimation? {
        if let cached = cache.object(forKey: key as NSString) { return cached }
        guard let alive = liveLock.withLock({ live[key]?.animation }) else { return nil }
        cache.setObject(alive, forKey: key as NSString, cost: alive.byteCost)
        return alive
    }

    /// Points the `requested` bucket at the entry stored under `effective`.
    func alias(_ url: URL, requested: Int, to effective: Int, posterOnly: Bool = false) {
        guard requested != effective else { return }
        aliases.setObject(
            NSNumber(value: effective),
            forKey: Self.key(url: url, maxPixelSize: requested, posterOnly: posterOnly) as NSString)
    }

    func store(_ animation: DecodedAnimation, for url: URL, maxPixelSize: Int, posterOnly: Bool = false) {
        let key = Self.key(url: url, maxPixelSize: maxPixelSize, posterOnly: posterOnly)
        cache.setObject(animation, forKey: key as NSString, cost: animation.byteCost)
        liveLock.withLock {
            live[key] = WeakAnimation(animation: animation)
            // Dead references are only ever removed here, so the table grows
            // with every distinct emote decoded; sweep when it has doubled.
            if live.count > liveSweepThreshold {
                live = live.filter { $0.value.animation != nil }
                liveSweepThreshold = max(256, live.count * 2)
            }
        }
    }

    /// Drops every cached animation (memory warning, Clear Cache). Ones a
    /// view is still showing stay alive through that view and are found
    /// again through the live table, so nothing on screen blanks or is
    /// decoded twice.
    func removeAll() {
        cache.removeAllObjects()
    }
}

// MARK: - Shared decoder

/// De-duplicates animated-emote fetch + decode across views.
///
/// A popular animated emote can be on screen in a dozen rows at once; on a
/// cache miss each `AnimatedImageView` used to start its own detached
/// decode of the same bytes. Now the first request for a (URL, pixel size)
/// starts one task and later requests await it. The task is cancelled only
/// when every view waiting on it has gone away (scrolled off), so fast
/// scrolling doesn't leave a backlog of decodes nobody will see.
///
/// Fetches run as they come (Nuke queues them); the frame extraction after
/// each is CPU-bound, so only `maxConcurrentDecodes` run at once. Opening a
/// channel full of animated emotes used to start one decode per emote, all
/// competing with each other and with chat's own background work.
actor AnimatedEmoteDecoder {
    static let shared = AnimatedEmoteDecoder()

    private struct InFlight {
        let task: Task<DecodedAnimation?, any Error>
        var waiters: Int
    }

    private var inFlight: [String: InFlight] = [:]

    private static let maxConcurrentDecodes = 4
    /// Decode slots taken, and the tasks queued for one (FIFO). Actor state.
    private var activeDecodes = 0
    private var decodeQueue: [CheckedContinuation<Void, Never>] = []

    /// Returns once the caller holds a decode slot. Not cancellation-aware
    /// on purpose: a cancelled task takes its turn, sees the cancellation,
    /// and gives the slot straight back.
    private func acquireDecodeSlot() async {
        if activeDecodes < Self.maxConcurrentDecodes {
            activeDecodes += 1
            return
        }
        // `releaseDecodeSlot` hands its slot over, still counted.
        await withCheckedContinuation { decodeQueue.append($0) }
    }

    private func releaseDecodeSlot() {
        if decodeQueue.isEmpty {
            activeDecodes -= 1
        } else {
            decodeQueue.removeFirst().resume()
        }
    }

    /// Guards each waiter's release so the normal-return path and the
    /// cancellation path can't both decrement the waiter count.
    private final class Waiter: Sendable {
        private let released = OSAllocatedUnfairLock(initialState: false)

        /// True exactly once.
        func claimRelease() -> Bool {
            released.withLock { (done: inout Bool) -> Bool in
                if done { return false }
                done = true
                return true
            }
        }
    }

    /// Decode-size bucket for a display box: the box's longer side in
    /// pixels, rounded up to a multiple of 16 so nearby text-size settings
    /// share cache entries.
    static func maxPixelSize(for box: CGSize, scale: CGFloat) -> Int {
        let pixels = Int((max(box.width, box.height) * max(scale, 1)).rounded(.up))
        return max(16, (pixels + 15) / 16 * 16)
    }

    /// The pixel size a thumbnail decode of `data` at `requested` actually
    /// produces: ImageIO never upscales, so it's capped at the source's long
    /// side. Reads only the header properties (no frame decode).
    static func effectivePixelSize(data: Data, requested: Int) -> Int {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { return requested }
        return min(requested, max(width, height))
    }

    /// The decoded animation for `url` at `maxPixelSize`, from cache or a
    /// shared fetch + decode. `nil` when the bytes aren't decodable.
    func animation(for url: URL, maxPixelSize: Int, posterOnly: Bool = false) async throws -> DecodedAnimation? {
        if let cached = DecodedAnimationCache.shared.decoded(for: url, maxPixelSize: maxPixelSize, posterOnly: posterOnly) {
            return cached
        }
        if posterOnly,
           let fullCached = DecodedAnimationCache.shared.decoded(for: url, maxPixelSize: maxPixelSize, posterOnly: false) {
            return fullCached
        }
        let key = DecodedAnimationCache.key(url: url, maxPixelSize: maxPixelSize, posterOnly: posterOnly)
        let task: Task<DecodedAnimation?, any Error>
        if var existing = inFlight[key] {
            existing.waiters += 1
            inFlight[key] = existing
            task = existing.task
        } else {
            // Poster-only decodes (e.g. visible emote picker cells for BTTV GIFs)
            // extract 1–2 frames and sit directly in front of the user, so run
            // them at `.userInitiated` rather than starving behind `.utility`.
            let priority: TaskPriority = posterOnly ? .userInitiated : .utility
            task = Task.detached(priority: priority) {
                let (data, _) = try await ImagePipeline.shared.data(for: ImageRequest(url: url))
                try Task.checkCancellation()
                let cache = DecodedAnimationCache.shared
                // Thumbnails never upscale, so every size bucket at or above
                // the source's long side decodes to identical frames. Key the
                // decode on the size actually produced, so chat rows at
                // different text sizes and the picker's larger cells share
                // one decode (and one cache entry's memory) instead of each
                // re-extracting every frame.
                let effective = AnimatedEmoteDecoder.effectivePixelSize(data: data, requested: maxPixelSize)
                // The alias lets the view's synchronous lookup at the
                // requested bucket find the shared entry; the frames are
                // stored (and their cost charged) once, under `effective`.
                cache.alias(url, requested: maxPixelSize, to: effective, posterOnly: posterOnly)
                if effective != maxPixelSize,
                   let shared = cache.decoded(for: url, maxPixelSize: effective, posterOnly: posterOnly) {
                    return shared
                }
                await self.acquireDecodeSlot()
                // Another size bucket of this emote may have decoded the
                // same frames while this task waited for its slot.
                if let shared = cache.decoded(for: url, maxPixelSize: effective, posterOnly: posterOnly) {
                    await self.releaseDecodeSlot()
                    return shared
                }
                // CPU-bound frame extraction, off the main thread and off
                // this actor. Stops between frames once cancelled.
                let decoded = Task.isCancelled
                    ? nil
                    : DecodedAnimation(data: data, maxPixelSize: effective, posterOnly: posterOnly)
                await self.releaseDecodeSlot()
                // A decode cut short is not "these bytes aren't an image".
                try Task.checkCancellation()
                guard let decoded else { return nil }
                cache.store(decoded, for: url, maxPixelSize: effective, posterOnly: posterOnly)
                return decoded
            }
            inFlight[key] = InFlight(task: task, waiters: 1)
        }

        let waiter = Waiter()
        defer { release(key: key, task: task, waiter: waiter) }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            // The view went away: drop our claim now (not when the shared
            // task eventually finishes) so the decode can be cancelled if
            // nobody else wants it.
            Task { await self.release(key: key, task: task, waiter: waiter) }
        }
    }

    private func release(key: String, task: Task<DecodedAnimation?, any Error>, waiter: Waiter) {
        guard waiter.claimRelease() else { return }
        guard var entry = inFlight[key], entry.task == task else { return }
        entry.waiters -= 1
        if entry.waiters > 0 {
            inFlight[key] = entry
            return
        }
        inFlight[key] = nil
        // No-op if it already finished; otherwise nobody is left to show
        // the result, so stop the fetch/decode.
        task.cancel()
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
        // Begin as if the loop had been running since a common origin, so
        // every layer showing this emote is on the same frame however late
        // its row appeared (or was re-attached). Both readings come from
        // the one `now`, so the phase doesn't depend on when the
        // transaction commits.
        let now = CACurrentMediaTime()
        keyframes.beginTime = layer.convertTime(now, from: nil) - animation.phase(at: now)
        // Let the render server run this layer at the rate the emote needs
        // (its shortest frame) rather than the full display refresh. Other
        // on-screen motion (scrolling) still gets full rate — the system
        // takes the highest rate anything asks for.
        let rate = animation.peakFrameRate
        keyframes.preferredFrameRateRange = CAFrameRateRange(minimum: min(10, rate), maximum: rate, preferred: rate)
        layer.add(keyframes, forKey: Self.animationKey)
    }
}
#endif
