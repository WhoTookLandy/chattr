import SwiftUI

/// Keeps `PagerWindow.centerId` following `activeTabId`, except while the
/// user is mid-swipe (see `PagerWindow`). A zero-size view of its own so the
/// `activeTabId` read invalidates only this, never the pager body.
struct PagerWindowTracker: View {
    let chatTabs: ChatTabsModel
    let window: PagerWindow

    var body: some View {
        let active = chatTabs.activeTabId ?? chatTabs.tabs.first?.id
        // Mid-swipe: hold the current center. Otherwise follow the page.
        let target = window.isUserScrolling ? window.centerId : active
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: target, initial: true) { _, newTarget in
                guard let newTarget, window.centerId != newTarget else { return }
                window.centerId = newTarget
            }
    }
}
