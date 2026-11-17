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

    @Environment(\.chatTabs) private var chatTabs
    @Environment(\.channelStatus) private var channelStatus
    @Environment(\.followsStore) private var followsStore

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
                chatTabs.activeTabId = tab.id
                chatTabs.isPresented = true
            } label: {
                OpenChatRow(tab: tab, chatTabs: chatTabs)
            }
            .buttonStyle(.plain)
            .listRowBackground(Color.clear)
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) {
                    chatTabs.close(tabId: tab.id)
                } label: {
                    Label("Close", systemImage: "xmark")
                }
            }
            .channelPreviewMenu(
                name: tab.displayName,
                profileImageURL: tab.profileImageURL,
                stream: stream,
                open: {
                    chatTabs.activeTabId = tab.id
                    chatTabs.isPresented = true
                },
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
