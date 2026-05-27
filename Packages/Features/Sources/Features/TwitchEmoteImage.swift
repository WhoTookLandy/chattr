import SwiftUI
import TwitchKit

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
        let format = (emote.format ?? []).contains("animated") ? "animated" : "static"
        return URL(string: "https://static-cdn.jtvnw.net/emoticons/v2/\(emote.id)/\(format)/dark/2.0")
    }
}
