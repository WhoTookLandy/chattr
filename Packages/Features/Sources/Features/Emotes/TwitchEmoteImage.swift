import SwiftUI
import TwitchKit
import Core      // For Endpoints.TwitchCDN.emote(...)

/// Loads and displays a single Twitch native emote from the CDN, using
/// Nuke's `LazyImage` for memory + disk caching and prefetching.
/// Falls back to the literal text name while loading or on failure.
///
/// **iOS 26 perf note**: under chat scroll, the same emote tends to
/// repeat dozens of times within the visible buffer. LazyImage's
/// synchronous memory-cache hit means once we've decoded an emote
/// once, every subsequent occurrence renders with no fetch and no
/// placeholder flash.
struct TwitchEmoteImage: View {
    let emote: EmoteReference
    let displayName: String
    /// Pre-resolved CDN URL, computed once in `init`. Storing as `let`
    /// ensures a stable URL across re-renders — Nuke deduplicates
    /// fetches by URL, so stability matters for cache-hit efficiency.
    private let emoteURL: URL?
    /// Whether this Twitch emote has an animated variant — drives the
    /// ImageIO-based animated renderer vs the cheap static LazyImage.
    private let isAnimated: Bool
    /// From `ChatAppearance.animatedEmotes`. Off → animated emotes show their
    /// poster frame, matching `ThirdPartyEmoteImage`.
    let allowAnimation: Bool

    init(emote: EmoteReference, displayName: String, allowAnimation: Bool = true) {
        self.emote = emote
        self.displayName = displayName
        self.allowAnimation = allowAnimation
        // Twitch CDN auto-falls-back to static when an emote has no animated
        // variant, so requesting "animated" is always safe; sticking with
        // "static" avoids the (small) extra processing for emotes we know
        // don't have animation metadata.
        let animated = (emote.format ?? []).contains("animated")
        self.isAnimated = animated
        self.emoteURL = Endpoints.TwitchCDN.emote(id: emote.id, format: animated ? "animated" : "static")
    }

    /// Fixed box from metadata (Twitch emotes are square), applied to every
    /// state — the placeholder used to be the free-width emote name, so the
    /// row reflowed when the image replaced it.
    private static let box = EmoteDisplayMetrics.size(
        aspectRatio: EmoteDisplayMetrics.twitchAspectRatio,
        height: EmoteDisplayMetrics.lineHeight)

    var body: some View {
        EmoteImageView(
            url: emoteURL,
            isAnimated: isAnimated,
            width: Self.box.width, height: Self.box.height,
            accessibilityLabel: displayName,
            boxSize: Self.box,
            animate: allowAnimation
        ) { image in
            image.resizable().interpolation(.high).scaledToFit()
        } placeholder: { failed in
            EmotePlaceholder(name: displayName, failed: failed)
        }
    }
}
