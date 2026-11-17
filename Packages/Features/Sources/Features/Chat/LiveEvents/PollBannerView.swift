import SwiftUI
import Channels

/// A running (or just-finished) poll: title and countdown on one line;
/// expanded, every choice with a live percentage bar. Read-only — voting
/// would need Twitch's undocumented web endpoints.
struct PollBannerView: View {
    let poll: LivePoll
    let isExpanded: Bool
    let onToggle: () -> Void
    let onDismiss: () -> Void

    private static let tint = Color.purple

    var body: some View {
        LiveEventBannerCard(
            icon: "chart.bar.fill",
            tint: Self.tint,
            title: poll.title,
            isExpanded: isExpanded,
            accessibilityTitle: "Poll: \(poll.title)",
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
        switch poll.status {
        case .active:
            if let endsAt = poll.endsAt, endsAt > .now {
                LiveEventCountdown(deadline: endsAt)
            } else {
                Text("^[\(poll.totalVotes) vote](inflect: true)")
            }
        case .completed, .archived:
            Text("Final results")
        case .terminated:
            Text("Ended early")
        }
    }

    private var details: some View {
        let leaders = poll.leadingChoiceIds
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(poll.choices) { choice in
                let isLeader = leaders.contains(choice.id)
                let fraction = poll.fraction(of: choice)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        if isLeader, poll.status.isConcluded {
                            Image(systemName: "crown.fill")
                                .font(.caption2)
                                .foregroundStyle(.yellow)
                        }
                        Text(choice.title)
                            .font(.footnote.weight(isLeader ? .semibold : .regular))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(fraction.liveEventPercent)
                            .font(.footnote.weight(.semibold))
                            .monospacedDigit()
                    }
                    LiveEventShareBar(
                        fraction: fraction,
                        tint: isLeader ? Self.tint : Self.tint.opacity(0.45)
                    )
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("\(choice.title), \(fraction.liveEventPercent), ^[\(choice.votes) vote](inflect: true)"))
            }
            Text("^[\(poll.totalVotes) vote](inflect: true)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
