import SwiftUI

/// Owns every read of `activeTabId` / `isPresented` for scene restore, so a
/// pager swipe invalidates this empty view instead of `ChatsScreen`'s stack.
struct ChatResumeCoordinator: View {
    let chatTabs: ChatTabsModel?

    /// Scene-scoped restoration of the open chat (round-tripped through
    /// `uuidString`; `@SceneStorage` only takes primitives). Not
    /// account-scoped: after an account switch the saved id simply won't
    /// match any of the new account's tabs, and the restore skips it.
    @SceneStorage("chattr.chat.activeTabId") private var persistedActiveTabId: String?

    /// Settings → Chat → Resume Last Chat.
    @AppStorage("chattr.resumeLastChatOnLaunch") private var resumeLastChatOnLaunch = true

    /// Cold start: put the user back in the chat they had open. One-shot.
    @State private var didResume = false

    var body: some View {
        Color.clear
            .onAppear(perform: resumeLastChatIfNeeded)
            // Tabs hydrate from disk asynchronously at launch; retry once they land.
            .onChange(of: chatTabs?.tabs.count) { _, _ in resumeLastChatIfNeeded() }
            // Persist the chat that's open on screen (nil once popped), so
            // "resume last chat" restores what the user was actually in.
            .onChange(of: chatTabs?.activeTabId) { _, newValue in
                if chatTabs?.isPresented == true {
                    persistedActiveTabId = newValue?.uuidString
                }
            }
            .onChange(of: chatTabs?.isPresented) { _, presented in
                persistedActiveTabId = presented == true ? chatTabs?.activeTabId?.uuidString : nil
            }
    }

    private func resumeLastChatIfNeeded() {
        guard !didResume,
              resumeLastChatOnLaunch,
              let chatTabs,
              chatTabs.activeTabId == nil,
              let savedId = persistedActiveTabId,
              let uuid = UUID(uuidString: savedId),
              chatTabs.tabs.contains(where: { $0.id == uuid })
        else { return }
        didResume = true
        chatTabs.activeTabId = uuid
        chatTabs.isPresented = true
    }
}
