import SwiftUI
import Accounts
import Core
import DesignSystem
import NukeUI
import os

private let logger = AppLogger.make("Features.Profile")

/// The "Profile" tab — entry point for everything user-centric: account
/// header (avatar + display name + login), appearance settings, developer
/// tools, and sign out.
///
/// ## Why this replaces the gear-in-toolbar pattern
///
/// Previously: ChannelListScreen had a gear icon in its toolbar that
/// pushed to a SettingsScreen. That worked but:
///   - The gear icon sat alone at the right edge of the toolbar (the
///     "lonely island" finding from earlier review).
///   - It meant "settings is hidden inside Follows," which is wrong —
///     settings is account-level, not follows-level.
///   - It also meant the bottom tab bar was only 2 tabs wide
///     (Follows + Chat), making iOS 26's tab bar capsule look
///     visually thin and "floaty."
///
/// Promoting Profile to its own tab fixes all three: the bar gets a third
/// affordance (wider, reads as proper chrome), the toolbar gets simpler
/// (no gear), and settings lives in the right place semantically.
///
/// ## Content
///
/// One Form with three sections:
///   1. Account header — avatar circle + display name + @login. Read-only
///      summary; tapping nothing for now (future: edit profile would go here).
///   2. Appearance — theme picker (system / light / dark).
///   3. Developer — Recent Logs nav link.
///   4. Sign-out destructive button at the bottom.
///
/// The previous `SettingsScreen` is deleted — its contents migrate here.
public struct ProfileScreen: View {
    private let account: Account
    private let accountStore: AccountStore

    @AppStorage(AppearanceMode.storageKey) private var appearanceModeRaw: String = AppearanceMode.system.rawValue
    @State private var isSigningOut = false
    @State private var showingSignOutConfirm = false
    @State private var errorMessage: String?

    public init(account: Account, accountStore: AccountStore) {
        self.account = account
        self.accountStore = accountStore
    }

    /// Parsed appearance mode with safe fallback when the raw value drifts
    /// (e.g. a future build adds a new case, the user downgrades). Fallback
    /// to `.system` is the safest default — never traps the user.
    private var appearanceMode: AppearanceMode {
        AppearanceMode(rawValue: appearanceModeRaw) ?? .system
    }

    public var body: some View {
        Form {
            // Account header — full-width banner-style row at the top of the
            // form. Uses `.listRowInsets` to remove the standard Form padding
            // so the header reads as a hero element, not a regular settings row.
            Section {
                AccountHeaderRow(account: account)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section {
                // Segmented picker for theme — three mutually-exclusive
                // options where one-tap selection beats menu-reveal.
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

            // Developer tools — always visible for now. When the app ships
            // for real users we'll gate behind `#if DEBUG` or a hidden
            // tap-counter gesture; today there's no production audience so
            // a discoverable nav row is fine.
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

            // Sign-out lives at the bottom — destructive actions stay
            // visually separated from positive controls (theme picker
            // above) so the user can't muscle-memory into one when
            // intending the other.
            Section {
                Button(role: .destructive) {
                    showingSignOutConfirm = true
                } label: {
                    Label("Sign out @\(account.login)", systemImage: "rectangle.portrait.and.arrow.right")
                }
                .disabled(isSigningOut)
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
        }
        .navigationTitle("Profile")
        // `.inlineLarge` keeps the title in the toolbar (no big drop-down
        // title) — consistent with the ChannelListScreen treatment. Saves
        // ~60pt of vertical space vs the default large-title mode.
        .toolbarTitleDisplayMode(.inlineLarge)
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

    /// Drop the SwiftData Account row + tear down keychain entries. The
    /// `@Query` in RootView reacts and re-renders SignInView automatically
    /// — no manual dismiss needed because the whole navigation stack
    /// unmounts.
    @MainActor
    private func signOut() async {
        isSigningOut = true
        defer { isSigningOut = false }
        do {
            try await accountStore.remove(account: account)
            logger.notice("Signed out @\(account.login, privacy: .public) from Profile")
        } catch {
            logger.error("Sign out had an error: \(error.localizedDescription, privacy: .public)")
            errorMessage = "Sign out: \(error.localizedDescription)"
        }
    }
}

/// Banner-style account row showing avatar + display name + @login.
/// Sits at the top of `ProfileScreen` as the visual identity anchor.
private struct AccountHeaderRow: View {
    let account: Account

    var body: some View {
        HStack(spacing: 14) {
            LazyImage(url: URL(string: account.profileImageURL)) { state in
                if let image = state.image {
                    image.resizable().scaledToFill()
                } else {
                    // Placeholder while loading or when the URL is nil
                    // (first sign-in before profile fetch completes).
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.secondary.opacity(0.5))
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text("@\(account.login)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
}
