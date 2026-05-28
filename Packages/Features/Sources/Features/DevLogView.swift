import SwiftUI
import Core

/// Dev-only log viewer. Reads from `OSLogStore` via
/// `AppLogger.recentEntries(...)` and displays chattr's recent log entries
/// with filtering.
///
/// ## Where this is reachable from
///
/// Settings → Developer → Recent Logs. Not in the normal nav graph —
/// intentional. Casual users shouldn't see this; it's for diagnosing
/// "why doesn't X work?" situations from inside the app without
/// needing Xcode attached.
///
/// ## Performance notes
///
/// Earlier version queried OSLogStore on every severity change (~10-50ms
/// per query) and used non-stable UUIDs (forcing SwiftUI to re-create
/// every row on every refresh). Current shape:
///
///   - **One query**, fetches everything at `.debug` and above into
///     `allEntries`. Severity changes filter the in-memory array — instant.
///   - **Deterministic Entry.id** (hash of date+category+message) so SwiftUI
///     can diff rows across reloads instead of re-creating all 200.
///   - **Memoized `availableCategories`** in @State, updated only when
///     `allEntries` changes — not on every body recomputation.
public struct DevLogView: View {
    /// All entries from the last OSLogStore read, regardless of severity.
    /// We apply the severity filter in memory rather than re-querying.
    @State private var allEntries: [AppLogger.Entry] = []

    /// Memoized category set + sort. Recomputed only when `allEntries`
    /// changes (via the `.onChange` below), not on every body call.
    @State private var availableCategories: [String] = []

    @State private var minLevel: AppLogger.Entry.Level = .info
    @State private var selectedCategory: String? = nil
    @State private var isLoading = false

    /// Entries visible after both severity + category filters. Computed
    /// fresh on each body recomputation, but that's cheap (~200 element
    /// array scan with two cheap predicates) — far cheaper than re-querying
    /// OSLogStore.
    private var visibleEntries: [AppLogger.Entry] {
        allEntries.filter { entry in
            guard entry.level.severity >= minLevel.severity else { return false }
            if let cat = selectedCategory, entry.category != cat { return false }
            return true
        }
    }

    public init() {}

    public var body: some View {
        List {
            Section {
                ForEach(visibleEntries) { entry in
                    DevLogRow(entry: entry)
                }
                if visibleEntries.isEmpty && !isLoading {
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
        .refreshable { await reload() }
        .task { await reload() }
        // Recompute the category chip set ONLY when the underlying data
        // changes. Without this guard, the Set+sort would re-run on every
        // body recomputation (severity slider, filter chip tap, etc.).
        .onChange(of: allEntries) { _, new in
            availableCategories = Array(Set(new.map(\.category))).sorted()
        }
    }

    @ViewBuilder
    private var filterControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Severity picker. Changing it just filters `allEntries` in
            // memory — no OSLogStore re-query needed.
            Picker("Severity", selection: $minLevel) {
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

            // Category chips. Reads from `availableCategories` (memoized).
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip(label: "All", isActive: selectedCategory == nil) {
                        selectedCategory = nil
                    }
                    ForEach(availableCategories, id: \.self) { category in
                        chip(label: category, isActive: selectedCategory == category) {
                            selectedCategory = (selectedCategory == category) ? nil : category
                        }
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .textCase(nil)  // List section headers uppercase by default; opt out.
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

    /// Re-read from OSLogStore. Fetches at `.debug` and above so any
    /// severity filter is satisfiable in memory without a re-query.
    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        // Off-main read: OSLogStore is sync but slow (~10-50ms). Hopping
        // keeps the refresh-pull animation smooth.
        let snapshot = await Task.detached(priority: .userInitiated) {
            // Fetch at the lowest level so picker changes don't need to
            // re-query. 500 entries is plenty for one debug session and
            // keeps the in-memory filter snappy.
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
