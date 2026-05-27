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
    /// Owned by chattrApp, not by RootView — re-instantiating RootView (e.g.
    /// on a future hot reload or scene rebuild) shouldn't blow away in-flight
    /// chat sessions.
    private let channelSessionRegistry: ChannelSessionRegistry

    @Query(sort: \Account.addedAt, order: .reverse)
    private var accounts: [Account]

    /// App-wide cache of global badges + emotes. Owned here so it survives
    /// channel-list / chat-screen navigation but gets re-instantiated if the
    /// whole RootView is unmounted (e.g. on full sign-out — though we're
    /// keeping the data across sign-outs is also fine since it's not auth-specific).
    @State private var globalCatalog = GlobalCatalog()

    /// Cache of the active account's followed channels + enrichment data.
    /// Owned here so the data survives chat-screen push/pop — previously
    /// every back-nav refetched the entire follow list because the state
    /// lived in ChannelListScreen's `@State` and `.task` re-fired on appear.
    @State private var followsStore = FollowsStore()

    public init(
        accountStore: AccountStore,
        clientId: String,
        channelSessionRegistry: ChannelSessionRegistry
    ) {
        self.accountStore = accountStore
        self.clientId = clientId
        self.channelSessionRegistry = channelSessionRegistry
    }

    public var body: some View {
        Group {
            if let active = accounts.first {
                AppShell(account: active, accountStore: accountStore)
            } else {
                SignInView(accountStore: accountStore, clientId: clientId)
            }
        }
        .environment(\.globalCatalog, globalCatalog)
        .environment(\.followsStore, followsStore)
        .environment(\.channelSessionRegistry, channelSessionRegistry)
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
        // Trigger initial loads on first sign-in (or account swap).
        //
        // - All list (`loadAllIfNeeded`): cached per account. Runs once, then
        //   skipped until the user signs out / swaps accounts.
        // - Live list (`refreshLive`): not cached. Refreshes whenever this
        //   task re-fires. We do it here so the Live tab has data ready when
        //   the user first opens the Follows tab — they don't have to wait.
        //
        // Two separate `.task(id:)` modifiers — both fire concurrently on
        // appearance. Can't use `withTaskGroup` because `Account` is a
        // SwiftData `@Model` (non-Sendable), and TaskGroup's child closures
        // would need to send it across an isolation boundary. Two .task
        // modifiers each run on @MainActor (no boundary crossing), but
        // suspend independently on network I/O — so the calls interleave
        // and effectively run in parallel anyway.
        .task(id: accounts.first?.userId) {
            guard let active = accounts.first else { return }
            await followsStore.refreshLive(account: active, accountStore: accountStore)
        }
        .task(id: accounts.first?.userId) {
            guard let active = accounts.first else { return }
            await followsStore.loadAllIfNeeded(account: active, accountStore: accountStore)
        }
    }
}
