import SwiftUI

/// Settings → About: release notes, the version (also the 7-tap dev-tools
/// unlock), and the Developer section once unlocked.
struct AboutSettingsScreen: View {
    /// 7-tap counter on the Version row (release builds' dev-tools unlock).
    /// Session-scoped on purpose — partial taps don't persist.
    @State private var versionTapCount = 0

    /// Whether the Developer section is visible in release builds. Toggled
    /// by 7 taps on the Version row; persisted so the user doesn't
    /// re-unlock every launch. DEBUG builds bypass this.
    @AppStorage("chattr.devToolsUnlocked") private var devToolsUnlocked = false

    private var showDeveloperSection: Bool {
        #if DEBUG
        return true
        #else
        return devToolsUnlocked
        #endif
    }

    /// "1.2 (34)" — the first thing support asks for. Reads the app bundle
    /// (Bundle.main is the host app at runtime, not the Features package).
    private var versionString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
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
                    Text(versionString)
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

            // Always visible in DEBUG; in release builds hidden behind 7
            // taps on the Version row.
            if showDeveloperSection {
                Section {
                    NavigationLink {
                        DevLogView()
                    } label: {
                        Label("Recent Logs", systemImage: "doc.text.magnifyingglass")
                    }
                } header: {
                    Text("Developer")
                } footer: {
                    Text("Live view of chattr's runtime logs. Useful for diagnosing why something didn't work.")
                }
            }
        }
        // Subtle confirmation when the 7th tap lands (either direction).
        .sensoryFeedback(.success, trigger: devToolsUnlocked)
        .navigationTitle("About")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
