import Testing
import Foundation
import Core
@testable import Features

/// `PagerWindow` keeps the settled page and one neighbour each side mounted.
@MainActor
@Suite("PagerWindow")
struct PagerWindowTests {
    private func channel(_ name: String) -> ChannelDescriptor {
        ChannelDescriptor(
            channelId: name, channelLoginName: name,
            channelDisplayName: name, profileImageURL: nil
        )
    }

    /// Five open tabs, returned in strip order.
    private func fiveTabs() -> (ChatTabsModel, [UUID]) {
        let model = ChatTabsModel()
        let ids = ["a", "b", "c", "d", "e"].map { model.open(channel: channel($0)) }
        return (model, ids)
    }

    @Test("Mounts the center and its neighbours only")
    func centerAndNeighbours() {
        let (model, ids) = fiveTabs()
        let window = PagerWindow()
        window.centerId = ids[2]
        #expect(ids.map { window.isMounted($0, in: model) } == [false, true, true, true, false])
    }

    @Test("Edges mount one neighbour")
    func edges() {
        let (model, ids) = fiveTabs()
        let window = PagerWindow()
        window.centerId = ids[0]
        #expect(ids.map { window.isMounted($0, in: model) } == [true, true, false, false, false])
    }

    @Test("Before the first settle, centers on the active tab")
    func fallsBackToActiveTab() {
        let (model, ids) = fiveTabs()  // opening the last tab activates it
        let window = PagerWindow()
        #expect(ids.map { window.isMounted($0, in: model) } == [false, false, false, true, true])
    }

    @Test("A closed center falls back to the active tab, not to everything")
    func staleCenterFallsBack() {
        let (model, ids) = fiveTabs()
        let window = PagerWindow()
        window.centerId = ids[2]
        model.activeTabId = ids[4]
        model.close(tabId: ids[2])
        // Remaining strip: a b d e, active e → d and e mounted.
        #expect(ids.map { window.isMounted($0, in: model) } == [false, false, false, true, true])
    }
}
