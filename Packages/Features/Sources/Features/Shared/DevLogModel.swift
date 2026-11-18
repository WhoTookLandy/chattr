import Observation
import Core

/// Owns the state + side effects for `DevLogView`. Split out so the
/// OSLogStore read configuration (limit, lookback, priority) and the
/// filter logic (severity threshold, category) can be unit-tested
/// without rendering the view.
///
/// ## Caching strategy
///
///   - **One OSLogStore read per `load()`.** Severity-picker changes
///     and category-chip taps don't re-query — they filter the
///     in-memory `allEntries` via `visibleEntries`.
///   - **`availableCategories` is a computed property.** With ≤500
///     entries the Set+sort is sub-millisecond, not worth memoizing
///     for a dev-only screen.
@MainActor @Observable
final class DevLogModel {
    /// All entries from the last OSLogStore read, regardless of severity.
    /// Severity filter applies in memory (see `visibleEntries`) so picker
    /// changes don't re-query OSLogStore.
    private(set) var allEntries: [AppLogger.Entry] = []

    /// Severity filter. Reads from the segmented picker.
    var minLevel: AppLogger.Entry.Level = .info

    /// Optional category filter. nil = show all categories.
    var selectedCategory: String? = nil

    /// True while `load()` is in flight. Drives empty-state vs. content
    /// disambiguation when `visibleEntries.isEmpty`.
    private(set) var isLoading = false

    /// Entries visible after applying severity + category filters.
    var visibleEntries: [AppLogger.Entry] {
        allEntries.filter { entry in
            guard entry.level.severity >= minLevel.severity else { return false }
            if let cat = selectedCategory, entry.category != cat { return false }
            return true
        }
    }

    /// Distinct categories present in the currently-loaded entries. Used
    /// to populate the chip set. Recomputed via the computed property —
    /// for ≤500 entries the Set+sort is sub-millisecond. If this ever
    /// became a hot path (it won't on a dev screen), memoize via
    /// `.onChange(of: allEntries)` into a stored `@State`.
    var availableCategories: [String] {
        Array(Set(allEntries.map(\.category))).sorted()
    }

    /// Re-read from OSLogStore. Fetches everything at `.debug` and above
    /// so any severity filter is satisfiable in memory.
    ///
    /// The OSLogStore read is synchronous and slow (10-50ms), so we hop
    /// off-main via `Task.detached(priority: .userInitiated)` to keep
    /// the refresh-pull animation smooth.
    func load() async {
        isLoading = true
        defer { isLoading = false }
        let snapshot = await Task.detached(priority: .userInitiated) {
            AppLogger.recentEntries(limit: 500, minLevel: .debug)
        }.value
        self.allEntries = snapshot
    }
}
