import Foundation
import Core
import EmoteSources

/// Which image an emote surface loads, and through which renderer.
///
/// Chat rows, the emote picker and the launch prefetcher all have to
/// arrive at the same URL for an emote: Nuke's memory and disk caches and
/// the decoded-animation cache are keyed by it, so a surface that spelled
/// it differently would miss everything the others had already loaded.
/// The rule is written here once and all three call it.
struct EmoteImageSource: Equatable, Sendable {
    let url: URL?
    /// True → the frame decoder (`AnimatedImageView`); false → Nuke's
    /// `LazyImage`.
    let isAnimated: Bool

    /// A Twitch native emote.
    ///
    /// - Parameters:
    ///   - formats: The emote's format list — `"static"`, plus `"animated"`
    ///     when it has an animated variant.
    ///   - animate: False when the surface will only ever show a still
    ///     (Animated Emotes off, the picker). The CDN serves every emote's
    ///     still at the same path with `static` as the format, so that is
    ///     loaded instead of downloading the animation to take one frame.
    static func twitch(id: String, formats: [String], animate: Bool = true) -> EmoteImageSource {
        // The CDN falls back to static when an emote has no animated
        // variant, so asking for "animated" would be safe; "static" skips
        // the frame decoder for emotes known not to need it.
        let animated = animate && formats.contains("animated")
        return EmoteImageSource(
            url: Endpoints.TwitchCDN.emote(id: id, format: animated ? "animated" : "static"),
            isAnimated: animated)
    }

    /// A 7TV / BTTV / FFZ emote. With `animate` false, an animated emote
    /// whose provider lists a separate still image (`Emote.staticURLs`)
    /// loads that; otherwise the animated file is used and the renderer
    /// shows its poster frame.
    static func thirdParty(_ emote: Emote, animate: Bool = true) -> EmoteImageSource {
        if emote.isAnimated, !animate, let still = preferredURL(in: emote.staticURLs ?? [:]) {
            return EmoteImageSource(url: still, isAnimated: false)
        }
        return EmoteImageSource(url: preferredURL(in: emote.urls), isAnimated: emote.isAnimated)
    }

    /// The 2x size matches a chat line on @2x/@3x displays; fall back to
    /// whatever exists for partial-variant emotes.
    private static func preferredURL(in urls: [Emote.Size: URL]) -> URL? {
        urls[.x2] ?? urls[.x1] ?? urls[.x4]
    }
}
