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

    /// The device's active-account selection, stored in UserDefaults by
    /// `AccountStore.selectAccount` / `.add` / `.remove`. `@AppStorage`
    /// observes the key via KVO, so writing it from AccountStore
    /// re-renders this view. Empty string = no explicit selection →
    /// `activeAccount` falls back to most-recently-added.
    @AppStorage(AccountStore.activeAccountUserIdKey) private var activeAccountUserId: String = ""

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

    /// Launch-time chat image prefetcher. Warms Nuke's memory + disk
    /// caches with Twitch global emotes + global badges (memory),
    /// AND the user's subscribed-channel emote set (disk). Per-channel
    /// badges are prefetched separately by `ChatScreen` on channel
    /// entry, also via this prefetcher (so they share Nuke pipeline
    /// concurrency limits).
    @State private var chatImagePrefetcher = ChatImagePrefetcher()

    public init(
        accountStore: AccountStore,
        clientId: String,
        channelSessionRegistry: ChannelSessionRegistry
    ) {
        self.accountStore = accountStore
        self.clientId = clientId
        self.channelSessionRegistry = channelSessionRegistry
    }

    /// The account to show. Resolves the stored active-account selection
    /// against the current account list; falls back to most-recently-added
    /// (`accounts.first`, since the @Query sorts by addedAt desc) when
    /// there's no stored selection or it points at a removed account.
    private var activeAccount: Account? {
        if !activeAccountUserId.isEmpty,
           let match = accounts.first(where: { $0.userId == activeAccountUserId }) {
            return match
        }
        return accounts.first
    }

    public var body: some View {
        // Configure Nuke's shared image pipeline with chattr-tuned
        // memory/disk cache limits. Synchronous, idempotent — first call
        // wins; subsequent calls are no-ops. Done here so it lands
        // before any LazyImage materializes (badges/emotes/avatars).
        let _ = { ImagePipelineSetup.configure() }()
        Group {
            if let active = activeAccount {
                AppShell(account: active, accountStore: accountStore, clientId: clientId)
                    // `.id(userId)` forces a fresh AppShell when the active
                    // account changes (switch / add / remove). A new account
                    // means new chat sessions, a new follow list, new
                    // emote+badge prefetch — a clean slate is correct, and
                    // far simpler than threading account-change invalidation
                    // through every child store.
                    .id(active.userId)
            } else {
                SignInView(accountStore: accountStore, clientId: clientId)
            }
        }
        .environment(\.globalCatalog, globalCatalog)
        .environment(\.followsStore, followsStore)
        .environment(\.channelSessionRegistry, channelSessionRegistry)
        .environment(\.chatImagePrefetcher, chatImagePrefetcher)
        .onChange(of: activeAccount?.userId) { _, newId in
            // Keep AccountStore's in-memory activeUserId in sync with the
            // rendered account — covers the cold-start case where the
            // @AppStorage value was restored from UserDefaults but
            // setActive hasn't been called yet this launch.
            if let newId {
                accountStore.setActive(userId: newId)
            }
        }
        // Pre-fetch global Twitch data once on first sign-in. `.task(id:)` re-fires
        // when the active userId changes (nil → userId, or A → B on account swap);
        // the catalog's `hasLoaded` guard makes subsequent fires no-ops, so we
        // don't refetch on account swap. Cancellation is automatic on view tear-down.
        //
        // We CHAIN the global emote image prefetch onto this task —
        // GlobalCatalog populates `globalEmotes` (metadata only) and we
        // immediately hand the URL list to Nuke's ImagePrefetcher for
        // memory-cache warming. Sequential because the prefetch needs
        // the catalog's emote IDs; both await calls run on @MainActor,
        // no concurrency cost vs splitting into two tasks.
        .task(id: activeAccount?.userId) {
            guard let active = activeAccount else { return }
            await globalCatalog.load(account: active, accountStore: accountStore)
            // After GlobalCatalog populates, kick image prefetches for
            // BOTH global emotes AND global badges. Both go into Nuke's
            // memory cache (they appear in nearly every chat message,
            // so the decoded image is worth the RAM).
            chatImagePrefetcher.prefetchGlobalEmotes(Array(globalCatalog.globalEmotes.values))
            chatImagePrefetcher.prefetchGlobalBadges(globalCatalog.globalBadges)
        }
        // User-subscribed emote image prefetch. Walks Helix's paginated
        // `/chat/emotes/user` endpoint and disk-caches every URL. Runs
        // INDEPENDENTLY from the global catalog load — they're two
        // different endpoints with no data dependency between them.
        //
        // Requires the `user:read:emotes` scope (added to SignInView).
        // Accounts that signed in before we added the scope will get
        // an `unauthorized` error which the prefetcher handles
        // silently — the app keeps working, just falls back to
        // fetch-on-first-display.
        .task(id: activeAccount?.userId) {
            guard let active = activeAccount else { return }
            await chatImagePrefetcher.prefetchUserSubscribedEmotes(
                account: active,
                accountStore: accountStore
            )
        }
        // Cold-start EventSub zombie cleanup. Reap dead subscriptions a previous
        // crash/force-quit left behind so they stop counting against Twitch's
        // per-app quota. Best-effort; runs concurrently with the prefetch tasks
        // and with session startup (it only deletes non-enabled subs, so it can't
        // touch a live subscription). `.task(id:)` re-fires on account swap.
        .task(id: activeAccount?.userId) {
            guard let active = activeAccount else { return }
            await channelSessionRegistry.cleanupDisconnectedSubscriptions(forAccountUserId: active.userId)
        }
        // One-shot Keychain mirror: if the user has a valid TwitchKit
        // token but nothing in our chattr-side refresh cache (i.e. they
        // upgraded across the OAuthRefreshTokenCache rollout), copy the
        // refresh_token over so a future refresh failure can recover.
        // `warmRefreshTokenCacheIfNeeded` is a no-op once the cache is
        // populated, so this is cheap on subsequent launches.
        .task(id: activeAccount?.userId) {
            guard let active = activeAccount else { return }
            await accountStore.warmRefreshTokenCacheIfNeeded(for: active)
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
        .task(id: activeAccount?.userId) {
            guard let active = activeAccount else { return }
            await followsStore.refreshLive(account: active, accountStore: accountStore)
        }
        .task(id: activeAccount?.userId) {
            guard let active = activeAccount else { return }
            await followsStore.loadAllIfNeeded(account: active, accountStore: accountStore)
        }
    }
}
