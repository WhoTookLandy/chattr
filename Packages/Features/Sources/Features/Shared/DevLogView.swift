import SwiftUI
import Observation
import Core

/// Dev / TestFlight log viewer and diagnostic report exporter.
///
/// Reads from `DiagnosticLogStore` (via `AppLogger.recentEntries`) so `.debug`
/// and `.info` entries are preserved on TestFlight devices without Xcode
/// attached, alongside live `ChatDiagnostics` layout snapshots and one-tap
/// Copy / Share report export.
public struct DevLogView: View {
    @State private var model = DevLogModel()
    @State private var showLiveSnapshot = false
    @State private var copiedFeedback = false
    @State private var shareReport = ""
    @AppStorage(DeveloperSettings.chatDebugHUDKey) private var showChatDebugHUD = false

    public init() {}

    public var body: some View {
        @Bindable var bindable = model
        List {
            liveStateSection

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
        .searchable(text: $bindable.searchText, prompt: "Filter logs")
        .navigationTitle("Recent Logs")
        .toolbarTitleDisplayMode(.inline)
        #if os(iOS)
        .toolbar(.hidden, for: .tabBar)
        #endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    copyReport(filteredOnly: false)
                } label: {
                    Image(systemName: copiedFeedback ? "checkmark" : "doc.on.doc")
                }
                .accessibilityLabel("Copy diagnostic report")

                ShareLink(
                    item: shareReport.isEmpty ? model.buildReport(filteredOnly: false, includePreviousSession: true) : shareReport,
                    subject: Text("chattr Diagnostic Report (\(DeveloperSettings.versionString))")
                ) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share diagnostic report")

                Menu {
                    Button {
                        copyReport(filteredOnly: true)
                    } label: {
                        Label("Copy Filtered Logs Only", systemImage: "line.3.horizontal.decrease.circle")
                    }
                    Toggle(isOn: $showChatDebugHUD) {
                        Label("Chat Debug HUD", systemImage: "gauge.with.dots.needle.33percent")
                    }
                    Divider()
                    Button(role: .destructive) {
                        Task {
                            await model.clear()
                            shareReport = model.buildReport(filteredOnly: false, includePreviousSession: true)
                        }
                    } label: {
                        Label("Clear Logs", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More log actions")
            }
        }
        .appSensoryFeedback(.success, trigger: copiedFeedback) { _, copied in copied }
        .refreshable {
            await model.load()
            shareReport = model.buildReport(filteredOnly: false, includePreviousSession: true)
        }
        .task {
            await model.load()
            shareReport = model.buildReport(filteredOnly: false, includePreviousSession: true)
        }
    }

    private func copyReport(filteredOnly: Bool) {
        let report = model.buildReport(
            filteredOnly: filteredOnly,
            includePreviousSession: !filteredOnly
        )
        DeveloperSettings.copyToClipboard(report)
        copiedFeedback = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copiedFeedback = false
        }
    }

    @ViewBuilder
    private var liveStateSection: some View {
        let pager = ChatDiagnostics.shared.pager
        let pages = ChatDiagnostics.shared.mergedPages()
        Section {
            DisclosureGroup(isExpanded: $showLiveSnapshot) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(pager?.summaryLine ?? "Pager: (none recorded)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                    if pages.isEmpty {
                        Text("Pages: (none mounted)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(pages, id: \.channelLogin) { page in
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(page.summaryLines, id: \.self) { line in
                                    Text(line)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.primary)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "waveform.path.ecg")
                        .foregroundStyle(.secondary)
                    Text("Live Chat Snapshot")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text("\(pages.count) page(s)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
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
            isActive
                ? .regular.tint(Color.accentColor).interactive()
                : .regular.interactive(),
            in: Capsule()
        )
    }
}
