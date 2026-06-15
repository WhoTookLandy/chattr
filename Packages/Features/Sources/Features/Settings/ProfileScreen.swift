import SwiftUI
import SwiftData
import Accounts
import Core
import DesignSystem
import NukeUI
import os

private let logger = AppLogger.make("Features.Profile")

/// The You tab — entry point for everything user-centric: account
/// switching, settings, and sign out. Hosted by AppShell's TabView
/// inside its own NavigationStack; every child screen is a push.
///
/// ## Grouping rule
///
/// Sections group by what the user is *thinking about*, not by what the
/// code touches:
///   1. Account header — avatar + display name + @login; tap (or
///      long-press for the hot-switch menu) → account switcher.
///   2. **Chat** — how the transcript looks and behaves: Appearance,
///      Emotes, Filters, Highlights. Pure navigation rows; each feature
///      owns ALL its controls on its own page (no lone toggles mixed in
///      with links — that's how the old Highlight Sound toggle got
///      separated from the keywords it modified).
///   3. **Privacy** — Blocked Users. An account-level relationship, not
///      a chat-display preference.
///   4. **App** — chattr itself: Theme, Resume Last Chat, Storage.
///   5. **About** — What's New, Version (the 7-tap dev-tools unlock).
///   6. Developer (conditional) + destructive sign-out at the bottom.
public struct ProfileScreen: View {
    private let account: Account
    private let accountStore: AccountStore
    /// Twitch client id, used by the account switcher's "Add Account".
    private let clientId: String

    /// Stored as the enum directly — `AppearanceMode` is `RawRepresentable`
    /// over `String`, which `@AppStorage` supports natively (same pattern as
    /// `ChatAppearanceScreen`'s `loginNameDisplay`). A drifted/unknown raw
    /// value falls back to the `.system` default, so the explicit
    /// `?? .system` guard the old `String`-backed mirror needed is gone.
    @AppStorage(AppearanceMode.storageKey) private var appearanceMode: AppearanceMode = .system
    /// Whether visiting the Chats tab re-pushes the chat that was open
    /// when the scene was torn down. Read by ChatTabsScreen's scene
    /// restoration; default on (resume) matches pre-toggle behavior.
    @AppStorage("chattr.resumeLastChatOnLaunch") private var resumeLastChatOnLaunch = true
    @State private var isSigningOut = false
    @State private var showingSignOutConfirm = false
    @State private var errorMessage: String?

    /// Whether the account-switcher sheet is presented.
    @State private var showingAccountSwitcher = false

    /// All signed-in accounts — drives the header's long-press hot-switch
    /// menu. Same sort as RootView/switcher (newest first).
    @Query(sort: \Account.addedAt, order: .reverse)
    private var accounts: [Account]

    /// 7-tap counter on the version footer (release builds' dev-tools
    /// unlock). Session-scoped on purpose — partial taps don't persist.
    @State private var versionTapCount = 0

    /// Whether the Developer section is visible in release builds.
    /// Toggled by 7 taps on the version footer; persisted so the user
    /// doesn't re-unlock every launch. DEBUG builds bypass this.
    @AppStorage("chattr.devToolsUnlocked") private var devToolsUnlocked = false

    private var showDeveloperSection: Bool {
        #if DEBUG
        return true
        #else
        return devToolsUnlocked
        #endif
    }

    /// "1.2 (34)" — the first thing support asks for. Reads the app
    /// bundle (Bundle.main is the host app at runtime, not the Features
    /// package bundle). Shown as the detail of the About → Version row,
    /// which is also the 7-tap dev-tools unlock target.
    private var versionString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
    }

    public init(account: Account, accountStore: AccountStore, clientId: String) {
        self.account = account
        self.accountStore = accountStore
        self.clientId = clientId
    }

    public var body: some View {
        Form {
            // Account header — full-width banner-style row at the top of the
            // form. Uses `.listRowInsets` to remove the standard Form padding
            // so the header reads as a hero element, not a regular settings row.
            Section {
                // Tappable header → account switcher. The chevron signals
                // "there's more here." Plain button style so the row keeps
                // its custom layout instead of taking the system blue
                // tint treatment.
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
                // without the sheet round-trip. Tap stays "open the
                // switcher" (discoverable); the menu is the power-user
                // accelerator. Expired accounts route to the switcher,
                // which owns the re-authorize flow.
                .contextMenu {
                    ForEach(accounts) { other in
                        if other.userId == account.userId {
                            // Current account — checkmark, inert.
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

            // Chat — how the transcript looks and behaves. Pure
            // navigation rows: every control lives on its feature's own
            // page (mixed altitudes — a lone toggle among links — read
            // as clutter and made features hard to find).
            Section {
                NavigationLink {
                    ChatAppearanceScreen(currentUserLogin: account.login)
                } label: {
                    Label("Appearance", systemImage: "textformat.size")
                }
                NavigationLink {
                    EmoteSettingsScreen()
                } label: {
                    Label("Emotes", systemImage: "face.smiling")
                }
                NavigationLink {
                    ChatFiltersScreen()
                } label: {
                    Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
                }
                NavigationLink {
                    HighlightKeywordsScreen()
                } label: {
                    Label("Highlights", systemImage: "sparkles")
                }
            } header: {
                Text("Chat")
            } footer: {
                Text("How chat looks, which emotes show, what gets hidden, and the words that light up a message.")
            }

            // Privacy — who you don't want to hear from. Separate from
            // Chat: blocking is an account-level relationship, not a
            // display preference.
            Section {
                NavigationLink {
                    BlockedUsersScreen()
                } label: {
                    Label("Blocked Users", systemImage: "hand.raised")
                }
            } header: {
                Text("Privacy")
            }

            // App — preferences about chattr itself rather than chat
            // content. Theme stays inline (three exclusive options;
            // one-tap beats a page round-trip).
            Section {
                Picker(selection: $appearanceMode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                } label: {
                    Label("Theme", systemImage: "circle.lefthalf.filled")
                }
                Toggle(isOn: $resumeLastChatOnLaunch) {
                    Label("Resume Last Chat", systemImage: "arrow.uturn.forward")
                }
                NavigationLink {
                    StorageSettingsScreen()
                } label: {
                    Label("Storage", systemImage: "internaldrive")
                }
            } header: {
                Text("App")
            } footer: {
                Text("Resume drops you straight back into the chat you had open. Theme follows your device's appearance when set to System.")
            }

            // About — version as a proper row (copy-friendly, and the
            // 7-tap dev-tools unlock target) instead of a floating
            // footer at the very bottom of the form.
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
            } header: {
                Text("About")
            }

            // Developer tools — always visible in DEBUG; in release builds
            // hidden behind 7 taps on the version footer (the classic),
            // persisted via `devToolsUnlocked`.
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
                    Text("Live view of chattr's runtime logs (from OSLogStore). Useful for diagnosing why something didn't work.")
                }
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
                        // The destructive role reddens the title but the
                        // icon keeps the app tint — force the whole label
                        // red so the row reads as one destructive unit.
                        .foregroundStyle(.red)
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
        // Subtle confirmation when the 7th tap lands (either direction).
        .sensoryFeedback(.success, trigger: devToolsUnlocked)
        .navigationTitle("You")
        // `.inlineLarge` keeps the title in the toolbar (no big drop-down
        // title) — consistent with the ChannelListScreen treatment. Saves
        // ~60pt of vertical space vs the default large-title mode.
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
