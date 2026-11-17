import SwiftUI
import EmoteSources

/// Inline image for a 7TV / BTTV / FFZ emote in a chat row — the
/// third-party counterpart of `TwitchEmoteImage`, rendered through the same
/// `EmoteImageView`.
///
/// Fixed line height, natural width: a wide emote gets its real aspect ratio
/// instead of being crushed into a square-ish box. The box comes from API
/// metadata (not the loaded image), and every state — loading, failed,
/// static, animated — renders in it, so the row's layout is final on the
/// first pass and never reflows when a wide emote pops in.
struct ThirdPartyEmoteImage: View {
    let emote: Emote
    /// Size multiplier from the chat text-size setting, so emotes track the
    /// surrounding text instead of staying fixed at 24pt.
    let scale: CGFloat
    /// From `ChatAppearance.animatedEmotes`. Off → animated emotes show a
    /// still (cheaper, calmer): the provider's static file when it lists
    /// one, else the animation's poster frame.
    let allowAnimation: Bool
    /// Resolved once: a stable URL across re-renders keeps Nuke's
    /// fetch-dedup and cache hits effective.
    private let source: EmoteImageSource

    init(emote: Emote, scale: CGFloat = 1, allowAnimation: Bool = true) {
        self.emote = emote
        self.scale = scale
        self.allowAnimation = allowAnimation
        self.source = EmoteImageSource.thirdParty(emote, animate: allowAnimation)
    }

    var body: some View {
        let box = EmoteDisplayMetrics.size(
            aspectRatio: emote.aspectRatio,
            height: EmoteDisplayMetrics.lineHeight * scale
        )
        EmoteImageView(
            url: source.url,
            isAnimated: source.isAnimated,
            width: box.width, height: box.height,
            accessibilityLabel: emote.name,
            boxSize: box,
            animate: allowAnimation
        ) { image in
            image.resizable().interpolation(.high).scaledToFit()
        } placeholder: { failed in
            // Box-sized stand-in; on failure it shows the name, shrunk to
            // fit — the name often hints at the emote.
            EmotePlaceholder(name: emote.name, failed: failed)
        }
    }
}
