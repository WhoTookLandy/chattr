import Testing
import Foundation
@testable import Features

@MainActor
@Suite("ChatTabsModel.move")
struct ChatTabsModelMoveTests {
    private func channel(_ name: String) -> ChannelDescriptor {
        ChannelDescriptor(
            channelId: name, channelLoginName: name,
            channelDisplayName: name, profileImageURL: nil
        )
    }

    @Test("Moving a tab reorders the tabs array")
    func reorders() {
        let model = ChatTabsModel()
        model.open(channel: channel("a"))
        model.open(channel: channel("b"))
        model.open(channel: channel("c"))
        model.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(model.tabs.map { $0.channels[0].channelLoginName } == ["c", "a", "b"])
    }

    @Test("Reordering preserves the active selection")
    func preservesActive() {
        let model = ChatTabsModel()
        model.open(channel: channel("a"))
        let bId = model.open(channel: channel("b"))
        model.open(channel: channel("c"))
        model.activeTabId = bId
        model.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        #expect(model.activeTabId == bId)
        #expect(model.tabs.map { $0.channels[0].channelLoginName } == ["b", "c", "a"])
    }
}
