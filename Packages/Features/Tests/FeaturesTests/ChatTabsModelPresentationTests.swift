import Testing
import Foundation
import Core
@testable import Features

/// `isPresented` drives the chat push separately from `activeTabId`, so
/// popping the pager never writes to the id its scroll position is bound to
/// (the back-button freeze).
@MainActor
@Suite("ChatTabsModel.isPresented")
struct ChatTabsModelPresentationTests {
    private func channel(_ name: String) -> ChannelDescriptor {
        ChannelDescriptor(
            channelId: name, channelLoginName: name,
            channelDisplayName: name, profileImageURL: nil
        )
    }

    @Test("Opening a channel presents the chat")
    func openPresents() {
        let model = ChatTabsModel()
        let id = model.open(channel: channel("a"))
        #expect(model.isPresented)
        #expect(model.activeTabId == id)
    }

    @Test("Popping clears the flag but keeps the active tab")
    func popKeepsActiveTab() {
        let model = ChatTabsModel()
        let id = model.open(channel: channel("a"))
        model.isPresented = false
        #expect(model.activeTabId == id)
    }

    @Test("Re-opening an existing channel presents it again")
    func reopenPresents() {
        let model = ChatTabsModel()
        let id = model.open(channel: channel("a"))
        model.isPresented = false
        #expect(model.open(channel: channel("a")) == id)
        #expect(model.isPresented)
    }

    @Test("Closing the last tab dismisses the chat")
    func closeLastDismisses() {
        let model = ChatTabsModel()
        let id = model.open(channel: channel("a"))
        model.close(tabId: id)
        #expect(!model.isPresented)
    }

    @Test("Mentions in the active tab count once the chat is popped")
    func mentionAfterPop() {
        let model = ChatTabsModel()
        let id = model.open(channel: channel("a"))

        model.markMention(tabId: id)
        #expect(!model.mentionedTabIds.contains(id))  // on screen: ignored

        model.isPresented = false
        model.markMention(tabId: id)
        #expect(model.mentionedTabIds.contains(id))   // off screen: counts

        model.isPresented = true
        #expect(!model.mentionedTabIds.contains(id))  // coming back clears it
    }
}
