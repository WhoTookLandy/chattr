import SwiftUI
import TwitchKit

/// One chat-message row: bold username followed by inline-rendered fragments
/// (text, Twitch emote images, @mention highlights, cheermote text).
struct ChatRow: View {
    let message: ChatMessage

    var body: some View {
        FlowLayout(spacing: 4, alignment: .firstTextBaseline) {
            // Username prefix
            Text(message.chatterUserName)
                .font(.callout.weight(.semibold))
                .foregroundStyle(color)
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

    /// Best-effort author color. Falls back to neutral when not parseable.
    private var color: Color {
        guard !message.color.isEmpty,
              let parsed = Color(hex: message.color) else {
            return .primary
        }
        return parsed
    }
}

// MARK: - Color hex helper

/// Tiny helper: Color from "#RRGGBB" string.
private extension Color {
    init?(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt64(s, radix: 16) else { return nil }
        let r = Double((v >> 16) & 0xff) / 255
        let g = Double((v >> 8) & 0xff) / 255
        let b = Double(v & 0xff) / 255
        self.init(red: r, green: g, blue: b)
    }
}
