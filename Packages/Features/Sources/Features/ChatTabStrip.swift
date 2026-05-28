import SwiftUI
import TwitchKit

/// Horizontal pill strip showing one cell per open chat channel. Active cell
/// is tinted with the accent color; both states use Liquid Glass capsules.
/// Each cell carries an X close button; the strip ends with a + button that
/// triggers `onAddTab` (AppShell wires this to "switch to Follows tab").
///
/// Liquid Glass hierarchy: pills are the glass elements. The strip itself is
/// transparent — putting `.bar`/material on the parent would nest glass on
/// glass, which the iOS 26 design guidelines explicitly call out as wrong.
///
/// The strip is hidden by ChatTabsScreen when no tabs are open — empty state
/// is the more informative UI in that case.
struct ChatTabStrip: View {
    @Bindable var model: ChatTabsModel
    let onAddTab: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.tabs) { tab in
                    TabCell(
                        tab: tab,
                        isActive: model.activeTabId == tab.id,
                        onTap: { model.activeTabId = tab.id },
                        onClose: { model.close(tabId: tab.id) }
                    )
                }

                AddTabButton(action: onAddTab)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        // No background — each pill is its own Liquid Glass element so the
        // chat content beneath subtly shows through the gaps. Nesting glass
        // inside `.bar` (the previous design) is explicitly discouraged.
    }
}

/// One pill in the tab strip. Tapping the body activates the tab; tapping
/// the X removes it. The X is rendered as a Button so VoiceOver can target
/// it independently of the cell tap.
private struct TabCell: View {
    let tab: ChatTab
    let isActive: Bool
    let onTap: () -> Void
    let onClose: () -> Void

    /// Live FollowsStore lookup. The URL captured on the ChannelDescriptor at
    /// open-time is a snapshot — if the profile wasn't yet enriched when the
    /// tab opened, that snapshot is nil and stays nil. By reading from
    /// followsStore.userProfiles dynamically, the avatar can appear once the
    /// background enrichment fetch completes, even if the URL was nil at open.
    @Environment(\.followsStore) private var followsStore

    /// Best available avatar URL: prefer FollowsStore's live cache (which
    /// updates over time as enrichment fetches complete), then fall back to
    /// the snapshot taken at tab-open time.
    private var avatarURL: URL? {
        if let userId = tab.channels.first?.channelId,
           let user = followsStore?.userProfiles[userId],
           let url = URL(string: user.profileImageUrl) {
            return url
        }
        return tab.profileImageURL
    }

    var body: some View {
        HStack(spacing: 6) {
            if let url = avatarURL {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Color.secondary.opacity(0.2)
                    }
                }
                .frame(width: 18, height: 18)
                .clipShape(Circle())
            }

            // Display name without `#` — broadcasterDisplayName is the
            // user-facing string Twitch already capitalizes correctly. The
            // `#` was an IRC affectation; on a modern mobile UI, just show
            // the name. For multi-channel tabs (future), `tab.displayName`
            // composes a friendly label like "Lirik · shroud" or "Lirik + 2".
            Text(tab.displayName)
                .font(.callout.weight(isActive ? .semibold : .regular))
                .lineLimit(1)
                .foregroundStyle(isActive ? .primary : .secondary)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(2)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Close \(tab.displayName)")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        // Liquid Glass capsule; active state gets accent tint via the
        // `.regular.tint(_:)` glass style so the material itself colors
        // rather than overlaying an opaque fill.
        .glassEffect(
            isActive ? .regular.tint(Color.accentColor) : .regular,
            in: Capsule()
        )
        // Tap anywhere on the cell (except the X) to activate. The X is a
        // separate Button so its tap consumes the gesture and doesn't bubble.
        .contentShape(Capsule())
        .onTapGesture(perform: onTap)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(tab.displayName), \(isActive ? "active" : "inactive")")
    }
}

/// Circular "+" button at the end of the strip. Visually distinct from
/// channel pills so it reads as "action," not "current tab."
private struct AddTabButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.callout.weight(.semibold))
                .frame(width: 30, height: 30)
                .glassEffect(in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add channel")
    }
}
