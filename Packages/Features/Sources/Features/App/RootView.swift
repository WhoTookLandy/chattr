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

    // Chat appearance preferences — read here (the app's root) so one
    // environment injection covers every chat surface at once: live chat,
    // the thread sheet, and the settings screen's preview. @AppStorage
    // observes the keys via KVO, so ChatAppearanceScreen's writes
    // re-render all of them live.
    @AppStorage(ChatAppearance.textSizePointsKey) private var chatTextSizePoints: Double = ChatAppearance.defaultTextSizePoints
    @AppStorage(ChatAppearance.showTimestampsKey) private var chatShowTimestamps: Bool = false
    @AppStorage(ChatAppearance.showBadgesKey) private var chatShowBadges: Bool = true
    @AppStorage(ChatAppearance.animatedEmotesKey) private var chatAnimatedEmotes: Bool = true
    @AppStorage(ChatAppearance.edgeToEdgeKey) private var chatEdgeToEdge: Bool = false
    @AppStorage(ChatAppearance.loginNameDisplayKey) private var chatLoginNameDisplay: ChatAppearance.LoginNameDisplay = .displayFirst
    /// Observed only to re-fire the registry-sync `.task(id:)` below when
    /// the user changes the setting — consumers read the value through
    /// `ChatAppearance.chatHistoryLines()` (which also validates it).
    @AppStorage(ChatAppearance.chatHistoryLinesKey) private var chatHistoryLines: Int = ChatAppearance.defaultChatHistoryLines

    /// Dynamic Type multiplier for the chat text size: 1.0 at the standard
    /// content size, growing/shrinking with the user's systemwide setting.
    /// Applied to the slider-chosen base points below, so chat text (and
    /// emotes/badges via `imageScale`) keeps tracking Dynamic Type the way
    /// the old text-style-based steps did. `@ScaledMetric` re-renders this
    /// view on content-size changes, which re-injects the environment.
    @ScaledMetric(relativeTo: .callout) private var chatTypeScale: CGFloat = 1.0

    /// Assembled appearance for environment injection.
    private var chatAppearance: ChatAppearance {
        ChatAppearance(
            textSizePoints: chatTextSizePoints * chatTypeScale,
            showTimestamps: chatShowTimestamps,
            showBadges: chatShowBadges,
            animatedEmotes: chatAnimatedEmotes,
            edgeToEdge: chatEdgeToEdge,
            loginNameDisplay: chatLoginNameDisplay
        )
    }

    /// App-wide cache of global badges + emotes. Owned here so it survives
    /// channel-list / chat-screen navigation but gets re-instantiated if the
    /// whole RootView is unmounted (e.g. on full sign-out — though we're
    /// keeping the data across sign-outs is also fine since it's not auth-specific).
    @State private var globalCatalog = GlobalCatalog()

    /// Per-active-account blocked-user store. Re-created when the active
    /// account changes. Seeded in a launch .task and injected via the
    /// environment, like globalCatalog.
    @State private var blockStore: BlockStore?

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
        // Carry the pre-slider discrete text-size choice into the points
        // key (no-op once migrated or when the user has set the slider).
        ChatAppearance.migrateLegacyTextSizeIfNeeded()
    }

    /// The account to show. Resolves the stored active-account selection
    /// against the current account list; falls back to most-recently-added
    /// (`accounts.first`, since the @Query sorts by addedAt desc) when
    /// there's no stored selection or it points at a removed account.
    ///
    /// Accounts flagged `needsReauth` are skipped in both paths — an
    /// expired session can't drive AppShell (every Helix call would
    /// fail). They stay in the switcher with a re-authorize affordance;
    /// when NO healthy account remains this returns nil and SignInView
    /// renders (with the session-expired banner).
    private var activeAccount: Account? {
        if !activeAccountUserId.isEmpty,
           let match = accounts.first(where: { $0.userId == activeAccountUserId }),
           !match.needsReauth {
            return match
        }
        return accounts.first(where: { !$0.needsReauth })
    }

    public var body: some View {
        // Nuke's shared image pipeline is configured once in `chattrApp.init`,
        // before any view materializes — not here. Keeping one-time setup out
        // of `body` avoids re-running it on every re-evaluation.
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
        .environment(\.blockStore, blockStore)
        .environment(\.followsStore, followsStore)
        .environment(\.channelSessionRegistry, channelSessionRegistry)
        .environment(\.chatImagePrefetcher, chatImagePrefetcher)
        .environment(\.chatAppearance, chatAppearance)
        .onChange(of: activeAccount?.userId) { _, newId in
            // Keep AccountStore's in-memory activeUserId in sync with the
            // rendered account — covers the cold-start case where the
            // @AppStorage value was restored from UserDefaults but
            // setActive hasn't been called yet this launch.
            if let newId {
                accountStore.setActive(userId: newId)
            }
        }
        // Keep the registry's ring capacity in step with the Chat History
        // setting — at launch and whenever the user changes it. Applies to
        // sessions constructed AFTER the change (newly opened tabs);
        // existing sessions keep their capacity.
        .task(id: chatHistoryLines) {
            channelSessionRegistry.chatHistoryLimit = ChatAppearance.chatHistoryLines()
        }
        // Bound the per-channel emote cache: delete files not refreshed in 7
        // days. Runs once at launch (not keyed to account). The 24h TTL governs
        // freshness; this governs lifetime. OS purge of Caches/ is a backstop.
        .task {
            await JSONDiskCache(subdirectory: CacheSubdirectory.emoteChannels)
                .sweep(maxAge: 7 * 24 * 60 * 60)
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
        // Create the active account's BlockStore (loads its persisted cache in
        // init) and seed it from Twitch's authoritative block list. `.task(id:)`
        // re-fires on account swap, replacing the store for the new account.
        .task(id: activeAccount?.userId) {
            guard let active = activeAccount else {
                blockStore = nil
                return
            }
            let store = BlockStore(accountUserId: active.userId, accountStore: accountStore)
            blockStore = store
            await store.load()
        }
    }
}
