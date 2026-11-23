import SwiftUI
import Core

/// Settings → About: release notes, the version (also the 7-tap dev-tools
/// unlock in App Store builds), and the Developer section (shown automatically
/// in Debug and TestFlight builds, or once unlocked).
struct AboutSettingsScreen: View {
    /// 7-tap counter on the Version row (App Store builds' dev-tools unlock).
    /// Session-scoped on purpose — partial taps don't persist.
    @State private var versionTapCount = 0

    /// Whether the Developer section is manually unlocked in App Store builds.
    @AppStorage(DeveloperSettings.devToolsUnlockedKey) private var devToolsUnlocked = false

    /// Opt-in live diagnostic HUD overlaid on `ChatScreen`.
    @AppStorage(DeveloperSettings.chatDebugHUDKey) private var showChatDebugHUD = false

    /// Brief confirmation state after copying a diagnostic report.
    @State private var copiedReport = false

    private var showDeveloperSection: Bool {
        DeveloperSettings.isAutomaticallyUnlocked || devToolsUnlocked
    }

    /// "1.2 (34)" in App Store builds, "1.2 (34) · TestFlight" in TestFlight,
    /// "1.2 (34) · Debug" in Debug.
    private var versionLabel: String {
        let base = DeveloperSettings.versionString
        let channel = DeveloperSettings.buildChannel
        return channel == "Release" ? base : "\(base) · \(channel)"
    }

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    WhatsNewScreen()
                } label: {
                    Label("What's New", systemImage: "megaphone")
                }
                HStack {
                    Label("Version", systemImage: "info.circle")
                    Spacer()
                    Text(versionLabel)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    versionTapCount += 1
                    if versionTapCount >= 7 {
                        versionTapCount = 0
                        devToolsUnlocked.toggle()
                    }
                }
            }

            // Always visible in Debug & TestFlight; in App Store builds hidden
            // behind 7 taps on the Version row.
            if showDeveloperSection {
                Section {
                    NavigationLink {
                        DevLogView()
                    } label: {
                        Label("Recent Logs", systemImage: "doc.text.magnifyingglass")
                    }
                    Toggle(isOn: $showChatDebugHUD) {
                        Label("Chat Debug HUD", systemImage: "gauge.with.dots.needle.33percent")
                    }
                    Button {
                        copyDiagnosticReport()
                    } label: {
                        Label(
                            copiedReport ? "Copied Diagnostic Report" : "Copy Diagnostic Report",
                            systemImage: copiedReport ? "checkmark.circle.fill" : "doc.on.doc"
                        )
                    }
                } header: {
                    Text("Developer")
                } footer: {
                    Text("Runtime logs, live chat layout HUD, and one-tap diagnostic export for TestFlight bug reports.")
                }
            }
        }
        // Subtle confirmation when the 7th tap lands or report is copied.
        .appSensoryFeedback(.success, trigger: devToolsUnlocked)
        .appSensoryFeedback(.success, trigger: copiedReport) { _, copied in copied }
        .navigationTitle("About")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func copyDiagnosticReport() {
        Task {
            let (entries, previous) = await Task.detached(priority: .userInitiated) {
                (
                    AppLogger.recentEntries(limit: 1_000, minLevel: .debug),
                    AppLogger.previousSessionLog()
                )
            }.value
            let report = DiagnosticReportBuilder.build(
                entries: entries,
                previousSessionLog: previous
            )
            DeveloperSettings.copyToClipboard(report)
            copiedReport = true
            try? await Task.sleep(for: .seconds(2))
            copiedReport = false
        }
    }
}
