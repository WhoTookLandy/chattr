import Testing
import Foundation
import Observation
import Core
@testable import Features

/// Redundant writes to `ChatTabsModel` must not notify observers. AppShell's
/// body (the whole `TabView`) reads `mentionedTabIds` and `isPresented`, and
/// the pager's `.scrollPosition(id:)` writes `activeTabId` back on every
/// page change — so an equal-value write that still notified re-ran the
/// root view on every chat swipe.
@MainActor
@Suite("ChatTabsModel observation de-dup")
struct ChatTabsModelObservationTests {
    private func channel(_ name: String) -> ChannelDescriptor {
        ChannelDescriptor(
            channelId: name, channelLoginName: name,
            channelDisplayName: name, profileImageURL: nil
        )
    }

    /// Set from `withObservationTracking`'s `@Sendable` onChange. It fires
    /// synchronously inside the mutating call on this (main) actor, so a
    /// plain flag is race-free here.
    private final class Flag: @unchecked Sendable {
        var fired = false
    }

    /// True when `mutate` notifies a tracker that read `read`.
    private func notifies(
        reading read: () -> Void,
        when mutate: () -> Void
    ) -> Bool {
        let flag = Flag()
        withObservationTracking(read) { flag.fired = true }
        mutate()
        return flag.fired
    }

    @Test("Re-setting the active tab doesn't notify")
    func sameActiveTabIsSilent() {
        let model = ChatTabsModel()
        let id = model.open(channel: channel("a"))
        #expect(!notifies(reading: { _ = model.activeTabId }) { model.activeTabId = id })
        #expect(!notifies(reading: { _ = model.mentionedTabIds }) { model.activeTabId = id })
    }

    @Test("Switching tabs without a mention doesn't touch mentionedTabIds")
    func switchWithoutMentionIsSilent() {
        let model = ChatTabsModel()
        let a = model.open(channel: channel("a"))
        let b = model.open(channel: channel("b"))
        // A real change still notifies its readers…
        #expect(notifies(reading: { _ = model.activeTabId }) { model.activeTabId = a })
        // …but not the mention set's, when there was nothing to clear.
        #expect(!notifies(reading: { _ = model.mentionedTabIds }) { model.activeTabId = b })
    }

    @Test("Switching to a mentioned tab still clears its mention")
    func switchToMentionedTabClears() {
        let model = ChatTabsModel()
        let a = model.open(channel: channel("a"))
        _ = model.open(channel: channel("b"))
        model.markMention(tabId: a)
        #expect(model.mentionedTabIds.contains(a))
        model.activeTabId = a
        #expect(!model.mentionedTabIds.contains(a))
    }

    @Test("A repeat ping in a background tab doesn't notify")
    func repeatMentionIsSilent() {
        let model = ChatTabsModel()
        let a = model.open(channel: channel("a"))
        _ = model.open(channel: channel("b"))
        model.markMention(tabId: a)
        #expect(!notifies(reading: { _ = model.mentionedTabIds }) { model.markMention(tabId: a) })
    }

    @Test("Re-setting isPresented doesn't notify")
    func sameIsPresentedIsSilent() {
        let model = ChatTabsModel()
        _ = model.open(channel: channel("a"))
        #expect(!notifies(reading: { _ = model.isPresented }) { model.isPresented = true })
    }
}
