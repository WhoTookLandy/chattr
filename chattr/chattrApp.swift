//
//  chattrApp.swift
//  chattr
//

import Accounts
import Channels
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
    static let clientId = "u39wc5fdx2ser9lkf8ntl9dzyj51dh"

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

    var body: some Scene {
        WindowGroup {
            RootView(accountStore: accountStore, clientId: Self.clientId)
                .modelContainer(modelContainer)
        }
    }
}
