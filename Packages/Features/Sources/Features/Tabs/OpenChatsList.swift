import SwiftUI
import DesignSystem

/// Home → Chats: the open chats, Messages-style. Each row (`OpenChatRow`)
/// carries live ring / viewers / category / uptime / title, or offline +
/// last live. Tap to push the chat pager (sets `activeTabId`, which the
/// presenting `HomeScreen` derives its push from); swipe to close (releases
/// the session via the model's `onClose`); drag to reorder (defines the
/// pager's swipe order).
struct OpenChatsList: View {
    /// The empty state's CTA — switches Home to its Live section.
    let onShowLive: () -> Void

    @Environment(\.chatTabs) private var chatTabs

    var body: some View {
        if let chatTabs, !chatTabs.tabs.isEmpty {
            List {
                ForEach(chatTabs.tabs) { tab in
                    Button {
                        chatTabs.activeTabId = tab.id
                    } label: {
                        OpenChatRow(tab: tab, chatTabs: chatTabs)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                }
                .onMove { source, destination in
                    chatTabs.move(fromOffsets: source, toOffset: destination)
                }
                .onDelete { offsets in
                    // One batched close: a single persistence save and one
                    // release pass, instead of a save per row.
                    chatTabs.close(tabIds: offsets.map { chatTabs.tabs[$0].id })
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
}
