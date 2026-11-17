import SwiftUI
import ChatModel

/// The quoted line above a reply: "@author message…" on one line, small and
/// secondary, sitting on the `ReplyElbow` connector (see `ChatRow`). Tap
/// opens the thread.
struct QuotedReplyPreview: View {
    let reply: ChatLine.ReplyParent
    let onViewThread: (() -> Void)?

    var body: some View {
        Button {
            onViewThread?()
        } label: {
            Text("\(Text("@\(reply.parentAuthorDisplayName) ").fontWeight(.semibold))\(reply.parentBody)")
                .font(.caption)
                // `.secondary`, not `.tertiary`: real content the reader
                // needs, and `.tertiary` at caption size fails WCAG AA.
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .buttonStyle(.plain)
        .disabled(onViewThread == nil)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Replying to \(reply.parentAuthorDisplayName): \(reply.parentBody)")
        .accessibilityHint(onViewThread == nil ? "" : "Opens the thread")
    }
}

/// ╭── — the connector from a reply up to the message it quotes.
struct ReplyElbow: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = min(rect.height, 6)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + radius, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}
