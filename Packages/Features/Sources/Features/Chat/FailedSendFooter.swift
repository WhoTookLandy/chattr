import SwiftUI

/// Footer under a `.failed` message row: the drop reason from Twitch (or the
/// network error), and the whole strip is one tap target that retries.
///
/// Design choices:
///   - `exclamationmark.triangle.fill` with hierarchical rendering in `.red`
///     reads as "error" at any size without a filled background.
///   - "Tap to retry" as one strip → a bigger hit area and less clutter than
///     a separate 44pt icon button next to the row.
///   - With no `onRetry` (read-only contexts) the strip keeps its look but
///     drops the Retry affordance and the tap.
struct FailedSendFooter: View {
    let reason: String
    let onRetry: (() -> Void)?

    var body: some View {
        Button {
            onRetry?()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.red)
                    .imageScale(.small)
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.red)
                Spacer(minLength: 4)
                if onRetry != nil {
                    Image(systemName: "arrow.clockwise")
                        .imageScale(.small)
                        .foregroundStyle(.red)
                    Text("Retry")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.red.opacity(0.10))
            )
        }
        .buttonStyle(.plain)
        .disabled(onRetry == nil)
        .accessibilityLabel("Failed to send: \(reason). Tap to retry.")
    }
}
