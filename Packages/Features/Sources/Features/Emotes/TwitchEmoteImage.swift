import SwiftUI
import TwitchKit

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
    /// Size multiplier from the chat text-size setting, so Twitch emotes
    /// track the surrounding text the way third-party emotes and badges do.
    let scale: CGFloat
    /// From `ChatAppearance.animatedEmotes`. Off → animated emotes show a
    /// still, matching `ThirdPartyEmoteImage`.
    let allowAnimation: Bool
    /// Pre-resolved CDN URL and renderer choice, computed once in `init`.
    /// Storing it as `let` ensures a stable URL across re-renders — Nuke
    /// deduplicates fetches by URL, so stability matters for cache-hit
    /// efficiency.
    private let source: EmoteImageSource

    init(emote: EmoteReference, displayName: String, scale: CGFloat = 1, allowAnimation: Bool = true) {
        self.emote = emote
        self.displayName = displayName
        self.scale = scale
        self.allowAnimation = allowAnimation
        self.source = EmoteImageSource.twitch(
            id: emote.id, formats: emote.format ?? [], animate: allowAnimation)
    }

    var body: some View {
        // Fixed box from metadata (Twitch emotes are square), applied to
        // every state — the placeholder used to be the free-width emote
        // name, so the row reflowed when the image replaced it.
        let box = EmoteDisplayMetrics.size(
            aspectRatio: EmoteDisplayMetrics.twitchAspectRatio,
            height: EmoteDisplayMetrics.lineHeight * scale)
        EmoteImageView(
            url: source.url,
            isAnimated: source.isAnimated,
            width: box.width, height: box.height,
            accessibilityLabel: displayName,
            boxSize: box,
            animate: allowAnimation
        ) { image in
            image.resizable().interpolation(.high).scaledToFit()
        } placeholder: { failed in
            EmotePlaceholder(name: displayName, failed: failed)
        }
    }
}
