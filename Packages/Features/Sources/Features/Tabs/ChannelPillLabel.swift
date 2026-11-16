import SwiftUI

/// The channel-pill *label*: the visible tab's name, a chevron, an
/// unseen-mention dot, and (with 2+ tabs) miniature page dots.
///
/// Extracted from `ChatTabsScreen` into its own `View` purely for
/// invalidation isolation. The pill reads `chatTabs.mentionedTabIds`, which
/// changes whenever a ping lands in a *background* tab; left inline in
/// `ChatTabsScreen.body` that read made every mention re-evaluate the whole
/// screen body, including the paged `ScrollView` of `ChatScreen`s. As its own
/// view the mention dependency is scoped here, so a background ping redraws
/// the dot without touching the pager. (`ChatScreen` pages are protected by
/// their own identity regardless; this avoids the wasted container rebuild.)
struct ChannelPillLabel: View {
    let chatTabs: ChatTabsModel

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            // Unseen mention in a BACKGROUND tab: dot the pill so the ping is
            // visible from inside another chat.
            .overlay(alignment: .topTrailing) {
                if hasBackgroundMention {
                    Circle()
                        .fill(.red)
                        .frame(width: 7, height: 7)
                        .offset(x: 10, y: -3)
                        .accessibilityLabel("Unread mention in another chat")
                }
            }
            pageDots
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        // The pill's own glass — `.interactive()` so it responds to the
        // press like the standalone control it looks like.
        .glassEffect(.regular.interactive(), in: Capsule())
    }

    /// Display name of the *visible* tab — `activeTabId`, falling back to
    /// `tabs.first` before scene restoration runs (matching the pager). "Chat"
    /// only when no tabs are open.
    private var title: String {
        guard let visibleId = chatTabs.activeTabId ?? chatTabs.tabs.first?.id,
              let tab = chatTabs.tabs.first(where: { $0.id == visibleId })
        else { return "Chat" }
        return tab.displayName
    }

    /// True when any non-active tab holds an unseen mention.
    private var hasBackgroundMention: Bool {
        !chatTabs.mentionedTabIds.subtracting([chatTabs.activeTabId].compactMap { $0 }).isEmpty
    }

    /// Miniature page dots — one per open tab, active highlighted, mention
    /// dots red. Rendered only with 2+ tabs; with a single tab the pill is
    /// just the name (nothing to switch between).
    @ViewBuilder
    private var pageDots: some View {
        if chatTabs.tabs.count > 1 {
            HStack(spacing: 4) {
                // Resolve the same way the title does: the pager shows
                // `tabs.first` when `activeTabId` is still nil, so highlight
                // that dot rather than leaving all of them dim.
                let visibleId = chatTabs.activeTabId ?? chatTabs.tabs.first?.id
                ForEach(chatTabs.tabs) { tab in
                    // Mention beats position: a red dot says "that page
                    // pinged you," which matters more than which page it is.
                    Circle()
                        .fill(chatTabs.mentionedTabIds.contains(tab.id)
                            ? AnyShapeStyle(.red)
                            : tab.id == visibleId
                                ? AnyShapeStyle(.tint)
                                : AnyShapeStyle(.secondary.opacity(0.35)))
                        .frame(width: 5, height: 5)
                }
            }
            .accessibilityHidden(true)
        }
    }
}
