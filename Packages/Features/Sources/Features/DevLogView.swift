import SwiftUI
import Core

/// Dev-only log viewer. Reads from `OSLogStore` via
/// `AppLogger.recentEntries(...)` and displays chattr's recent log entries
/// with filtering.
///
/// ## Where this is reachable from
///
/// Long-press the Settings screen header (see `SettingsScreen.swift`).
/// Not in the normal nav graph — intentional. Casual users shouldn't
/// see this; it's for diagnosing "why doesn't X work?" situations from
/// inside the app without needing Xcode attached.
///
/// ## What you can do here
///
///   - Browse the most recent ~200 log lines, newest first
///   - Filter by severity (info / notice / warning / error / fault)
///   - Filter by category (Accounts / Channels / Features / etc.)
///   - Tap an entry to copy its `composedMessage` to clipboard
///   - Pull to refresh (re-reads from OSLogStore)
///
/// ## What it doesn't do (yet)
///
///   - Persist across launches (OSLogStore retains entries for hours/days
///     but is process-scoped on iOS — we read what the system has).
///   - Export as a file (could add later — for now, copy-tap a line).
///   - Live-update (we re-read on appear and on refresh; no streaming).
public struct DevLogView: View {
    @State private var entries: [AppLogger.Entry] = []
    @State private var minLevel: AppLogger.Entry.Level = .info
    @State private var selectedCategory: String? = nil
    @State private var isLoading = false

    /// Categories present in the currently-loaded entries, alphabetized.
    /// Recomputed when entries change so the filter chip set stays
    /// representative of what's actually visible.
    private var availableCategories: [String] {
        Array(Set(entries.map(\.category))).sorted()
    }

    /// Entries filtered through the active category chip. Severity is
    /// already applied by the OSLogStore read (no need to re-filter).
    private var filteredEntries: [AppLogger.Entry] {
        guard let cat = selectedCategory else { return entries }
        return entries.filter { $0.category == cat }
    }

    public init() {}

    public var body: some View {
        List {
            // Filter controls live in a Section header so they pin while
            // scrolling — important when the log list is long.
            Section {
                ForEach(filteredEntries) { entry in
                    DevLogRow(entry: entry)
                }
                if filteredEntries.isEmpty && !isLoading {
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
        .refreshable { await reload() }
        .task { await reload() }
    }

    /// Severity picker + category chips. Wrapped in a VStack with explicit
    /// background so the sticky section header gets a solid material
    /// underneath (List section headers are transparent by default).
    @ViewBuilder
    private var filterControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Severity picker — segmented so all five options are visible
            // at a glance without a sheet/menu.
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
            .onChange(of: minLevel) { _, _ in Task { await reload() } }

            // Category filter as horizontal chips. "All" first, then
            // alphabetized categories. Each chip is a small tinted capsule
            // to match the existing channel-pill aesthetic.
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
        .textCase(nil)  // Otherwise List uppercases section headers.
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

    /// Re-read from OSLogStore. The read happens on a background-priority
    /// Task because OSLogStore can take 10-50ms for a few hundred entries.
    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        // Hop off-main for the read. OSLogStore is sync but slow; hopping
        // keeps the UI responsive during the refresh-pull animation.
        let snapshot = await Task.detached(priority: .userInitiated) { [minLevel] in
            AppLogger.recentEntries(limit: 200, minLevel: minLevel)
        }.value
        self.entries = snapshot
    }
}

/// One row in the log list. Color-codes by severity, monospaced font for
/// scannable category/message, tap-to-copy for the composed message.
private struct DevLogRow: View {
    let entry: AppLogger.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                // Color-coded severity badge.
                Text(entry.level.rawValue.uppercased())
                    .font(.caption2.weight(.bold).monospaced())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(severityColor, in: RoundedRectangle(cornerRadius: 4))
                // Category — the part after "chattr." subsystem prefix.
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

    /// Map severity → color. Red for error/fault, orange for warning,
    /// yellow for notice, gray for info/debug. Matches the "more severe
    /// = more attention-grabbing" convention used by Console.app.
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
