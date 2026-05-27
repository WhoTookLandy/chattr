import SwiftUI
import TwitchKit
import DesignSystem

/// One chat-message row: bold username followed by inline-rendered fragments
/// (text, Twitch emote images, @mention highlights, cheermote text).
///
/// Username color is HSL-lightness-clamped per color scheme — see
/// `Color.twitchUsername(hex:scheme:)` in DesignSystem. Twitch's user-picked
/// colors are tuned for dark UIs; without clamping, bright yellows / pale
/// pastels are unreadable on light backgrounds.
struct ChatRow: View {
    let message: ChatMessage

    /// Read once per row so the username color recomputes when the user toggles
    /// theme in Settings. (Environment changes trigger a re-render.)
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        FlowLayout(spacing: 4, alignment: .firstTextBaseline) {
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
