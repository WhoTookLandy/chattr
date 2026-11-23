import SwiftUI
import SwiftData
import Accounts
import Channels
import ChatModel
import Core
import os
#if canImport(UIKit)
import UIKit
#endif

private let logger = AppLogger.make("Features.AppShell")

/// Top-level shell for a signed-in user. Four tabs:
///
///   - **Home**: Live / Following / Chats as top tabs (`HomeScreen`);
///     opening a chat pushes the full-screen `ChatPagerScreen`. The app's
///     landing surface — answers "who's live?" on open.
///   - **Activity**: @-mentions and keyword hits across open chats
///     (`ActivityScreen`, fed by `TabSessionCoordinator`'s mention watcher).
///   - **You**: profile / appearance / storage — the old Profile sheet's
///     content as a persistent destination.
///   - **Search**: open any channel by name (`role: .search` gives it the
///     system's trailing-edge treatment; the field morphs from the tab).
///
/// Sheets remain only for genuinely transient tasks (the open-tabs
/// switcher); primary destinations are tabs.
///
/// AppShell owns:
///   - `navigation`: an `@Observable` holding `selectedTab` (which top-level
///     tab is visible) and `chatTabs` (the open-channel tab state). The
///     open-channel / resume-chat / go-home intents are methods on it, so the
///     three "switch to the Chats tab" call sites share one definition.
///     Injected by identity, which keeps `\.openChannel` a stable environment
///     value (see `OpenChannelAction`). `chatTabs` is also injected via
///     `\.chatTabs` and surfaced in the chat header's switcher.
///
/// It also injects the `\.openChannel` action (open a channel as a new chat
/// tab — used by Home, Following, and Search row taps) and, as it appears,
/// starts its `TabSessionCoordinator` (which wires `ChatTabsModel`'s
/// `onOpen`/`onClose`/`onDiscard` to the session registry's acquire/release
/// refcounting), installs the account-scoped `TabPersistence`, and hydrates
/// persisted tabs on cold start. On disappear (account switch / sign-out) it
/// tears the tab model down, releasing every session it acquired, then stops
/// the coordinator, which releases anything else the registry still holds
/// for the account.
public struct AppShell: View {
    private let account: Account
    private let accountStore: AccountStore
    /// Twitch client id, threaded down to ProfileScreen → the account
    /// switcher so "Add Account" can run the OAuth flow.
    private let clientId: String

    /// The app's top-level destinations.
    enum AppTab: Hashable {
        case home, chats, activity, search
    }

    @State private var navigation = AppNavigation()

    /// Same keys `ChatsScreen` restores from: if a chat was open when the
    /// scene was last torn down, launch on the Chats tab so it can resume.
    @SceneStorage("chattr.chat.activeTabId") private var persistedActiveTabId: String?
    @AppStorage("chattr.resumeLastChatOnLaunch") private var resumeLastChatOnLaunch = true
    @State private var didPickLaunchTab = false

    #if os(iOS)
    /// The single stream player: chat headers drive it; when its chat is
    /// left it keeps playing in `MiniPlayerOverlay`.
    @State private var playback = PlaybackCenter()

    /// A chat is on screen (Chats tab with the pager pushed) — the stream
    /// shows in its header there, so no mini player.
    private var chatOnScreen: Bool {
        navigation.selectedTab == .chats
            && navigation.chatTabs.isPresented
            && !navigation.chatTabs.tabs.isEmpty
    }

    private func wirePictureInPicture() {
        // PiP's "return to app" → back into that stream's chat.
        // Weak: the center owns the controller that stores these closures.
        playback.controller.onRestoreFromPictureInPicture = { [weak playback, weak navigation] in
            if let channel = playback?.channel {
                navigation?.openChannel(channel)
            }
        }
        // PiP closed with its × while no chat shows the stream: stop it
        // rather than leaving a paused mini player behind.
        playback.controller.onPictureInPictureClosed = { [weak playback, weak navigation] in
            guard let playback, let navigation else { return }
            let chatShowingIt = navigation.selectedTab == .chats && navigation.chatTabs.isPresented
            if !chatShowingIt { playback.stop() }
        }
    }
    #endif

    /// Ties this shell's chat tabs to the session registry: acquire /
    /// release per tab, the mention watchers, and the account-wide release
    /// when the shell goes away. Started and stopped below.
    @State private var tabSessions = TabSessionCoordinator()

    /// The link being handled (see `pendingIntent`), so a shell that goes
    /// away mid-lookup can call it off.
    @State private var intentTask: Task<Void, Never>?

    /// A link's destination, handed down by `RootView` and taken (and
    /// cleared) here.
    @Binding private var pendingIntent: NavigationIntent?

    @Environment(\.channelSessionRegistry) private var channelSessionRegistry

    /// The app's `ModelContext` (injected by `.modelContainer(...)` at
    /// chattrApp). We don't use the context itself — we use its `container`
    /// to construct a `TabPersistence` for the chat-tabs model. SwiftUI
    /// gives us this for free because RootView already applied the
    /// `.modelContainer(modelContainer)` modifier.
    @Environment(\.modelContext) private var modelContext

    public init(account: Account, accountStore: AccountStore, clientId: String) {
        self.init(account: account, accountStore: accountStore, clientId: clientId, pendingIntent: .constant(nil))
    }

    init(
        account: Account,
        accountStore: AccountStore,
        clientId: String,
        pendingIntent: Binding<NavigationIntent?>
    ) {
        self.account = account
        self.accountStore = accountStore
        self.clientId = clientId
        self._pendingIntent = pendingIntent
    }

    public var body: some View {
        @Bindable var navigation = navigation
        TabView(selection: $navigation.selectedTab) {
            // Icon-only tabs: the custom-`label` initializer renders just the
            // SF Symbol (no caption), with `.accessibilityLabel` preserving the
            // VoiceOver name the visible title used to carry. The `.search` tab
            // keeps its role-driven treatment below.
            // Home: Live / Following (swipeable top tabs), with You behind
            // the avatar in its corner. Chats is its own tab — it's the
            // heart of the app, one tap from anywhere.
            Tab(value: AppTab.home) {
                HomeScreen(
                    account: account,
                    accountStore: accountStore,
                    clientId: clientId,
                    section: $navigation.homeSection,
                    path: $navigation.homePath,
                    isTabSelected: navigation.selectedTab == .home,
                    isTabBarHidden: $navigation.isHomeTabBarHidden
                )
            } label: {
                Image(systemName: "house")
            }
            .accessibilityLabel("Home")
            // Chats and Activity take `navigation` / the store by reference and
            // no closures: this body re-runs whenever a badge below changes,
            // and a closure argument (never equal to the last one) would
            // re-run the tab's root with it.
            Tab(value: AppTab.chats) {
                ChatsScreen(account: account, accountStore: accountStore, navigation: navigation)
            } label: {
                Image(systemName: "bubble.left.and.bubble.right")
            }
            // Open chats with an unseen @-mention. 0 hides the badge.
            .badge(navigation.chatTabs.mentionedTabIds.count)
            .accessibilityLabel("Chats")
            Tab(value: AppTab.activity) {
                ActivityScreen(store: navigation.activity)
            } label: {
                Image(systemName: "bell")
            }
            // Mentions + keyword hits since Activity was last viewed.
            // 0 hides the badge.
            .badge(navigation.activity.unreadCount)
            .accessibilityLabel("Activity")
            // `role: .search` separates the tab on the trailing edge and
            // morphs it into the search field on activation (iOS 26). Custom
            // icon-only label so it matches the other tabs (no caption).
            Tab(value: AppTab.search, role: .search) {
                AddChannelView(
                    account: account,
                    accountStore: accountStore,
                    showsCancelButton: false
                )
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .accessibilityLabel("Search")
        }
        .environment(\.chatTabs, navigation.chatTabs)
        .onAppear {
            #if os(iOS)
            wirePictureInPicture()
            #endif
            guard !didPickLaunchTab else { return }
            didPickLaunchTab = true
            if resumeLastChatOnLaunch, persistedActiveTabId != nil {
                navigation.selectedTab = .chats
            }
        }
        // Injected by identity: `OpenChannelAction` stores the stable
        // `navigation` reference (not a per-body closure), so this env value
        // compares equal across body passes and doesn't churn its readers.
        .environment(\.openChannel, OpenChannelAction(navigation))
        #if os(iOS)
        .environment(\.playback, playback)
        // Stream keeps playing after leaving its chat: a floating player
        // over every tab. Tap → back to that chat; × or fling down → stop.
        // Every read behind "is the mini player showing" lives in
        // `MiniPlayerHost`'s own body, so a chat push / pop, a tab switch or
        // play / pause invalidates only the overlay — not this shell, whose
        // body rebuilds the TabView and every tab root.
        .overlay { MiniPlayerHost(navigation: navigation, playback: playback) }
        // Sign-out / account switch: nothing keeps playing for the old account.
        .onDisappear { playback.stop() }
        // Settings → Video & Device → Keep Screen Awake: while a chat is on
        // screen, or a stream is actually showing video (not paused, not the
        // audio-only pill).
        // Evaluated in the modifier's own body, so these reads don't make the
        // shell itself observe playback / navigation state.
        .keepsScreenAwake(while: { chatOnScreen || playback.holdsScreenAwake })
        // Settings → Video & Device → When a Chat Opens, applied just before the
        // pager presents so the header mounts in the chosen state.
        .onAppear {
            if PlaybackPreferences.videoOnOpen == .autoplayOnWiFi
                || PlaybackPreferences.homePreview == .wiFiOnly {
                NetworkReachability.warmUp()
            }
            let chatTabs = navigation.chatTabs
            chatTabs.onWillPresent = { [weak playback, weak chatTabs] tab, intent in
                ChatOpenVideoPolicy.apply(opening: tab, intent: intent, chatTabs: chatTabs, playback: playback)
            }
        }
        #endif
        // Links (`RootView`'s `onOpenURL`). `initial` covers one that arrived
        // before this shell mounted. Handled on a task, so the wiring
        // `.onAppear` below has run by the time a channel opens.
        .onChange(of: pendingIntent, initial: true) { _, intent in
            guard let intent else { return }
            pendingIntent = nil
            intentTask?.cancel()
            // Read here, not in the task: the account row can be deleted
            // before the task runs.
            let accountUserId = account.userId
            intentTask = Task {
                await navigation.handle(intent) { login in
                    let channel = try await ChannelLoginResolver.resolve(
                        login: login, accountUserId: accountUserId, accountStore: accountStore
                    )
                    // The lookup is a network round trip. If this shell went
                    // away meanwhile (account switch, sign-out), opening the
                    // channel would acquire a session nothing releases.
                    try Task.checkCancellation()
                    return channel
                }
            }
        }
        // Single appearance step that does, in this exact order:
        //
        //   0. Point `DraftStorage` at this account's drafts.
        //   1. Start the `TabSessionCoordinator`, which wires `onOpen` /
        //      `onClose` / `onDiscard` on the ChatTabsModel — these bridge
        //      to the registry's `acquire` / `release` so refcounts track
        //      tab lifetime.
        //   2. Install the `TabPersistence` handle so future mutations
        //      write through to SwiftData.
        //   3. Hydrate any persisted tabs from disk — fires the freshly-
        //      wired `onOpen` for each so the registry acquires their
        //      sessions and EventSub subscriptions resume.
        //
        // Why `.onAppear` and not `.task`: all of it is synchronous, and
        // `.onAppear` finishes before the first frame. From a `.task` the
        // tabs landed a turn later, so a cold launch into a resumed chat
        // first drew the Chats tab's empty state. One closure (rather than
        // wiring in one modifier and hydrating in another) keeps the order
        // above explicit.
        .onAppear {
            // The open-channel tab state lives on `navigation`; bind it once
            // so the wiring below reads the same way it did when ChatTabsModel
            // was a direct `@State`.
            let chatTabs = navigation.chatTabs

            // 0. Scope compose drafts to this account. Before hydration, so
            //    every ChatScreen the restored tabs mount reads this
            //    account's drafts (first run after upgrade also adopts the
            //    pre-scoping drafts — see `DraftStorage.activate`).
            DraftStorage.activate(accountUserId: account.userId)

            // 1. Wire callbacks. The coordinator takes stable Strings
            //    (`userId`, `login`), never the `Account` — see its
            //    Sendable note.
            tabSessions.start(
                accountUserId: account.userId,
                accountLogin: account.login,
                registry: channelSessionRegistry,
                navigation: navigation
            )

            // 2. Install persistence (uses the container injected by
            //    chattrApp's `.modelContainer(...)`). Construct lazily
            //    here so AppShell doesn't have to take the container as
            //    an init parameter — `@Environment(\.modelContext)` is
            //    the canonical SwiftUI accessor.
            //    Scoped to this account: it only reads and writes this
            //    account's rows, so each account keeps its own strip.
            let persistence = TabPersistence(
                modelContainer: modelContext.container,
                accountUserId: account.userId
            )
            chatTabs.persistence = persistence

            // 3. Hydrate. This fires `onOpen` for each restored tab, a few
            //    at a time, starting with the chat about to be resumed —
            //    which acquires sessions in the registry. The
            //    actual EventSub subscriptions happen asynchronously
            //    inside each acquire — the UI shows the restored tab
            //    pills immediately, and messages start flowing in the
            //    chat panel as soon as each subscription confirms.
            let resumedTabId = resumeLastChatOnLaunch
                ? persistedActiveTabId.flatMap(UUID.init(uuidString:))
                : nil
            chatTabs.hydrateFromPersistence(openingFirst: resumedTabId)
            logger.info("AppShell wired tab callbacks + persistence; hydration kicked off")
        }
        // Teardown: release every session this account's tabs acquired.
        // RootView's `.id(userId)` replaces this AppShell on account switch
        // (and removes it on sign-out), which fires `onDisappear` on the old
        // instance — its `navigation.chatTabs` is still the old account's
        // model here. Without this, nothing balanced the `onOpen` acquires
        // and every switch leaked the previous account's chat sessions and
        // EventSub subscriptions. `tearDown()` releases each acquired tab
        // exactly once, discards opens that hadn't started, and doesn't touch
        // the account's saved tabs; it is reversible (if this same AppShell
        // re-appeared, the `.onAppear` above would re-wire and re-hydrate).
        //
        // Then the coordinator sweeps up whatever the tabs didn't own, once
        // the last tab release has finished (see `TabSessionCoordinator.stop`).
        //
        // Deliberately doesn't read `account` here: on account removal the
        // SwiftData `@Model` may already be deleted when this fires, and
        // touching a deleted model's properties traps. The coordinator
        // took `userId` as a String back when it was started.
        .onDisappear {
            logger.notice("AppShell disappearing; tearing down chat tabs")
            intentTask?.cancel()
            let releases = navigation.chatTabs.tearDown()
            tabSessions.stop(after: releases)
        }
    }
}
