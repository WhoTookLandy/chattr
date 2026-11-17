import SwiftUI
import Channels

/// A Hype Train: level and time left on one line; expanded, progress
/// through the current level and the running total. Shows the final level
/// briefly when the train ends.
struct HypeTrainBannerView: View {
    let train: LiveHypeTrain
    let isExpanded: Bool
    let onToggle: () -> Void
    let onDismiss: () -> Void

    private var tint: Color { train.isGoldenKappa ? .yellow : .orange }

    private var title: String {
        let name = train.isGoldenKappa ? "Golden Kappa Train" : "Hype Train"
        return train.status == .ended
            ? "\(name) ended at Level \(train.level)"
            : "\(name) · Level \(train.level)"
    }

    var body: some View {
        LiveEventBannerCard(
            icon: "train.side.front.car",
            tint: tint,
            title: title,
            isExpanded: isExpanded,
            accessibilityTitle: title,
            onToggle: onToggle,
            onDismiss: onDismiss
        ) {
            summary
        } details: {
            details
        }
    }

    @ViewBuilder
    private var summary: some View {
        if train.status == .active {
            HStack(spacing: 6) {
                if let fraction = train.levelFraction {
                    Text(fraction.liveEventPercent)
                        .monospacedDigit()
                }
                if let expiresAt = train.expiresAt, expiresAt > .now {
                    LiveEventCountdown(deadline: expiresAt)
                }
            }
        } else if let total = train.total {
            Text(total.liveEventCompact)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let fraction = train.levelFraction {
                LiveEventShareBar(fraction: fraction, tint: tint)
                if let progress = train.progress, let goal = train.goal {
                    HStack {
                        Text("Level \(train.level) progress")
                        Spacer(minLength: 8)
                        Text("\(progress.liveEventCompact) / \(goal.liveEventCompact)")
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            if let total = train.total {
                Text("\(total.liveEventCompact) points contributed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
