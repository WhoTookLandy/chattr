import SwiftUI
import Accounts
import Core
import DesignSystem
import os

private let logger = AppLogger.make("Features.Settings")

/// Per-account settings: appearance mode and sign-out.
///
/// Pushed from the ChannelListScreen toolbar's gear button. The appearance
/// picker writes through `@AppStorage` so the app root (chattrApp) picks the
/// new value up immediately via `.preferredColorScheme(_:)`.
///
/// Why include sign-out here: it consolidates "things you do per-account" in
/// one place rather than scattering them across menus. The old toolbar menu
/// is removed.
public struct SettingsScreen: View {
    private let account: Account
    private let accountStore: AccountStore

    @AppStorage(AppearanceMode.storageKey) private var appearanceModeRaw: String = AppearanceMode.system.rawValue
    @State private var isSigningOut = false
    @State private var showingSignOutConfirm = false
    @State private var errorMessage: String?

    @Environment(\.dismiss) private var dismiss

    public init(account: Account, accountStore: AccountStore) {
        self.account = account
        self.accountStore = accountStore
    }

    /// Parsed appearance mode with safe fallback when the raw value drifts
    /// (e.g. a future build adds a new case, the user downgrades). The fallback
    /// to `.system` is the safest default — never traps the user in the wrong mode.
    private var appearanceMode: AppearanceMode {
        get { AppearanceMode(rawValue: appearanceModeRaw) ?? .system }
        nonmutating set { appearanceModeRaw = newValue.rawValue }
    }

    public var body: some View {
        Form {
            Section {
                // Segmented picker is the right control for 3 mutually-exclusive
                // options where users want a single tap, not a menu reveal.
                Picker("Theme", selection: Binding(
                    get: { appearanceMode },
                    set: { appearanceModeRaw = $0.rawValue }
                )) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Appearance")
            } footer: {
                Text("System follows your device's appearance setting.")
            }

            Section {
                Button(role: .destructive) {
                    showingSignOutConfirm = true
                } label: {
                    Label("Sign out @\(account.login)", systemImage: "rectangle.portrait.and.arrow.right")
                }
                .disabled(isSigningOut)
            } header: {
                Text("Account")
            } footer: {
                Text("You'll need to authorize chattr with Twitch again to use this account.")
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }

            // Developer tools — always visible for now. When the app ships
            // for real users we'll gate behind `#if DEBUG` or a hidden
            // tap-counter gesture; today there's no production audience so
            // a discoverable nav row is fine.
            //
            // The DevLogView reads from OSLogStore so it captures EVERY
            // log line emitted by chattr's subsystem since launch — no
            // additional instrumentation needed. Long-press a row to copy
            // its message to clipboard for sharing.
            Section {
                NavigationLink {
                    DevLogView()
                } label: {
                    Label("Recent Logs", systemImage: "doc.text.magnifyingglass")
                }
            } header: {
                Text("Developer")
            } footer: {
                Text("Live view of chattr's runtime logs (from OSLogStore). Useful for diagnosing why something didn't work.")
            }
        }
        .navigationTitle("Settings")
        // `.toolbarTitleDisplayMode` is cross-platform (iOS 17 / macOS 14+) —
        // newer replacement for the iOS-only `.navigationBarTitleDisplayMode`.
        .toolbarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Sign out of @\(account.login)?",
            isPresented: $showingSignOutConfirm,
            titleVisibility: .visible
        ) {
            Button("Sign Out", role: .destructive) {
                Task { await signOut() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll need to authorize chattr with Twitch again to use this account.")
        }
    }

    /// Mirrors ChannelListScreen.signOut(). After the @Query observing accounts
    /// sees the delete, RootView re-renders to SignInView automatically — no
    /// manual dismiss needed (the whole navigation stack unmounts).
    @MainActor
    private func signOut() async {
        isSigningOut = true
        defer { isSigningOut = false }
        do {
            try await accountStore.remove(account: account)
            logger.info("Signed out @\(account.login) from Settings")
        } catch {
            logger.error("Sign out had an error: \(error.localizedDescription)")
            errorMessage = "Sign out: \(error.localizedDescription)"
        }
    }
}
