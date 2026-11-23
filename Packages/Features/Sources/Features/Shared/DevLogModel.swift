import Foundation
import Observation
import Core

/// Owns the state + side effects for `DevLogView`. Split out so the log read,
/// filtering (severity, category, search text), and diagnostic report export
/// can be unit-tested without rendering the view.
///
/// ## Caching strategy
///
///   - **One log read per `load()`.** Severity-picker, category-chip, and
///     search-field changes filter the in-memory `allEntries` via
///     `visibleEntries` without re-reading disk or `OSLogStore`.
///   - **`availableCategories` is a computed property.** With ≤1,000 entries
///     the Set+sort is sub-millisecond.
@MainActor @Observable
final class DevLogModel {
    /// All entries from the last load, newest-first, regardless of severity.
    private(set) var allEntries: [AppLogger.Entry] = []

    /// Rotated log from the prior launch (before a crash or restart), if any.
    private(set) var previousSessionLog: String? = nil

    /// Severity filter. Reads from the segmented picker.
    var minLevel: AppLogger.Entry.Level = .info

    /// Optional category filter. nil = show all categories.
    var selectedCategory: String? = nil

    /// Free-text filter matching category or message (case-insensitive).
    var searchText: String = ""

    /// True while `load()` is in flight. Drives empty-state vs. content
    /// disambiguation when `visibleEntries.isEmpty`.
    private(set) var isLoading = false

    /// Entries visible after applying severity, category, and search filters.
    var visibleEntries: [AppLogger.Entry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return allEntries.filter { entry in
            guard entry.level.severity >= minLevel.severity else { return false }
            if let cat = selectedCategory, entry.category != cat { return false }
            if !query.isEmpty {
                let matchesCategory = entry.category.localizedCaseInsensitiveContains(query)
                let matchesMessage = entry.composedMessage.localizedCaseInsensitiveContains(query)
                guard matchesCategory || matchesMessage else { return false }
            }
            return true
        }
    }

    /// Distinct categories present in the currently-loaded entries.
    var availableCategories: [String] {
        Array(Set(allEntries.map(\.category))).sorted()
    }

    init(entries: [AppLogger.Entry] = [], previousSessionLog: String? = nil) {
        self.allEntries = entries
        self.previousSessionLog = previousSessionLog
    }

    /// Re-read recent entries and any rotated previous-session log off-main.
    func load() async {
        isLoading = true
        defer { isLoading = false }
        let (snapshot, previous) = await Task.detached(priority: .userInitiated) {
            (
                AppLogger.recentEntries(limit: 1_000, minLevel: .debug),
                AppLogger.previousSessionLog()
            )
        }.value
        self.allEntries = snapshot
        self.previousSessionLog = previous
    }

    /// Clears in-app log memory and rotating files.
    func clear() async {
        await Task.detached(priority: .userInitiated) {
            AppLogger.clearRecentEntries()
        }.value
        allEntries = []
        previousSessionLog = nil
    }

    /// Builds a shareable plain-text diagnostic report with device/settings
    /// metadata, live chat/UIKit snapshots, and logs.
    func buildReport(
        filteredOnly: Bool = false,
        includePreviousSession: Bool = true,
        diagnostics: ChatDiagnostics = .shared
    ) -> String {
        let entries = filteredOnly ? visibleEntries : allEntries
        return DiagnosticReportBuilder.build(
            entries: entries,
            previousSessionLog: includePreviousSession ? previousSessionLog : nil,
            diagnostics: diagnostics
        )
    }
}
