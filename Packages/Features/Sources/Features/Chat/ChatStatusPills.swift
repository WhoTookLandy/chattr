import SwiftUI

// MARK: - Transcript accessory views
//
// Separate `View` structs (not computed properties on ChatTranscript) on
// purpose: ChatTranscript's body re-evaluates at chat-message rate, and a
// computed property is inlined into that same invalidation boundary — its
// builder would re-run per message. A struct with narrow inputs only
// re-runs its body when those inputs actually change.

/// Empty-state placeholder. Two flavors driven by the model's attach state:
///   - `.detached` / `.attaching` → "Connecting to chat…" with a spinner
///     (the model's `attach(sessions:)` is in flight — that includes
///     registry.session() which subscribes to EventSub).
///   - `.attached` → "Connected — waiting for messages" (everything's
///     wired, the channel just hasn't had a chat message yet).
struct EmptyOrConnectingState: View {
    let isAttached: Bool
    let channelLoginName: String

    var body: some View {
        VStack(spacing: 12) {
            if !isAttached {
                ProgressView()
                Text("Connecting to chat…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.largeTitle)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                Text("Connected to #\(channelLoginName)")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                Text("Waiting for messages…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Transient connection indicator. "Reconnecting…" while the socket is down,
/// a brief "Live again" on recovery, hidden otherwise. Same quiet glass
/// capsule as the jump-to-latest pill.
struct ConnectionPill: View {
    let banner: ConnectionBanner

    var body: some View {
        if banner != .hidden {
            HStack(spacing: 4) {
                Image(systemName: banner == .liveAgain ? "checkmark" : "wifi.exclamationmark")
                    .font(.caption2.weight(.semibold))
                Text(banner == .liveAgain ? "Live again" : "Reconnecting…")
                    .font(.caption2.weight(.medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .glassEffect(.regular, in: Capsule())
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityLabel(banner == .liveAgain ? "Connection restored" : "Reconnecting")
        }
    }
}

/// Brief "Reported & blocked" confirmation pill. Appears after the user
/// reports a message and auto-dismisses after ~2s. Same quiet glass
/// capsule as the connection pill — reads as a transient status, not
/// a call-to-action.
struct ReportConfirmationPill: View {
    let isShown: Bool

    var body: some View {
        if isShown {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.shield").font(.caption2.weight(.semibold))
                Text("Reported & blocked").font(.caption2.weight(.medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .glassEffect(.regular, in: Capsule())
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// Floating "jump to latest" pill. Two moods: with unread messages it's
/// a proper call-to-action — footnote-weight primary text on a roomier
/// glass capsule, sized like Twitch's native "N new messages" chip —
/// because at caption2/5pt it read as an ignorable speck. Caught up,
/// it relaxes back to a quiet secondary "Latest" hint.
///
/// Explicit `Equatable` ignoring `action`: the closure is rebuilt on every
/// parent body pass (and closures can't be compared), which would otherwise
/// force a re-render per message while the pill is visible. `unreadCount`
/// is the only render-affecting input — same rationale as ChatRow's
/// conformance. Safe to keep a stale `action`: it only bumps parent
/// @State / reads the @Observable model, both reference-backed.
struct JumpToBottomPill: View, Equatable {
    let unreadCount: Int
    let action: () -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.unreadCount == rhs.unreadCount
    }

    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down")
                    .font(.footnote.weight(.semibold))
                if unreadCount > 0 {
                    // Apple's inflection markdown pluralizes "message"
                    // automatically (1 message / 2 messages).
                    Text("^[\(unreadCount) new message](inflect: true)")
                        .font(.footnote.weight(.semibold))
                } else {
                    Text("Latest")
                        .font(.footnote.weight(.medium))
                }
            }
            .foregroundStyle(unreadCount > 0 ? Color.primary : Color.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            // `.interactive()` so the glass responds to the press —
            // it's a button now, not a status pill.
            .glassEffect(.regular.interactive(), in: Capsule())
            // A `.plain` button only hit-tests the label's drawn pixels
            // (glyph + text), not the padding or the glass behind them —
            // so a tap on the pill's edge fell through to the chat row
            // underneath (TestFlight: "clicking Latest ends up tapping the
            // username below it"). Claim the whole capsule.
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            unreadCount > 0
                ? "Jump to latest, \(unreadCount) new messages"
                : "Jump to latest"
        )
    }
}
