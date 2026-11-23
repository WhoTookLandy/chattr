import Foundation
import CoreGraphics
import Darwin
import Core
#if canImport(UIKit)
import UIKit
#endif

/// Snapshot of the Chats container and horizontal pager (`ChatsScreen` + `ChatPagerScreen`).
struct PagerDiagnosticSnapshot: Equatable, Sendable {
    var usesSplitLayout: Bool = false
    var containerSize: CGSize = .zero
    var tabCount: Int = 0
    var tabSummary: String = ""
    var activeTabId: String = "nil"
    var isPresented: Bool = false
    var windowCenterId: String = "nil"
    var isUserScrolling: Bool = false
    var updatedAt: Date = Date()

    var summaryLine: String {
        let layout = usesSplitLayout ? "split" : "stack"
        let w = Int(containerSize.width.rounded())
        let h = Int(containerSize.height.rounded())
        return "layout=\(layout) size=\(w)x\(h) presented=\(isPresented) tabs=\(tabCount) [\(tabSummary)] active=\(activeTabId) center=\(windowCenterId) scrolling=\(isUserScrolling)"
    }
}

/// Snapshot of `ChatListViewController`'s UIKit collection view geometry and tailing state.
struct ChatListGeometrySnapshot: Equatable, Sendable {
    var ownerId: UUID = UUID()
    var isViewLoaded: Bool = false
    var inWindow: Bool = false
    var viewBounds: CGRect = .zero
    var collectionBounds: CGRect = .zero
    var contentSize: CGSize = .zero
    var contentOffset: CGPoint = .zero
    var adjustedContentInsetTop: CGFloat = 0
    var adjustedContentInsetBottom: CGFloat = 0
    var sectionCount: Int = 0
    var itemCount: Int = 0
    var visibleCellCount: Int = 0
    var minVisibleCellHeight: CGFloat = 0
    var maxVisibleCellHeight: CGFloat = 0
    var isPinnedToBottom: Bool = true
    var isVisible: Bool = true
    var isSuspended: Bool = false
    var feedConsumedVersion: Int = -1
    var feedLiveIdsCount: Int = 0
    var feedUnreadCount: Int = 0
    var updatedAt: Date = Date()

    var summaryLine: String {
        let vw = Int(viewBounds.width.rounded())
        let vh = Int(viewBounds.height.rounded())
        let cw = Int(collectionBounds.width.rounded())
        let ch = Int(collectionBounds.height.rounded())
        let csw = Int(contentSize.width.rounded())
        let csh = Int(contentSize.height.rounded())
        let ox = Int(contentOffset.x.rounded())
        let oy = Int(contentOffset.y.rounded())
        let it = Int(adjustedContentInsetTop.rounded())
        let ib = Int(adjustedContentInsetBottom.rounded())
        let minH = Int(minVisibleCellHeight.rounded())
        let maxH = Int(maxVisibleCellHeight.rounded())
        return "loaded=\(isViewLoaded) win=\(inWindow) view=\(vw)x\(vh) cv=\(cw)x\(ch) cs=\(csw)x\(csh) off=(\(ox),\(oy)) inset=\(it)/\(ib) sec=\(sectionCount) items=\(itemCount) visCells=\(visibleCellCount) cellH=\(minH)..\(maxH) pin=\(isPinnedToBottom) vis=\(isVisible) susp=\(isSuspended) feedV=\(feedConsumedVersion) live=\(feedLiveIdsCount) unread=\(feedUnreadCount)"
    }

    var compactHUDLine: String {
        let cw = Int(collectionBounds.width.rounded())
        let ch = Int(collectionBounds.height.rounded())
        let csh = Int(contentSize.height.rounded())
        let oy = Int(contentOffset.y.rounded())
        let it = Int(adjustedContentInsetTop.rounded())
        let ib = Int(adjustedContentInsetBottom.rounded())
        let win = inWindow ? "Y" : "N"
        let pin = isPinnedToBottom ? "Y" : "N"
        let susp = isSuspended ? " SUSP" : ""
        return "cv:\(cw)x\(ch) win:\(win) items:\(itemCount) cells:\(visibleCellCount) cs:\(csh) y:\(oy) in:\(it)/\(ib) pin:\(pin)\(susp)"
    }
}

/// Snapshot of one mounted `ChatScreen` / `ChatTranscript` instance.
struct ChatPageDiagnosticSnapshot: Equatable, Sendable {
    var channelLogin: String
    var channelId: String
    var tabId: String
    var errorMessage: String?
    var attachState: String
    var transcriptBranch: String
    var isEmpty: Bool
    var visibleLineCount: Int
    var unfilteredLineCount: Int
    var blockedCount: Int
    var changeVersion: Int
    var isVisible: Bool
    var connectionState: String
    var listGeometry: ChatListGeometrySnapshot?
    var updatedAt: Date = Date()

    var summaryLines: [String] {
        var lines = [
            "#\(channelLogin) (id=\(channelId), tab=\(tabId)): branch=\(transcriptBranch) attach=\(attachState) empty=\(isEmpty) lines=\(visibleLineCount)/\(unfilteredLineCount) blocked=\(blockedCount) ver=\(changeVersion) visible=\(isVisible) conn=\(connectionState)\(errorMessage.map { " error=\($0)" } ?? "")"
        ]
        if let listGeometry {
            lines.append("  list: \(listGeometry.summaryLine)")
        } else {
            lines.append("  list: not mounted")
        }
        return lines
    }

    var compactHUDLine: String {
        let err = errorMessage != nil ? " ERR" : ""
        return "#\(channelLogin) \(transcriptBranch) \(attachState) \(visibleLineCount)/\(unfilteredLineCount) blk:\(blockedCount) v:\(changeVersion) vis:\(isVisible ? "Y" : "N")\(err)"
    }
}

/// Non-observable, main-actor live diagnostic registry for TestFlight triage.
///
/// Deliberately NOT `@Observable`: recording pager/page/collection-view state
/// must never trigger SwiftUI invalidation on the normal chat path. Consumers
/// read on demand (`DiagnosticReportBuilder`, `DevLogView`, and the opt-in
/// `ChatDebugOverlay` timer).
@MainActor
final class ChatDiagnostics {
    static let shared = ChatDiagnostics()

    private(set) var pager: PagerDiagnosticSnapshot?
    private var pagesByKey: [String: ChatPageDiagnosticSnapshot] = [:]
    private var listGeometryByKey: [String: ChatListGeometrySnapshot] = [:]

    init() {}

    func recordPager(_ snapshot: PagerDiagnosticSnapshot) {
        pager = snapshot
    }

    func updatePagerLayout(usesSplitLayout: Bool, containerSize: CGSize) {
        var current = pager ?? PagerDiagnosticSnapshot()
        current.usesSplitLayout = usesSplitLayout
        current.containerSize = containerSize
        current.updatedAt = Date()
        pager = current
    }

    func recordPage(_ snapshot: ChatPageDiagnosticSnapshot) {
        let key = snapshot.channelLogin.lowercased()
        pagesByKey[key] = snapshot
    }

    func removePage(channelLogin: String) {
        let key = channelLogin.lowercased()
        pagesByKey[key] = nil
        listGeometryByKey[key] = nil
    }

    func recordListGeometry(channelLogin: String, _ geometry: ChatListGeometrySnapshot) {
        let key = channelLogin.lowercased()
        listGeometryByKey[key] = geometry
    }

    func removeListGeometry(channelLogin: String, ownerId: UUID? = nil) {
        let key = channelLogin.lowercased()
        if let ownerId, listGeometryByKey[key]?.ownerId != ownerId {
            return
        }
        listGeometryByKey[key] = nil
    }

    /// All currently mounted chat pages with their latest `ChatListViewController`
    /// geometry joined in, most-recently-updated first.
    func mergedPages() -> [ChatPageDiagnosticSnapshot] {
        pagesByKey.values.map { page in
            var copy = page
            copy.listGeometry = listGeometryByKey[page.channelLogin.lowercased()]
            return copy
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Live snapshot for one channel (joined with its UIKit list geometry).
    func page(for channelLogin: String) -> ChatPageDiagnosticSnapshot? {
        let key = channelLogin.lowercased()
        guard var page = pagesByKey[key] else { return nil }
        page.listGeometry = listGeometryByKey[key]
        return page
    }

    /// Two compact lines for `ChatDebugOverlay`.
    func hudLines(for channelLogin: String) -> (top: String, bottom: String) {
        let key = channelLogin.lowercased()
        let top = pagesByKey[key]?.compactHUDLine ?? "#\(channelLogin) (no page snapshot)"
        let bottom = listGeometryByKey[key]?.compactHUDLine ?? "cv:not-mounted"
        return (top, bottom)
    }

    func reset() {
        pager = nil
        pagesByKey.removeAll()
        listGeometryByKey.removeAll()
    }
}

/// Builds a self-contained plain-text diagnostic bundle (device + settings +
/// live chat/UIKit state + chronological logs) for TestFlight bug reports.
enum DiagnosticReportBuilder {

    @MainActor
    static func build(
        entries: [AppLogger.Entry],
        previousSessionLog: String? = nil,
        diagnostics: ChatDiagnostics = .shared
    ) -> String {
        let env = collectEnvironmentLines()
        return formatReport(
            environmentLines: env,
            pager: diagnostics.pager,
            pages: diagnostics.mergedPages(),
            entries: entries,
            previousSessionLog: previousSessionLog
        )
    }

    /// Pure formatter so report layout is unit-testable without UIKit/Bundle state.
    nonisolated static func formatReport(
        environmentLines: [String],
        pager: PagerDiagnosticSnapshot?,
        pages: [ChatPageDiagnosticSnapshot],
        entries: [AppLogger.Entry],
        previousSessionLog: String? = nil
    ) -> String {
        var sections: [String] = []

        var header = ["=== chattr Diagnostic Report ==="]
        header.append(contentsOf: environmentLines)
        sections.append(header.joined(separator: "\n"))

        var stateLines = ["=== Live Chat State ==="]
        if let pager {
            stateLines.append("Pager: \(pager.summaryLine)")
        } else {
            stateLines.append("Pager: (none recorded)")
        }
        if pages.isEmpty {
            stateLines.append("Pages: (none mounted)")
        } else {
            for page in pages {
                stateLines.append(contentsOf: page.summaryLines)
            }
        }
        sections.append(stateLines.joined(separator: "\n"))

        var logLines = ["=== Current Session Logs (\(entries.count)) ==="]
        if entries.isEmpty {
            logLines.append("(no log entries)")
        } else {
            logLines.append(DiagnosticLogStore.formatChronological(entries))
        }
        sections.append(logLines.joined(separator: "\n"))

        if let previousSessionLog, !previousSessionLog.isEmpty {
            sections.append("=== Previous Session Log ===\n\(previousSessionLog)")
        }

        return sections.joined(separator: "\n\n")
    }

    @MainActor
    private static func collectEnvironmentLines() -> [String] {
        let defaults = UserDefaults.standard
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let timestamp = Date().formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: false))

        var lines: [String] = [
            "Generated: \(timestamp)",
            "App: \(DeveloperSettings.versionString) [\(DeveloperSettings.buildChannel)]",
            "Device: \(hardwareModel()) | OS: \(osVersion)",
        ]

        #if canImport(UIKit)
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            let bounds = scene.coordinateSpace.bounds
            lines.append("Window: \(Int(bounds.width.rounded()))x\(Int(bounds.height.rounded()))")
        }
        #endif

        let edgeToEdge = defaults.bool(forKey: ChatAppearance.edgeToEdgeKey)
        let videoExpanded = defaults.bool(forKey: StreamHeaderView.expandedKey)
        let audioOnly = defaults.bool(forKey: PlayerSettings.audioOnlyKey)
        let nativePlayer = defaults.bool(forKey: PlayerSettings.nativePlayerKey)
        let hideCommands = ChatFilterSettings.hideCommands()
        let hideBots = ChatFilterSettings.hideBots()
        let historyCap = ChatAppearance.chatHistoryLines(defaults: defaults)
        lines.append(
            "Settings: edgeToEdge=\(edgeToEdge) videoExpanded=\(videoExpanded) audioOnly=\(audioOnly) nativePlayer=\(nativePlayer) hideCommands=\(hideCommands) hideBots=\(hideBots) historyCap=\(historyCap)"
        )
        return lines
    }

    /// Hardware identifier (e.g. "iPhone17,2", "arm64") via `uname`.
    nonisolated static func hardwareModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 1) { cStr in
                String(cString: cStr)
            }
        }
    }
}
