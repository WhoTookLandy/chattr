import SwiftUI

/// The channel-pill *label*: the visible tab's name, a chevron, an
/// unseen-mention dot, and (with 2+ tabs) miniature page dots.
///
/// Extracted from `ChatPagerScreen` into its own `View` purely for
/// invalidation isolation. The pill reads `chatTabs.mentionedTabIds`, which
/// changes whenever a ping lands in a *background* tab; left inline in
/// `ChatPagerScreen.body` that read made every mention re-evaluate the whole
/// screen body, including the paged `ScrollView` of `ChatScreen`s. As its own
/// view the mention dependency is scoped here, so a background ping redraws
/// the dot without touching the pager. (`ChatScreen` pages are protected by
/// their own identity regardless; this avoids the wasted container rebuild.)
struct ChannelPillLabel: View {
    let chatTabs: ChatTabsModel?

    @Environment(\.followsStore) private var followsStore
    @Environment(\.channelStatus) private var channelStatus
    #if os(iOS)
    @Environment(\.playback) private var playback
    @AppStorage(StreamHeaderView.expandedKey) private var isExpanded = false
    @AppStorage(PlayerSettings.audioOnlyKey) private var audioOnly = false
    #endif

    /// Viewer count when the visible channel is live; nil when offline or
    /// unknown. Read here (not in ChatPagerScreen) for the same isolation
    /// reason as the mention dot.
    private var liveViewers: Int? {
        guard let channelId = chatTabs?.visibleChannelId else { return nil }
        return ChannelStatusStore.liveStream(for: channelId, status: channelStatus, follows: followsStore)?.viewerCount
    }

    #if os(iOS)
    /// Audio-only / PiP: the header has collapsed, so the pill carries the
    /// mode as a glyph next to the viewer count.
    private var condensedMode: CondensedStreamMode? {
        CondensedStreamMode.resolve(
            channelId: chatTabs?.visibleChannelId,
            isLive: liveViewers != nil,
            isExpanded: isExpanded,
            audioOnly: audioOnly,
            playback: playback
        )
    }
    #endif

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                // "soochu ● 41" — live state at a glance, Twitch-style.
                if let liveViewers {
                    HStack(spacing: 3) {
                        Circle().fill(.red).frame(width: 6, height: 6)
                        Text(StreamFormatting.viewers(liveViewers))
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Live, \(liveViewers) viewers")
                }
                #if os(iOS)
                if let condensedMode {
                    Image(systemName: condensedMode.systemImage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                        .transition(.opacity.combined(with: .scale(scale: 0.6)))
                        .accessibilityLabel(condensedMode.accessibilityLabel)
                }
                #endif
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
        #if os(iOS)
        .animation(.snappy(duration: 0.25), value: condensedMode)
        #endif
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
        guard let chatTabs,
              let visibleId = chatTabs.activeTabId ?? chatTabs.tabs.first?.id,
              let tab = chatTabs.tabs.first(where: { $0.id == visibleId })
        else { return "Chat" }
        return tab.displayName
    }

    /// True when any non-active tab holds an unseen mention.
    private var hasBackgroundMention: Bool {
        guard let chatTabs else { return false }
        return !chatTabs.mentionedTabIds.subtracting([chatTabs.activeTabId].compactMap { $0 }).isEmpty
    }

    /// Miniature page dots — one per open tab, active highlighted, mention
    /// dots red. Rendered only with 2+ tabs; with a single tab the pill is
    /// just the name (nothing to switch between).
    @ViewBuilder
    private var pageDots: some View {
        if let chatTabs, chatTabs.tabs.count > 1 {
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
