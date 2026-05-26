import SwiftUI
import SwiftData
import Accounts
import Channels
import TwitchKit
import Core
import os

private let logger = AppLogger.make("Features.Root")

/// The app's root view. Decides between sign-in flow and the main app shell.
///
/// `accounts` is driven by SwiftData's `@Query` so it auto-refreshes when
/// `AccountStore.add(...)` inserts a new row.
public struct RootView: View {
    private let accountStore: AccountStore
    private let clientId: String

    @Query(sort: \Account.addedAt, order: .reverse)
    private var accounts: [Account]

    public init(accountStore: AccountStore, clientId: String) {
        self.accountStore = accountStore
        self.clientId = clientId
    }

    public var body: some View {
        Group {
            if let active = accounts.first {
                NavigationStack {
                    ChannelListScreen(account: active, accountStore: accountStore)
                }
            } else {
                SignInView(accountStore: accountStore, clientId: clientId)
            }
        }
        .onChange(of: accounts.first?.userId) { _, newId in
            // AccountStore is @MainActor; setActive is sync — no Task wrapper / await needed.
            // (The plan template had Task { await ... } from the older actor design.)
            if let newId {
                accountStore.setActive(userId: newId)
            }
        }
    }
}
