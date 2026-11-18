import SwiftUI
import SwiftData
import Accounts
import Channels
import TwitchKit
import Core

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
    // observes the keys via KVO, so AppearanceSettingsScreen's writes
    // re-render all of them live.
    @AppStorage(ChatAppearance.textSizePointsKey) private var chatTextSizePoints: Double = ChatAppearance.defaultTextSizePoints
    @AppStorage(ChatAppearance.showTimestampsKey) private var chatShowTimestamps: Bool = false
    @AppStorage(ChatAppearance.showBadgesKey) private var chatShowBadges: Bool = true
    @AppStorage(ChatAppearance.animatedEmotesKey) private var chatAnimatedEmotes: Bool = true
    @AppStorage(ChatAppearance.edgeToEdgeKey) private var chatEdgeToEdge: Bool = false
    @AppStorage(ChatAppearance.loginNameDisplayKey) private var chatLoginNameDisplay: ChatAppearance.LoginNameDisplay = .displayFirst
    @AppStorage(ChatAppearance.compactBotsKey) private var chatCompactBots: Bool = false
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
            loginNameDisplay: chatLoginNameDisplay,
            compactBots: chatCompactBots
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
    /// One store per account: an account switch gets a fresh one (see
    /// `FollowsStoreScope`).
    @State private var followsScope = FollowsStoreScope()

    private var followsStore: FollowsStore {
        followsScope.store(forAccountUserId: activeAccount?.userId)
    }

    /// Live/offline status for open chat channels (followed or not) — drives
    /// the chat stream header, live dots and last-live captions.
    @State private var channelStatus = ChannelStatusStore()

    /// Launch-time chat image prefetcher. Warms Nuke's memory + disk
    /// caches with Twitch global emotes + global badges (memory),
    /// AND the user's subscribed-channel emote set (disk). Per-channel
    /// badges are prefetched separately by `ChatScreen` on channel
    /// entry, also via this prefetcher (so they share Nuke pipeline
    /// concurrency limits).
    @State private var chatImagePrefetcher = ChatImagePrefetcher()

    /// Where a `chattr://open/...` link wants to go, until the signed-in
    /// shell takes it (see `AppShell`'s `pendingIntent`).
    @State private var pendingNavigationIntent: NavigationIntent?

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
        // Touching the lazy static runs it once per process, not on every
        // RootView re-init from the parent's body.
        _ = Self.legacyTextSizeMigration
    }

    /// Lazily-initialized (`static let` ⇒ exactly once, thread-safe) so the
    /// UserDefaults migration doesn't re-run on every RootView recompute.
    private static let legacyTextSizeMigration: Void = ChatAppearance.migrateLegacyTextSizeIfNeeded()

    /// Observed to refresh the live follow list when the app returns to the
    /// foreground (see the `.onChange(of: scenePhase)` below).
    @Environment(\.scenePhase) private var scenePhase

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
                AppShell(
                    account: active,
                    accountStore: accountStore,
                    clientId: clientId,
                    pendingIntent: $pendingNavigationIntent
                )
                    // `.id(userId)` forces a fresh AppShell when the active
                    // account changes (switch / add / remove). A new account
                    // means new chat sessions, a new follow list, new
                    // emote+badge prefetch — a clean slate is correct, and
                    // far simpler than threading account-change invalidation
                    // through every child store.
                    //
                    // The outgoing account's chat sessions are released by
                    // the OLD AppShell's `onDisappear` (→ `ChatTabsModel
                    // .tearDown()`), which this identity change triggers.
                    // Hooked there rather than in an `onChange` here because
                    // only AppShell holds that account's tab model.
                    .id(active.userId)
            } else {
                SignInView(accountStore: accountStore, clientId: clientId)
            }
        }
        .environment(\.globalCatalog, globalCatalog)
        .environment(\.blockStore, blockStore)
        .environment(\.followsStore, followsStore)
        .environment(\.channelStatus, channelStatus)
        .environment(\.channelSessionRegistry, channelSessionRegistry)
        .environment(\.chatImagePrefetcher, chatImagePrefetcher)
        .environment(\.chatAppearance, chatAppearance)
        // `chattr://open/...` links. The scheme is shared with the browser
        // sign-in callback (`chattr://oauth-complete?...`), which is not a
        // navigation link: `NavigationIntent` yields nil for it and for
        // anything else it doesn't know. Signed out there is nowhere to
        // navigate, so the link is dropped rather than kept for later.
        .onOpenURL { url in
            guard activeAccount != nil, let intent = NavigationIntent(url: url) else { return }
            pendingNavigationIntent = intent
        }
        .onChange(of: activeAccount?.userId) { _, newId in
            // A link is for the account that was showing when it arrived.
            pendingNavigationIntent = nil
            // Boundary log for the rendered account. The @AppStorage
            // selection is the single source of truth; AccountStore keeps
            // no in-memory active slot.
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
            // One refresh ahead of the launch fan-out (single-flight, shared
            // by the tasks below) instead of a 401 per request once the
            // access token has expired.
            await accountStore.refreshTokensIfExpiringSoon(for: active)
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
        //
        // Deferred a few seconds: it's pure cache warming (every page of
        // the endpoint, then hundreds of image downloads), and Nuke's
        // `.veryLow` priority only orders QUEUED requests — downloads already
        // running kept their bandwidth while the restored chat's emotes,
        // badges and history were loading.
        .task(id: activeAccount?.userId) {
            guard activeAccount != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let active = activeAccount else { return }
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
            // Resolved before suspending: `followsStore` is the store of
            // whichever account is current when it is read, and after an
            // account switch that is no longer this task's account.
            let store = followsStore
            await accountStore.refreshTokensIfExpiringSoon(for: active)
            // The refresh is a network round trip. An account switch during
            // it cancels this task, and `refreshLive` (unlike
            // `loadAllIfNeeded`) would switch the store back to `active`.
            guard !Task.isCancelled else { return }
            await store.refreshLive(account: active, accountStore: accountStore)
        }
        .task(id: activeAccount?.userId) {
            guard let active = activeAccount else { return }
            let store = followsStore
            await accountStore.refreshTokensIfExpiringSoon(for: active)
            await store.loadAllIfNeeded(account: active, accountStore: accountStore)
        }
        // Foregrounding: live status goes stale while backgrounded. Non-forced
        // — FollowsStore's staleness throttle skips it after a quick
        // background/foreground hop, and coalesces it with any in-flight
        // refresh (e.g. the launch-time `.task` above).
        //
        // Leaving the foreground (inactive on the way to background, or
        // background directly): write any debounced compose draft now — the
        // app may be suspended or killed before the ~400ms timer fires, and
        // the compose bar isn't torn down (so its own flush doesn't run).
        //
        // Sessions pause background network work (live-event Helix checks)
        // on `.background` and catch up once on `.active`. `.inactive` (app
        // switcher, Control Center) changes neither.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: channelSessionRegistry.setAppInForeground(true)
            case .background: channelSessionRegistry.setAppInForeground(false)
            default: break
            }
            guard phase == .active else {
                DraftStorage.flushPendingSaves()
                return
            }
            guard let active = activeAccount else { return }
            let activeUserId = active.userId
            Task {
                await accountStore.refreshTokensIfExpiringSoon(for: active)
                // Same hazard as the launch task above, without a task to
                // cancel: don't hand the store an account that was switched
                // away from during the refresh.
                guard activeAccount?.userId == activeUserId else { return }
                await followsStore.refreshLive(account: active, accountStore: accountStore)
            }
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
            await accountStore.refreshTokensIfExpiringSoon(for: active)
            await store.load()
        }
    }
}
