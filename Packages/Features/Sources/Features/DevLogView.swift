import SwiftUI
import Observation
import Core

/// Dev-only log viewer. Reads from `OSLogStore` via `DevLogModel`
/// (which wraps `AppLogger.recentEntries(...)`) and displays chattr's
/// recent log entries with filtering.
///
/// ## Where this is reachable from
///
/// Settings → Developer → Recent Logs. Not in the normal nav graph —
/// intentional. Casual users shouldn't see this; it's for diagnosing
/// "why doesn't X work?" situations from inside the app without
/// needing Xcode attached.
///
/// ## Architecture
///
/// All state + side effects live in `DevLogModel` (separate type
/// below). This view is a pure renderer. The split enables unit-testing
/// the filter logic without rendering, and keeps the OSLogStore read
/// configuration (priority, limit, lookback) co-located with the model
/// instead of scattered in view modifiers.
public struct DevLogView: View {
    @State private var model = DevLogModel()

    public init() {}

    public var body: some View {
        List {
            Section {
                ForEach(model.visibleEntries) { entry in
                    DevLogRow(entry: entry)
                }
                if model.visibleEntries.isEmpty && !model.isLoading {
                    ContentUnavailableView(
                        "No log entries",
                        systemImage: "doc.text",
                        description: Text("Nothing matches the current filters. Try lowering the severity threshold.")
                    )
                }
            } header: {
                filterControls
            }
        }
        .listStyle(.plain)
        .navigationTitle("Recent Logs")
        .toolbarTitleDisplayMode(.inline)
        // Hide the parent TabView's tab bar while this view is on screen —
        // dev tooling shouldn't compete with the rest of the app's chrome.
        // iOS-only modifier (`.tabBar` unavailable on macOS).
        #if os(iOS)
        .toolbar(.hidden, for: .tabBar)
        #endif
        .refreshable { await model.load() }
        .task { await model.load() }
    }

    @ViewBuilder
    private var filterControls: some View {
        @Bindable var bindable = model
        VStack(alignment: .leading, spacing: 8) {
            Picker("Severity", selection: $bindable.minLevel) {
                ForEach([
                    AppLogger.Entry.Level.debug,
                    .info,
                    .notice,
                    .warning,
                    .error,
                ], id: \.self) { level in
                    Text(level.rawValue.capitalized).tag(level)
                }
            }
            .pickerStyle(.segmented)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip(label: "All", isActive: model.selectedCategory == nil) {
                        model.selectedCategory = nil
                    }
                    ForEach(model.availableCategories, id: \.self) { category in
                        chip(label: category, isActive: model.selectedCategory == category) {
                            model.selectedCategory = (model.selectedCategory == category) ? nil : category
                        }
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .textCase(nil)
    }

    @ViewBuilder
    private func chip(label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.footnote.weight(isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? .primary : .secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(isActive ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
    }
}

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

/// One row in the log list. Color-codes by severity, monospaced font for
/// scannable category/message, swipe-to-copy for sharing.
private struct DevLogRow: View {
    let entry: AppLogger.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(entry.level.rawValue.uppercased())
                    .font(.caption2.weight(.bold).monospaced())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(severityColor, in: RoundedRectangle(cornerRadius: 4))
                Text(entry.category)
                    .font(.caption.weight(.medium).monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(entry.date, format: .dateTime.hour().minute().second())
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Text(entry.composedMessage)
                .font(.footnote.monospaced())
                .foregroundStyle(.primary)
                .lineLimit(8)
                .multilineTextAlignment(.leading)
        }
        .contentShape(Rectangle())
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                #if canImport(UIKit)
                UIPasteboard.general.string = entry.composedMessage
                #endif
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }
    }

    private var severityColor: Color {
        switch entry.level {
        case .debug:     return .gray
        case .info:      return .secondary
        case .notice:    return .yellow
        case .warning:   return .orange
        case .error:     return .red
        case .fault:     return .purple
        case .undefined: return .gray
        }
    }
}
