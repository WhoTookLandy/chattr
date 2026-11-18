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
/// All state + side effects live in `DevLogModel` (its own file).
/// This view is a pure renderer. The split enables unit-testing
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
        // Hide the tab bar while this view is on screen —
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
                // Same Liquid Glass pattern as ChatTabStrip — adjacent pill
                // chips morph fluidly when categories appear/disappear,
                // and active state uses `.regular.tint(accent)` so the
                // material itself takes the color rather than overlaying
                // a flat fill. Pattern consistency with the main app
                // chrome; dev-only view but worth aligning.
                GlassEffectContainer(spacing: 6) {
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
        }
        .buttonStyle(.plain)
        .glassEffect(
            // Per-branch `.interactive()` — same constraint as ChatTabStrip:
            // ternary + chained method call won't unify across the two
            // leaf types (tinted vs untinted Glass).
            isActive
                ? .regular.tint(Color.accentColor).interactive()
                : .regular.interactive(),
            in: Capsule()
        )
    }
}
