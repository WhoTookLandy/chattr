import SwiftUI
import Accounts

/// Routes a `SettingsDestination` to its screen. The single place a new
/// settings screen gets wired in (the exhaustive `switch` makes a missing
/// case a compile error). Used by both the root's category rows and its
/// search results, so a result always lands on the same screen the user
/// would reach by browsing.
struct SettingsDestinationView: View {
    let destination: SettingsDestination
    let account: Account
    let accountStore: AccountStore
    let clientId: String

    var body: some View {
        switch destination {
        case .category(.appearance):
            AppearanceSettingsScreen(currentUserLogin: account.login)
        case .category(.chat):
            ChatSettingsScreen()
        case .category(.videoAndDevice):
            VideoDeviceSettingsScreen()
        case .category(.accountsAndData):
            AccountsDataSettingsScreen(accountStore: accountStore, clientId: clientId)
        case .category(.about):
            AboutSettingsScreen()
        case .highlights:
            HighlightKeywordsScreen()
        case .filters:
            ChatFiltersScreen()
        case .emotes:
            EmoteSettingsScreen()
        case .landscape:
            LandscapeSettingsScreen()
        case .blockedUsers:
            BlockedUsersScreen()
        case .storage:
            StorageSettingsScreen()
        case .whatsNew:
            WhatsNewScreen()
        }
    }
}
