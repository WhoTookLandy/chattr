import SwiftUI
import Channels

/// A channel-points prediction: title and lock countdown (or Locked /
/// winner / Refunded) on one line; expanded, each outcome's share of the
/// points, pool size, predictor count and payout ratio. Read-only.
struct PredictionBannerView: View {
    let prediction: LivePrediction
    let isExpanded: Bool
    let onToggle: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        LiveEventBannerCard(
            icon: "sparkles",
            tint: .blue,
            title: prediction.title,
            isExpanded: isExpanded,
            accessibilityTitle: "Prediction: \(prediction.title)",
            onToggle: onToggle,
            onDismiss: onDismiss
        ) {
            summary
        } details: {
            details
        }
    }

    private var winner: LivePrediction.Outcome? {
        guard let id = prediction.winningOutcomeId else { return nil }
        return prediction.outcomes.first { $0.id == id }
    }

    @ViewBuilder
    private var summary: some View {
        switch prediction.status {
        case .active:
            if let locksAt = prediction.locksAt, locksAt > .now {
                LiveEventCountdown(deadline: locksAt)
            } else {
                Text(prediction.totalPoints.liveEventCompact)
            }
        case .locked:
            Label("Locked", systemImage: "lock.fill")
                .labelStyle(.titleAndIcon)
        case .resolved:
            if let winner {
                Text(winner.title)
                    .foregroundStyle(Self.color(for: winner, in: prediction))
            } else {
                Text("Resolved")
            }
        case .canceled:
            Text("Refunded")
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(prediction.outcomes) { outcome in
                let tint = Self.color(for: outcome, in: prediction)
                let fraction = prediction.fraction(of: outcome)
                let isWinner = outcome.id == prediction.winningOutcomeId
                let isLoser = prediction.status == .resolved && !isWinner
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        if isWinner {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.caption2)
                                .foregroundStyle(tint)
                        }
                        Text(outcome.title)
                            .font(.footnote.weight(isWinner ? .semibold : .regular))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(fraction.liveEventPercent)
                            .font(.footnote.weight(.semibold))
                            .monospacedDigit()
                    }
                    LiveEventShareBar(fraction: fraction, tint: tint)
                    HStack(spacing: 10) {
                        Label(outcome.points.liveEventCompact, systemImage: "circle.hexagongrid.fill")
                        Label(outcome.users.liveEventCompact, systemImage: "person.2.fill")
                        if let ratio = prediction.payoutRatio(of: outcome) {
                            Text("1:\(ratio.formatted(.number.precision(.fractionLength(0...2))))")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
                }
                .opacity(isLoser ? 0.5 : 1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("\(outcome.title), \(fraction.liveEventPercent), \(outcome.points.liveEventCompact) points, ^[\(outcome.users) predictor](inflect: true)\(isWinner ? ", winner" : "")"))
            }
            if prediction.status == .canceled {
                Text("Prediction cancelled — points refunded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Twitch's palette: two-outcome predictions are blue vs pink; with more
    /// outcomes Twitch tags them all blue, so colour by position instead.
    static func color(for outcome: LivePrediction.Outcome, in prediction: LivePrediction) -> Color {
        if prediction.outcomes.count <= 2 {
            return outcome.color == "pink" ? .pink : .blue
        }
        let palette: [Color] = [.blue, .pink, .orange, .green, .purple, .teal, .yellow, .red, .mint, .indigo]
        let index = prediction.outcomes.firstIndex { $0.id == outcome.id } ?? 0
        return palette[index % palette.count]
    }
}
