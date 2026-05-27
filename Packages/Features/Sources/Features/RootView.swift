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

    /// App-wide cache of global badges + emotes. Owned here so it survives
    /// channel-list / chat-screen navigation but gets re-instantiated if the
    /// whole RootView is unmounted (e.g. on full sign-out — though we're
    /// keeping the data across sign-outs is also fine since it's not auth-specific).
    @State private var globalCatalog = GlobalCatalog()

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
        .environment(\.globalCatalog, globalCatalog)
        .onChange(of: accounts.first?.userId) { _, newId in
            // AccountStore is @MainActor; setActive is sync — no Task wrapper / await needed.
            // (The plan template had Task { await ... } from the older actor design.)
            if let newId {
                accountStore.setActive(userId: newId)
            }
        }
        // Pre-fetch global Twitch data once on first sign-in. `.task(id:)` re-fires
        // when the active userId changes (nil → userId, or A → B on account swap);
        // the catalog's `hasLoaded` guard makes subsequent fires no-ops, so we
        // don't refetch on account swap. Cancellation is automatic on view tear-down.
        .task(id: accounts.first?.userId) {
            guard let active = accounts.first else { return }
            await globalCatalog.load(account: active, accountStore: accountStore)
        }
    }
}
