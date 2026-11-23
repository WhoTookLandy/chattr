import SwiftUI
import ChatModel

/// Twitch `/announce` chat card — tinted surface, leading accent bar matching
/// Twitch's announcement color (`PRIMARY` / `BLUE` / `GREEN` / `ORANGE` /
/// `PURPLE`), compact megaphone header, and a content slot that renders the
/// sender's badges, username, and emote/link-tokenized runs inline.
struct AnnouncementBubbleRow<Content: View>: View {
    let bubble: ChatLine.AnnouncementBubble
    let timestamp: Date
    let timestampFormat: Date.VerbatimFormatStyle
    let showTimestamp: Bool
    @ViewBuilder var content: () -> Content

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "megaphone.fill")
                    .font(.caption.weight(.semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(accentColor)
                    .accessibilityHidden(true)

                Text("Announcement")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accentColor)

                if showTimestamp {
                    Spacer(minLength: 4)
                    Text(timestamp, format: timestampFormat)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            content()
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accentColor.opacity(colorScheme == .dark ? 0.13 : 0.08))
        .overlay(alignment: .leading) {
            accentBar
                .frame(width: 3.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    accentColor.opacity(colorScheme == .dark ? 0.26 : 0.18),
                    lineWidth: 0.5
                )
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var accentBar: some View {
        switch bubble.color {
        case .primary:
            // Twitch's signature PRIMARY announcement gradient.
            LinearGradient(
                colors: [
                    Color(red: 0.57, green: 0.27, blue: 1.0),
                    Color(red: 0.0, green: 0.68, blue: 1.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        case .blue, .green, .orange, .purple:
            accentColor
        }
    }

    private var accentColor: Color {
        switch bubble.color {
        case .primary, .purple:
            Color(red: 0.62, green: 0.36, blue: 1.0)
        case .blue:
            Color(red: 0.08, green: 0.58, blue: 1.0)
        case .green:
            Color(red: 0.0, green: 0.76, blue: 0.48)
        case .orange:
            Color(red: 1.0, green: 0.56, blue: 0.08)
        }
    }
}
