import SwiftUI

/// The red "New" rule — separates messages from before the user was watching
/// (join backfill or a reconnect gap-fill) from live messages, matching the
/// Twitch-native treatment: a thin red line with a trailing "New" caption.
///
/// Pure presentation: no content, no context menu (the `.message`-only guard
/// in `ChatRow`'s menu keeps the long-press a no-op), and a single combined
/// accessibility element so VoiceOver reads one "New messages" landmark
/// instead of a meaningless 1pt rectangle. The `.isHeader` trait makes the
/// divider rotor-navigable — a VoiceOver user can jump straight to it in a
/// 500-row transcript, which is the divider's whole purpose.
struct NewMessagesDividerRow: View {
    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(.red)
                .frame(height: 1)
            Text("New")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("New messages")
        .accessibilityAddTraits(.isHeader)
    }
}
