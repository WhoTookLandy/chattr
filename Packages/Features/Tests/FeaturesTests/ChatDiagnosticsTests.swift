import Foundation
import CoreGraphics
import Testing
import Core
@testable import Features

@Suite("ChatDiagnostics & DevLogModel")
@MainActor
struct ChatDiagnosticsTests {

    @Test("ChatDiagnostics merges page snapshots with UIKit list geometry and formats HUD lines")
    func mergesPageAndListGeometry() {
        let diag = ChatDiagnostics()
        diag.recordPager(PagerDiagnosticSnapshot(
            usesSplitLayout: false,
            containerSize: CGSize(width: 440, height: 956),
            tabCount: 1,
            tabSummary: "#xqc*",
            activeTabId: "12345678",
            isPresented: true,
            windowCenterId: "12345678",
            isUserScrolling: false
        ))
        diag.recordPage(ChatPageDiagnosticSnapshot(
            channelLogin: "xQc",
            channelId: "71092938",
            tabId: "12345678",
            errorMessage: nil,
            attachState: "attached",
            transcriptBranch: "list",
            isEmpty: false,
            visibleLineCount: 150,
            unfilteredLineCount: 150,
            blockedCount: 0,
            changeVersion: 4,
            isVisible: true,
            connectionState: "connected"
        ))
        diag.recordListGeometry(
            channelLogin: "xqc",
            ChatListGeometrySnapshot(
                isViewLoaded: true,
                inWindow: true,
                viewBounds: CGRect(x: 0, y: 0, width: 440, height: 600),
                collectionBounds: CGRect(x: 0, y: 0, width: 440, height: 600),
                contentSize: CGSize(width: 440, height: 6400),
                contentOffset: CGPoint(x: 0, y: 5800),
                adjustedContentInsetTop: 110,
                adjustedContentInsetBottom: 72,
                sectionCount: 1,
                itemCount: 150,
                visibleCellCount: 14,
                minVisibleCellHeight: 28,
                maxVisibleCellHeight: 64,
                isPinnedToBottom: true,
                isVisible: true,
                isSuspended: false,
                feedConsumedVersion: 4,
                feedLiveIdsCount: 150,
                feedUnreadCount: 0
            )
        )

        let merged = diag.mergedPages()
        #expect(merged.count == 1)
        #expect(merged[0].listGeometry?.itemCount == 150)
        #expect(merged[0].listGeometry?.visibleCellCount == 14)

        let hud = diag.hudLines(for: "xqc")
        #expect(hud.top.contains("#xQc list attached 150/150"))
        #expect(hud.bottom.contains("cv:440x600 win:Y items:150 cells:14"))
    }

    @Test("DiagnosticReportBuilder formats environment, pager, pages, current logs, and previous session")
    func reportFormatting() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let t1 = Date(timeIntervalSince1970: 1_700_000_001)
        // Newest-first input (as AppLogger.recentEntries returns)
        let entries = [
            AppLogger.Entry(id: 2, date: t1, level: .warning, category: "Features.ChatListVC", composedMessage: "blank anomaly"),
            AppLogger.Entry(id: 1, date: t0, level: .info, category: "Features.ChatScreen", composedMessage: "appeared"),
        ]
        let report = DiagnosticReportBuilder.formatReport(
            environmentLines: ["App: 1.0 (42) [TestFlight]", "Device: iPhone18,2"],
            pager: PagerDiagnosticSnapshot(usesSplitLayout: false, containerSize: CGSize(width: 440, height: 956), tabCount: 1, tabSummary: "#xqc*", isPresented: true),
            pages: [],
            entries: entries,
            previousSessionLog: "2026-11-23T00:00:00.000Z [ERROR] [App] prior crash"
        )

        #expect(report.contains("=== chattr Diagnostic Report ==="))
        #expect(report.contains("App: 1.0 (42) [TestFlight]"))
        #expect(report.contains("Pager: layout=stack size=440x956"))
        #expect(report.contains("=== Current Session Logs (2) ==="))
        #expect(report.contains("=== Previous Session Log ==="))
        #expect(report.contains("prior crash"))

        // Current session logs are chronological (oldest first) in the report.
        let appearedRange = report.range(of: "appeared")
        let anomalyRange = report.range(of: "blank anomaly")
        #expect(appearedRange != nil && anomalyRange != nil)
        if let appearedRange, let anomalyRange {
            #expect(appearedRange.lowerBound < anomalyRange.lowerBound)
        }
    }

    @Test("DevLogModel filters by severity, category, and case-insensitive search text")
    func devLogModelFiltering() {
        let now = Date()
        let entries = [
            AppLogger.Entry(id: 3, date: now, level: .error, category: "Channels.Registry", composedMessage: "EventSub timeout"),
            AppLogger.Entry(id: 2, date: now, level: .info, category: "Features.ChatListVC", composedMessage: "initial apply #xqc"),
            AppLogger.Entry(id: 1, date: now, level: .debug, category: "Features.ChatListVC", composedMessage: "verbose tick"),
        ]
        let model = DevLogModel(entries: entries)

        // Default minLevel is .info
        #expect(model.visibleEntries.map(\.id) == [3, 2])
        #expect(model.availableCategories == ["Channels.Registry", "Features.ChatListVC"])

        model.minLevel = .debug
        #expect(model.visibleEntries.map(\.id) == [3, 2, 1])

        model.selectedCategory = "Features.ChatListVC"
        #expect(model.visibleEntries.map(\.id) == [2, 1])

        model.searchText = "XQC"
        #expect(model.visibleEntries.map(\.id) == [2])

        model.selectedCategory = nil
        model.searchText = "registry"
        #expect(model.visibleEntries.map(\.id) == [3])
    }
}
