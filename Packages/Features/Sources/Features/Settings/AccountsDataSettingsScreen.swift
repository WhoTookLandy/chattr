import SwiftUI
import SwiftData
import Accounts

/// Settings → Accounts & Data: signed-in accounts, who you've blocked, and
/// what chattr keeps on disk.
struct AccountsDataSettingsScreen: View {
    let accountStore: AccountStore
    /// Twitch client id, used by the account switcher's "Add Account".
    let clientId: String

    /// Same sort as RootView / the switcher (newest first). Only the count
    /// is shown here.
    @Query(sort: \Account.addedAt, order: .reverse)
    private var accounts: [Account]

    @State private var showingAccountSwitcher = false

    var body: some View {
        Form {
            Section {
                Button {
                    showingAccountSwitcher = true
                } label: {
                    SettingLabel(
                        "Manage Accounts",
                        systemImage: "person.2",
                        subtitle: accounts.count == 1 ? "1 account signed in" : "\(accounts.count) accounts signed in"
                    )
                }
            } header: {
                Text("Accounts")
            } footer: {
                Text("Switch between Twitch accounts, add another, or re-authorize one that has expired.")
            }

            Section {
                NavigationLink {
                    BlockedUsersScreen()
                } label: {
                    Label("Blocked Users", systemImage: "hand.raised")
                }
            } header: {
                Text("Privacy")
            } footer: {
                Text("Blocked users' messages are hidden in every chat. Blocks are saved to your Twitch account.")
            }

            Section {
                NavigationLink {
                    StorageSettingsScreen()
                } label: {
                    SettingLabel("Storage", systemImage: "internaldrive", subtitle: "Cached emotes and badges")
                }
            }
        }
        .navigationTitle("Accounts & Data")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $showingAccountSwitcher) {
            AccountSwitcherView(accountStore: accountStore, clientId: clientId)
        }
    }
}
