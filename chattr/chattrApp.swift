//
//  chattrApp.swift
//  chattr
//

import Accounts
import Channels
import DesignSystem
import Features
import SwiftData
import SwiftUI
import TwitchKit

@main
struct chattrApp: App {
    // ────────────────────────────────────────────────────────────────────────
    // ⚠️ REPLACE `TWITCH_CLIENT_ID_HERE` with the Client ID from dev.twitch.tv
    // for the chattr application Andrew registered. Note: this is the public
    // client ID, not the client secret — that's fine to commit. For Twitch's
    // authorization-code flow with a mobile/installed app, the client secret
    // is NOT required when using PKCE. (TwitchKit's TwitchOAuthClient handles
    // the flow.)
    // ────────────────────────────────────────────────────────────────────────
    static let clientId = "b3lzm4vxuqw81u2gb478deff8o3tmh"

    let modelContainer: ModelContainer
    let accountStore: AccountStore

    init() {
        do {
            let container = try ModelContainer(for: Account.self, JoinedChannel.self)
            self.modelContainer = container
            self.accountStore = AccountStore(modelContainer: container, clientId: Self.clientId)
        } catch {
            fatalError("Failed to initialize SwiftData: \(error)")
        }
    }

    /// Observed by `@AppStorage`; SettingsScreen writes through the same key
    /// so changes propagate without manual notification plumbing.
    @AppStorage(AppearanceMode.storageKey) private var appearanceModeRaw: String = AppearanceMode.system.rawValue

    var body: some Scene {
        WindowGroup {
            RootView(accountStore: accountStore, clientId: Self.clientId)
                .modelContainer(modelContainer)
                // nil = follow system (the default). SwiftUI's preferredColorScheme
                // recurses through child environments, so all sheets/navs honor it.
                .preferredColorScheme(
                    (AppearanceMode(rawValue: appearanceModeRaw) ?? .system).preferredColorScheme
                )
        }
    }
}
