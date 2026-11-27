import SwiftUI
import TwitchKit
import DesignSystem

/// The Chats tab's list: open chats, Messages-style, in **Live** and
/// **Offline** sections (live busiest first, offline in open order). Each
/// row (`OpenChatRow`) carries live ring / viewers / category / uptime /
/// title or offline + last live, and a red dot for an unseen @-mention.
///
/// Tap → push the chat. Swipe left → Close. Long-press → preview card with
/// Open / Watch / Audio only / Close (`channelPreviewMenu`).
struct OpenChatsList: View {
    /// The empty state's CTA — switches to Home → Live.
    let onShowLive: () -> Void
    /// Split layout: the chat sits beside this list, so the row on screen
    /// is marked as selected.
    var highlightsActiveChat: Bool = false

    @Environment(\.chatTabs) private var chatTabs
    @Environment(\.channelStatus) private var channelStatus
    @Environment(\.followsStore) private var followsStore
    #if os(iOS)
    @Environment(\.playback) private var playback
    #endif

    var body: some View {
        if let chatTabs, !chatTabs.tabs.isEmpty {
            let split = sections(chatTabs)
            List {
                if !split.live.isEmpty {
                    Section {
                        ListSectionTitle("Live")
                        rows(split.live, chatTabs: chatTabs)
                    }
                }
                if !split.offline.isEmpty {
                    Section {
                        ListSectionTitle("Offline")
                        rows(split.offline, chatTabs: chatTabs)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        } else {
            ContentUnavailableView {
                Label("No chats open", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("Pick a live channel to start chatting.")
            } actions: {
                Button("See who's live", action: onShowLive)
                    .buttonStyle(.borderedProminent)
                    .tint(.accentColor)
            }
        }
    }

    private func rows(_ tabs: [ChatTab], chatTabs: ChatTabsModel) -> some View {
        ForEach(tabs) { tab in
            let stream = liveStream(tab)
            Button {
                // Already on screen beside the list: nothing to open, and
                // re-running the open policy would reset its video.
                guard !(chatTabs.isPresented && chatTabs.activeTabId == tab.id) else { return }
                // `present` runs the "When a Chat Opens" policy even when a
                // chat is already presented — the split layout's case, where
                // tapping another row swaps chats without leaving the pager.
                chatTabs.present(tabId: tab.id)
            } label: {
                OpenChatRow(tab: tab, chatTabs: chatTabs)
            }
            .buttonStyle(.plain)
            .modifier(ActiveChatRowSelection(tabId: tab.id, chatTabs: chatTabs, isEnabled: highlightsActiveChat))
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) {
                    chatTabs.close(tabId: tab.id)
                } label: {
                    Label("Close", systemImage: "xmark")
                }
            }
            #if os(iOS)
            .retainsPinnedAudioFlag(for: tab.channels.first?.channelId ?? "", in: tab.channels.first != nil ? playback : nil)
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if let channel = tab.channels.first,
                   let playback,
                   PlayerSettings.isNativePlaybackEnabled,
                   stream != nil || playback.pinnedAudioFlag(for: channel.channelId).isPinned {
                    let isPinned = playback.pinnedAudioFlag(for: channel.channelId).isPinned
                    Button {
                        if isPinned {
                            playback.unpinBackgroundAudio(channelId: channel.channelId)
                        } else {
                            _ = playback.pinBackgroundAudio(
                                channel,
                                title: stream?.title ?? "",
                                profileImageURL: tab.profileImageURL ?? followsStore?.profileImageURLs[channel.channelId],
                                stream: stream
                            )
                        }
                    } label: {
                        Label(
                            isPinned ? "Unpin Audio" : "Background Audio",
                            systemImage: isPinned ? "speaker.slash.fill" : "headphones"
                        )
                    }
                    .tint(isPinned ? .red : .accentColor)
                    .disabled(!isPinned && !playback.canPinMoreBackgroundAudio)
                }
            }
            #endif
            .channelPreviewMenu(
                name: tab.displayName,
                profileImageURL: tab.profileImageURL,
                stream: stream,
                open: { intent in chatTabs.present(tabId: tab.id, intent: intent) },
                close: { chatTabs.close(tabId: tab.id) }
            )
        }
    }

    private func liveStream(_ tab: ChatTab) -> TwitchStream? {
        guard let id = tab.channels.first?.channelId else { return nil }
        return ChannelStatusStore.liveStream(for: id, status: channelStatus, follows: followsStore)
    }

    /// Live chats (busiest first) and offline ones (open order).
    private func sections(_ chatTabs: ChatTabsModel) -> (live: [ChatTab], offline: [ChatTab]) {
        var live: [(ChatTab, Int)] = []
        var offline: [ChatTab] = []
        for tab in chatTabs.tabs {
            if let stream = liveStream(tab) {
                live.append((tab, stream.viewerCount))
            } else {
                offline.append(tab)
            }
        }
        return (live.sorted { $0.1 > $1.1 }.map(\.0), offline)
    }
}

/// Selected state for a row in the split layout's sidebar: a tinted
/// background plus the `.isSelected` trait for VoiceOver. A modifier with
/// its own body so that `activeTabId` (which changes on every pager swipe)
/// is read here, invalidating one row instead of the whole list.
private struct ActiveChatRowSelection: ViewModifier {
    let tabId: UUID
    let chatTabs: ChatTabsModel
    /// Off in the stack layout: the row stays clear, and `activeTabId` is
    /// never read, so pager swipes don't touch the list at all.
    let isEnabled: Bool

    func body(content: Content) -> some View {
        let isActive = isEnabled && chatTabs.isPresented && chatTabs.activeTabId == tabId
        content
            .listRowBackground(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isActive ? Color.accentColor.opacity(0.18) : Color.clear)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
            )
            .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}
