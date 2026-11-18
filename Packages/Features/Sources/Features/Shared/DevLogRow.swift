import SwiftUI
import Core

/// One row in the log list. Color-codes by severity, monospaced font for
/// scannable category/message, swipe-to-copy for sharing.
struct DevLogRow: View {
    let entry: AppLogger.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(entry.level.rawValue.uppercased())
                    .font(.caption2.weight(.bold).monospaced())
                    // Pick foreground for WCAG 4.5:1 against the severity
                    // backplate. White works on red/orange/purple/gray, but
                    // fails on yellow (WCAG ~1.7:1 in light mode) — use
                    // black for that case. This also keeps the same
                    // visual weight across all badges (severity stays
                    // bold + uppercase + monospaced).
                    .foregroundStyle(severityForeground)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(severityColor, in: RoundedRectangle(cornerRadius: 4))
                Text(entry.category)
                    .font(.caption.weight(.medium).monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(entry.date, format: .dateTime.hour().minute().second())
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Text(entry.composedMessage)
                .font(.footnote.monospaced())
                .foregroundStyle(.primary)
                .lineLimit(8)
                .multilineTextAlignment(.leading)
        }
        .contentShape(Rectangle())
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                #if canImport(UIKit)
                UIPasteboard.general.string = entry.composedMessage
                #endif
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }
    }

    private var severityColor: Color {
        switch entry.level {
        case .debug:     return .gray
        case .info:      return .secondary
        case .notice:    return .yellow
        case .warning:   return .orange
        case .error:     return .red
        case .fault:     return .purple
        case .undefined: return .gray
        }
    }

    /// Contrast-correct foreground for each severity backplate. Yellow is
    /// the outlier — WCAG 4.5:1 fails with white in light mode.
    private var severityForeground: Color {
        switch entry.level {
        case .notice: return .black
        default:      return .white
        }
    }
}
