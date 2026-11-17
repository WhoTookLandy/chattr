import SwiftUI
import Channels

/// A slim notice at the top of chat when the signed-in user is timed out,
/// banned or warned in this channel — with a live countdown for a timeout of
/// known length.
///
/// Self-contained: it reads only `OwnChatRestrictionState` (so nothing else
/// re-renders when it changes) and renders nothing at all when there's no
/// restriction, so it can share the top safe-area bar with other banners.
/// The countdown is a self-updating `Text(timerInterval:)` — no per-second
/// body re-evaluation.
struct OwnChatRestrictionBanner: View {
    let state: OwnChatRestrictionState
    let channelLoginName: String

    @Environment(\.openURL) private var openURL

    var body: some View {
        // The VStack is the animation anchor (and is zero-size when empty),
        // so the banner slides in/out without the parent having to read
        // `state` — which would subscribe the whole chat screen to it.
        VStack(spacing: 0) {
            if let restriction = state.current {
                content(for: restriction)
            }
        }
        .animation(.snappy(duration: 0.25), value: state.current)
    }

    private func content(for restriction: OwnChatRestriction) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: Self.symbol(for: restriction))
                .font(.body.weight(.semibold))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            message(for: restriction)
                .font(.footnote)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            trailingControl(for: restriction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.14), in: .rect(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    @ViewBuilder
    private func message(for restriction: OwnChatRestriction) -> some View {
        switch restriction {
        case .timedOut(let until?) where until > .now:
            Text("You're timed out here. You can chat again in \(Text(timerInterval: Date.now...until, countsDown: true).monospacedDigit().bold()).")
        case .timedOut:
            Text("You're timed out in this chat.")
        case .banned:
            Text("You're banned from this chat.")
        case .warned(let reason):
            if let reason, !reason.isEmpty {
                Text("A moderator warned you: \(reason). Acknowledge it on Twitch to chat again.")
            } else {
                Text("A moderator warned you. Acknowledge the warning on Twitch to chat again.")
            }
        case .removedByModerator:
            Text("A moderator removed your messages. You may be timed out or banned.")
        }
    }

    @ViewBuilder
    private func trailingControl(for restriction: OwnChatRestriction) -> some View {
        switch restriction {
        case .warned:
            Button("Open") {
                if let url = URL(string: "https://www.twitch.tv/\(channelLoginName)") {
                    openURL(url)
                }
            }
            .font(.footnote.weight(.semibold))
            .buttonStyle(.borderless)
        case .timedOut(let until?) where until > .now:
            // Ends on its own; nothing to dismiss.
            EmptyView()
        default:
            // Twitch never tells us when a ban is lifted or a warning
            // acknowledged elsewhere — let the user clear the notice.
            Button {
                withAnimation(.snappy(duration: 0.2)) { state.dismiss() }
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(-8)
            .accessibilityLabel("Dismiss")
        }
    }

    private static func symbol(for restriction: OwnChatRestriction) -> String {
        switch restriction {
        case .timedOut: return "clock.badge.exclamationmark"
        case .banned: return "nosign"
        case .warned: return "exclamationmark.triangle.fill"
        case .removedByModerator: return "eye.slash"
        }
    }
}
