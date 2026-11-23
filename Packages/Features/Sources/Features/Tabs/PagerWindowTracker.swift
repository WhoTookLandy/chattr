import SwiftUI
import Core

private let logger = AppLogger.make("Features.ChatPagerScreen")

/// Keeps `PagerWindow.centerId` following `activeTabId`, except while the
/// user is mid-swipe (see `PagerWindow`). A zero-size view of its own so the
/// `activeTabId` read invalidates only this, never the pager body.
///
/// Also records pager state into `ChatDiagnostics` on transitions so TestFlight
/// diagnostic reports include tab/window state without adding any observation
/// dependencies to `ChatPagerScreen.body`.
struct PagerWindowTracker: View {
    let chatTabs: ChatTabsModel
    let window: PagerWindow

    private struct DiagnosticKey: Equatable {
        let tabIds: [UUID]
        let activeTabId: UUID?
        let isPresented: Bool
        let centerId: UUID?
        let isUserScrolling: Bool
    }

    var body: some View {
        let active = chatTabs.activeTabId ?? chatTabs.tabs.first?.id
        // Mid-swipe: hold the current center. Otherwise follow the page.
        let target = window.isUserScrolling ? window.centerId : active
        let diagKey = DiagnosticKey(
            tabIds: chatTabs.tabs.map(\.id),
            activeTabId: chatTabs.activeTabId,
            isPresented: chatTabs.isPresented,
            centerId: window.centerId,
            isUserScrolling: window.isUserScrolling
        )
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: target, initial: true) { _, newTarget in
                guard let newTarget, window.centerId != newTarget else { return }
                window.centerId = newTarget
            }
            .onChange(of: diagKey, initial: true) { _, key in
                let existing = ChatDiagnostics.shared.pager
                let summary = chatTabs.tabs.map { tab in
                    let login = tab.channels.first?.channelLoginName ?? "?"
                    let marker = tab.id == key.activeTabId ? "*" : ""
                    return "#\(login)\(marker)"
                }.joined(separator: ", ")
                let snapshot = PagerDiagnosticSnapshot(
                    usesSplitLayout: existing?.usesSplitLayout ?? false,
                    containerSize: existing?.containerSize ?? .zero,
                    tabCount: chatTabs.tabs.count,
                    tabSummary: summary,
                    activeTabId: key.activeTabId?.uuidString.prefix(8).description ?? "nil",
                    isPresented: key.isPresented,
                    windowCenterId: key.centerId?.uuidString.prefix(8).description ?? "nil",
                    isUserScrolling: key.isUserScrolling
                )
                ChatDiagnostics.shared.recordPager(snapshot)
                logger.info("ChatPager state: \(snapshot.summaryLine, privacy: .public)")
            }
    }
}
