import SwiftUI
import TwitchKit
import DesignSystem

/// One chat-message row: badges → bold username → inline-rendered fragments
/// (text, Twitch emote images, @mention highlights, cheermote text).
///
/// Username color is HSL-lightness-clamped per color scheme — see
/// `Color.twitchUsername(hex:scheme:)` in DesignSystem. Twitch's user-picked
/// colors are tuned for dark UIs; without clamping, bright yellows / pale
/// pastels are unreadable on light backgrounds.
///
/// Badges are resolved by the parent (`ChatScreen` owns the `ChatBadgeStore`)
/// and passed in as already-looked-up `BadgeEntry`s — keeps `ChatRow` purely
/// presentational and avoids re-doing the dictionary lookup on every body
/// recomputation.
struct ChatRow: View {
    let message: ChatMessage
    let badgeEntries: [ChatBadgeEntry]

    /// Read once per row so the username color recomputes when the user toggles
    /// theme in Settings. (Environment changes trigger a re-render.)
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        FlowLayout(spacing: 4, alignment: .firstTextBaseline) {
            // Badges (zero or more — broadcasters typically have 1, partners 2-3,
            // moderators 1, regular subscribers 1, etc.)
            ForEach(Array(badgeEntries.enumerated()), id: \.offset) { _, entry in
                BadgeImage(entry: entry)
            }
            // Username prefix
            Text(message.chatterUserName)
                .font(.callout.weight(.semibold))
                .foregroundStyle(usernameColor)
            Text(":")
                .foregroundStyle(.secondary)

            // Walk message fragments
            ForEach(Array(message.message.fragments.enumerated()), id: \.offset) { _, fragment in
                fragmentView(for: fragment)
            }
        }
    }

    @ViewBuilder
    private func fragmentView(for fragment: ChatFragment) -> some View {
        switch fragment.type {
        case .emote:
            if let emoteRef = fragment.emote {
                TwitchEmoteImage(emote: emoteRef, displayName: fragment.text)
            } else {
                Text(fragment.text).font(.callout)
            }
        case .mention:
            Text(fragment.text)
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.accentColor)
        case .text, .cheermote:
            // Cheermotes render as text for slice-2 interlude; full bits rendering is a later slice.
            Text(fragment.text).font(.callout)
        case .unknown:
            Text(fragment.text).font(.callout)
        }
    }

    /// Per-row username color. Empty `message.color` (user hasn't picked one)
    /// falls back to `.primary` so the system handles light/dark automatically.
    private var usernameColor: Color {
        guard !message.color.isEmpty else { return .primary }
        return .twitchUsername(hex: message.color, scheme: colorScheme)
    }
}

// MARK: - Badge rendering

/// 18pt-square inline badge image. Failed/loading badges collapse to nothing
/// (`Color.clear` at zero size) rather than showing a placeholder — chat rows
/// look cleaner without a stand-in icon, and the username + message still
/// render correctly while images load.
///
/// `interpolation(.high)` is important: badges are bitmaps being downsampled
/// from 72px (source 4x) to 54px physical pixels on @3x devices. Without
/// high-quality interpolation, edges look jagged on small icons.
private struct BadgeImage: View {
    let entry: ChatBadgeEntry

    var body: some View {
        AsyncImage(url: entry.url) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            case .empty, .failure:
                // Don't reserve space — let layout flow as if the badge weren't there.
                Color.clear.frame(width: 0, height: 0)
            @unknown default:
                Color.clear.frame(width: 0, height: 0)
            }
        }
        .frame(width: 18, height: 18)
        .accessibilityLabel(entry.title ?? "Chat badge")
    }
}
