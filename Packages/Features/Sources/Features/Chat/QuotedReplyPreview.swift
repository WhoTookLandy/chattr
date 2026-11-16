import SwiftUI
import ChatModel

/// The quoted-parent line above a reply in `ChatRow`: reply arrow, parent
/// author, truncated parent body — ONE line, because vertical space is the
/// scarcest resource in a fast chat; the quote is a glanceable hint, and the
/// full context is one tap away.
///
/// The whole line is a button that opens the thread sheet — the same action
/// as the long-press "View Thread" item, but discoverable. Read-only
/// contexts (the thread sheet, previews) pass `onViewThread == nil`, which
/// disables the tap without changing the visual.
struct QuotedReplyPreview: View {
    let reply: ChatLine.ReplyParent
    let onViewThread: (() -> Void)?

    var body: some View {
        Button {
            onViewThread?()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(reply.parentAuthorDisplayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(reply.parentBody)
                    .font(.caption)
                    // `.secondary`, not `.tertiary`: this is real content the
                    // reader needs (what's being replied to), and `.tertiary`
                    // at caption size commonly fails WCAG AA's 4.5:1 contrast.
                    // `.tertiary` stays reserved for decoration (the arrow).
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .buttonStyle(.plain)
        .disabled(onViewThread == nil)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Replying to \(reply.parentAuthorDisplayName): \(reply.parentBody)")
        .accessibilityHint(onViewThread == nil ? "" : "Opens the thread")
    }
}
