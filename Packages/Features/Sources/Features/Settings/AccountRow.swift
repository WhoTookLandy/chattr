import SwiftUI
import Accounts
import NukeUI

/// A signed-in account presented as avatar + display name + @login.
///
/// Two presentations share one layout:
/// - `.banner` — the large hero row at the top of `ProfileScreen`, padded to
///   read as a visual identity anchor rather than a settings row.
/// - `.listRow` — a selectable row in `AccountSwitcherView`, which adds an
///   active checkmark, a session-expired affordance, and combined VoiceOver.
struct AccountRow: View {
    enum Style { case banner, listRow }

    let account: Account
    /// Only consulted by `.listRow` (drives the checkmark). Ignored by `.banner`.
    var isActive: Bool = false
    let style: Style

    private var avatarSize: CGFloat { style == .banner ? 64 : 40 }
    private var rowSpacing: CGFloat { style == .banner ? 14 : 12 }
    private var nameFont: Font { style == .banner ? .title3.weight(.semibold) : .body.weight(.medium) }
    private var subtitleFont: Font { style == .banner ? .subheadline : .caption }

    var body: some View {
        let row = HStack(spacing: rowSpacing) {
            avatar

            VStack(alignment: .leading, spacing: style == .banner ? 2 : 1) {
                Text(account.displayName)
                    .font(nameFont)
                    .foregroundStyle(.primary)
                    .lineLimit(style == .banner ? 1 : nil)
                subtitle
            }

            Spacer()

            trailingIndicator
        }

        switch style {
        case .banner:
            row
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
        case .listRow:
            row
                .contentShape(Rectangle())
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    account.needsReauth
                        ? "\(account.displayName), session expired, tap to re-authorize"
                        : "\(account.displayName)\(isActive ? ", active" : "")"
                )
        }
    }

    private var avatar: some View {
        LazyImage(url: URL(string: account.profileImageURL)) { state in
            if let image = state.image {
                image.resizable().scaledToFill()
            } else {
                // Placeholder while loading or when the URL is nil (first
                // sign-in before the profile fetch completes).
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary.opacity(0.5))
            }
        }
        .frame(width: avatarSize, height: avatarSize)
        .clipShape(Circle())
    }

    @ViewBuilder
    private var subtitle: some View {
        if style == .listRow, account.needsReauth {
            // Orange + clock, matching SignInView's banner tone — a routine
            // session timeout, not a security incident.
            Text("Session expired — tap to re-authorize")
                .font(subtitleFont)
                .foregroundStyle(.orange)
        } else {
            Text("@\(account.login)")
                .font(subtitleFont)
                .foregroundStyle(.secondary)
                .lineLimit(style == .banner ? 1 : nil)
        }
    }

    @ViewBuilder
    private var trailingIndicator: some View {
        if style == .listRow {
            if account.needsReauth {
                Image(systemName: "clock.badge.exclamationmark")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.orange)
            } else if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.accentColor)
            }
        }
    }
}
