import SwiftUI
import SwiftData
import Accounts
import Core
import os

private let logger = AppLogger.make("Features.Profile")

/// The Settings root (reached from the avatar on Home). Everything
/// user-centric starts here: the account header, one row per settings
/// category, search across every setting, and sign out.
///
/// ## Layout
///
///   1. Account header — avatar + display name + @login; tap (or
///      long-press for the hot-switch menu) → account switcher.
///   2. Category rows — Appearance, Chat, Video & Device, Accounts & Data,
///      then About. Each row shows an icon, the title, and a one-line
///      summary of what's inside (`SettingsCategory.summary`); each pushes
///      its category screen, which owns all of its controls. The root holds
///      no toggles of its own.
///   3. Destructive sign-out at the bottom, visually apart from everything
///      else.
///
/// ## Search
///
/// The search field matches setting titles and keywords across every
/// category (`SettingsRegistry.search`) and replaces the category list with
/// results while there's a query. Tapping a result pushes the screen that
/// holds that setting — the same screen browsing would reach, routed by
/// `SettingsDestinationView`. To make a new setting findable, add one line
/// to `SettingsRegistry.entries`.
///
/// ## Performance
///
/// This screen and its category screens read preferences through narrow
/// `@AppStorage` keys only. Nothing here is observed by chat views, so
/// browsing or searching settings never re-renders a transcript; flipping a
/// setting re-renders exactly the views that read that key.
public struct ProfileScreen: View {
    private let account: Account
    private let accountStore: AccountStore
    /// Twitch client id, used by the account switcher's "Add Account".
    private let clientId: String

    @State private var isSigningOut = false
    @State private var showingSignOutConfirm = false
    @State private var errorMessage: String?

    /// Whether the account-switcher sheet is presented.
    @State private var showingAccountSwitcher = false

    /// The search field's text. Results are derived from it in `body` —
    /// a cheap filter over the static registry, nothing cached or observed.
    @State private var searchText = ""

    /// All signed-in accounts — drives the header's long-press hot-switch
    /// menu. Same sort as RootView/switcher (newest first).
    @Query(sort: \Account.addedAt, order: .reverse)
    private var accounts: [Account]

    /// Categories shown in the main group; About sits in its own section
    /// below, apart from the preferences.
    private static let preferenceCategories: [SettingsCategory] = [
        .appearance, .chat, .videoAndDevice, .accountsAndData,
    ]

    public init(account: Account, accountStore: AccountStore, clientId: String) {
        self.account = account
        self.accountStore = accountStore
        self.clientId = clientId
    }

    public var body: some View {
        let isSearching = !searchText.trimmingCharacters(in: .whitespaces).isEmpty
        Form {
            if isSearching {
                searchResults
            } else {
                accountHeader
                categories
                signOutSection
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }
        }
        .searchable(text: $searchText, placement: Self.searchPlacement, prompt: "Search Settings")
        .autocorrectionDisabled()
        .navigationTitle("Settings")
        // `.inlineLarge` keeps the title in the toolbar (no big drop-down
        // title) — consistent with the ChannelListScreen treatment.
        .toolbarTitleDisplayMode(.inlineLarge)
        .sheet(isPresented: $showingAccountSwitcher) {
            AccountSwitcherView(accountStore: accountStore, clientId: clientId)
        }
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

    /// Always-visible field under the title on iOS, so search is
    /// discoverable without pulling the list down.
    private static var searchPlacement: SearchFieldPlacement {
        #if os(iOS)
        return .navigationBarDrawer(displayMode: .always)
        #else
        return .automatic
        #endif
    }

    // MARK: - Sections

    /// Full-width banner-style row at the top. `.listRowInsets` removes the
    /// standard Form padding so it reads as a hero element.
    private var accountHeader: some View {
        Section {
            // Tappable header → account switcher. The chevron signals
            // "there's more here." Plain button style so the row keeps its
            // custom layout instead of the tint treatment.
            Button {
                showingAccountSwitcher = true
            } label: {
                HStack {
                    AccountRow(account: account, style: .banner)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            // Long-press hot-switch: jump straight to another account
            // without the sheet round-trip. Expired accounts route to the
            // switcher, which owns the re-authorize flow.
            .contextMenu {
                ForEach(accounts) { other in
                    if other.userId == account.userId {
                        Button {} label: {
                            Label(other.displayName, systemImage: "checkmark")
                        }
                        .disabled(true)
                    } else if other.needsReauth {
                        Button {
                            showingAccountSwitcher = true
                        } label: {
                            Label("\(other.displayName) — expired", systemImage: "clock.badge.exclamationmark")
                        }
                    } else {
                        Button {
                            accountStore.selectAccount(other)
                        } label: {
                            Label(other.displayName, systemImage: "person.crop.circle")
                        }
                    }
                }
                Divider()
                Button {
                    showingAccountSwitcher = true
                } label: {
                    Label("Manage Accounts…", systemImage: "person.2")
                }
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
    }

    @ViewBuilder
    private var categories: some View {
        Section {
            ForEach(Self.preferenceCategories) { category in
                categoryLink(category)
            }
        }
        Section {
            categoryLink(.about)
        }
    }

    private func categoryLink(_ category: SettingsCategory) -> some View {
        NavigationLink {
            destination(.category(category))
        } label: {
            SettingsCategoryRow(category: category)
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        let results = SettingsRegistry.search(searchText)
        if results.isEmpty {
            Section {
                ContentUnavailableView.search(text: searchText)
            }
        } else {
            Section {
                ForEach(results) { entry in
                    NavigationLink {
                        destination(entry.destination)
                    } label: {
                        SettingsSearchResultRow(entry: entry)
                    }
                }
            }
        }
    }

    /// Sign-out lives at the bottom — destructive actions stay visually
    /// separated from everything else so the user can't muscle-memory into
    /// it.
    private var signOutSection: some View {
        Section {
            Button(role: .destructive) {
                showingSignOutConfirm = true
            } label: {
                Label("Sign out @\(account.login)", systemImage: "rectangle.portrait.and.arrow.right")
                    // The destructive role reddens the title but the icon
                    // keeps the app tint — force the whole label red so the
                    // row reads as one destructive unit.
                    .foregroundStyle(.red)
            }
            .disabled(isSigningOut)
        } footer: {
            Text("You'll need to authorize chattr with Twitch again to use this account.")
        }
    }

    private func destination(_ destination: SettingsDestination) -> some View {
        SettingsDestinationView(
            destination: destination,
            account: account,
            accountStore: accountStore,
            clientId: clientId
        )
    }

    // MARK: - Sign out

    /// Drop the SwiftData Account row + tear down keychain entries. The
    /// `@Query` in RootView reacts and re-renders SignInView automatically
    /// — no manual dismiss needed because the whole navigation stack
    /// unmounts.
    @MainActor
    private func signOut() async {
        isSigningOut = true
        defer { isSigningOut = false }
        // Read before removal: the row is deleted once `remove` returns, and
        // touching a deleted SwiftData model's properties traps.
        let login = account.login
        do {
            try await accountStore.remove(account: account)
            logger.notice("Signed out @\(login, privacy: .public) from Settings")
        } catch {
            logger.error("Sign out had an error: \(error.localizedDescription, privacy: .public)")
            errorMessage = "Sign out: \(error.localizedDescription)"
        }
    }
}
