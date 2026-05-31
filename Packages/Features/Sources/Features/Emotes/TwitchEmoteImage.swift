import SwiftUI
import TwitchKit
import Core      // For Endpoints.TwitchCDN.emote(...)
import NukeUI

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

    init(emote: EmoteReference, displayName: String) {
        self.emote = emote
        self.displayName = displayName
        // Twitch CDN auto-falls-back to static when an emote has no animated
        // variant, so requesting "animated" is always safe; sticking with
        // "static" avoids the (small) extra processing for emotes we know
        // don't have animation metadata.
        let animated = (emote.format ?? []).contains("animated")
        self.isAnimated = animated
        self.emoteURL = Endpoints.TwitchCDN.emote(id: emote.id, format: animated ? "animated" : "static")
    }

    var body: some View {
        Group {
            if isAnimated {
                AnimatedImageView(url: emoteURL, width: 28, height: 24) {
                    Text(displayName).font(.callout).foregroundStyle(.secondary)
                }
            } else {
                LazyImage(url: emoteURL) { state in
                    if let image = state.image {
                        image.resizable().scaledToFit().frame(height: 24)
                    } else if state.isLoading {
                        Text(displayName).font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text(displayName).font(.callout)
                    }
                }
            }
        }
        .accessibilityLabel(Text(displayName))
    }
}
