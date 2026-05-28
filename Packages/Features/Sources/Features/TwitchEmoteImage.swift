import SwiftUI
import TwitchKit
import Core   // For Endpoints.TwitchCDN.emote(...)

// Slice-2 interlude: AsyncImage-backed. Slice-2 T16 replaces this with a
// Nuke-backed `InlineEmoteView` for animated WebP + emote prefetch.
// See docs/superpowers/specs/2026-05-24-chattr-design.md (Image / emote loading).

/// Loads and displays a single Twitch native emote from the CDN.
/// Falls back to the literal text name while loading or on failure.
struct TwitchEmoteImage: View {
    let emote: EmoteReference
    let displayName: String

    var body: some View {
        AsyncImage(url: emoteURL) { phase in
            switch phase {
            case .empty:
                Text(displayName).font(.callout).foregroundStyle(.secondary)
            case .success(let image):
                image.resizable().scaledToFit().frame(height: 24)
            case .failure:
                Text(displayName).font(.callout)
            @unknown default:
                Text(displayName).font(.callout)
            }
        }
        .accessibilityLabel(Text(displayName))
    }

    private var emoteURL: URL? {
        // Twitch CDN auto-falls-back to static when an emote has no animated
        // variant, so requesting "animated" is always safe; sticking with
        // "static" avoids the (small) extra processing for emotes we know
        // don't have animation metadata.
        let format = (emote.format ?? []).contains("animated") ? "animated" : "static"
        return Endpoints.TwitchCDN.emote(id: emote.id, format: format)
    }
}
