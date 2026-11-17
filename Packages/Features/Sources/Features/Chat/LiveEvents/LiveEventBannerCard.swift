import SwiftUI

/// The shared chrome of a live-event banner: a glass card whose first line
/// (icon, title, trailing summary) is always visible, and whose details
/// unfold below it when expanded. Tapping anywhere toggles; the close button
/// (expanded only) hides the event.
///
/// Collapsed it is one line tall, so a running poll or train costs a single
/// row of chat at most — and `LiveEventsModel` folds every expansion back
/// after a few seconds.
struct LiveEventBannerCard<Summary: View, Details: View>: View {
    let icon: String
    let tint: Color
    let title: String
    let isExpanded: Bool
    /// Spoken label for the whole collapsed card, e.g. "Poll: Best map?".
    let accessibilityTitle: String
    let onToggle: () -> Void
    let onDismiss: () -> Void
    let summary: Summary
    let details: Details

    init(
        icon: String,
        tint: Color,
        title: String,
        isExpanded: Bool,
        accessibilityTitle: String,
        onToggle: @escaping () -> Void,
        onDismiss: @escaping () -> Void,
        @ViewBuilder summary: () -> Summary,
        @ViewBuilder details: () -> Details
    ) {
        self.icon = icon
        self.tint = tint
        self.title = title
        self.isExpanded = isExpanded
        self.accessibilityTitle = accessibilityTitle
        self.onToggle = onToggle
        self.onDismiss = onDismiss
        self.summary = summary()
        self.details = details()
    }

    private static var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(isExpanded ? 3 : 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                summary
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if isExpanded {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Hide")
                } else {
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            if isExpanded {
                details
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: Self.shape)
        .contentShape(Self.shape)
        .onTapGesture(perform: onToggle)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: isExpanded ? "Collapse" : "Expand", onToggle)
    }
}

/// A horizontal share bar (vote / point percentage, level progress).
struct LiveEventShareBar: View {
    /// 0…1; clamped.
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(tint)
                    .frame(width: proxy.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

/// "1:23" until `deadline`, ticking once a second — and only while it is on
/// screen: each visible banner owns its own `TimelineView`, so there is no
/// shared timer and nothing runs when no countdown is shown.
struct LiveEventCountdown: View {
    let deadline: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Self.format(deadline.timeIntervalSince(context.date)))
                .monospacedDigit()
        }
    }

    /// Whole seconds, rounded up so "0:00" appears only at the deadline.
    static func format(_ remaining: TimeInterval) -> String {
        let seconds = max(0, Int(remaining.rounded(.up)))
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

extension Double {
    /// "42%" for a 0…1 share.
    var liveEventPercent: String {
        formatted(.percent.precision(.fractionLength(0)))
    }
}

extension Int {
    /// "12.3K" for points / totals.
    var liveEventCompact: String {
        formatted(.number.notation(.compactName))
    }
}
