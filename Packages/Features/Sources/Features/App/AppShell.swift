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
///     (`ActivityScreen`, fed by the mention watcher wired below).
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
/// wires `ChatTabsModel`'s `onOpen`/`onClose`/`onDiscard` to the
/// session registry's acquire/release refcounting, installs the
/// account-scoped `TabPersistence`, and hydrates persisted tabs on cold
/// start. On disappear (account switch / sign-out) it tears the tab model
/// down, releasing every session it acquired, then anything else the
/// registry still holds for the account.
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

    /// Subscription tokens for the per-tab mention watchers installed in
    /// `onOpen`, keyed by tab id, one entry per channel in the tab. Held in
    /// a reference type (not view `@State` value) so the long-stored
    /// `onOpen`/`onClose` closures can mutate it.
    @State private var mentionWatchTokens = MentionWatchTokens()

    @Environment(\.channelSessionRegistry) private var channelSessionRegistry

    /// The app's `ModelContext` (injected by `.modelContainer(...)` at
    /// chattrApp). We don't use the context itself — we use its `container`
    /// to construct a `TabPersistence` for the chat-tabs model. SwiftUI
    /// gives us this for free because RootView already applied the
    /// `.modelContainer(modelContainer)` modifier.
    @Environment(\.modelContext) private var modelContext

    public init(account: Account, accountStore: AccountStore, clientId: String) {
        self.account = account
        self.accountStore = accountStore
        self.clientId = clientId
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
                    section: $navigation.homeSection
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
            if PlaybackPreferences.videoOnOpen == .autoplayOnWiFi {
                NetworkReachability.warmUp()
            }
            let chatTabs = navigation.chatTabs
            chatTabs.onWillPresent = { [weak playback, weak chatTabs] tab, intent in
                ChatOpenVideoPolicy.apply(opening: tab, intent: intent, chatTabs: chatTabs, playback: playback)
            }
        }
        #endif
        // Single appearance step that does, in this exact order:
        //
        //   0. Point `DraftStorage` at this account's drafts.
        //   1. Wire `onOpen` / `onClose` / `onDiscard` on the ChatTabsModel
        //      — these bridge to the registry's `acquire` / `release` so
        //      refcounts track tab lifetime.
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
        //
        // ## What `onOpen` does
        //
        //   A tab just appeared (user opened a channel OR cold-start
        //   hydration restored a persisted tab). Bumps the refcount for
        //   each of its channels and triggers session construction so
        //   EventSub subscriptions start flowing immediately.
        //
        // ## What `onClose` does
        //
        //   A tab just disappeared (user tapped the X). Drops the
        //   refcount for each of its channels. The session keeps running
        //   while other tabs still hold a reference; when the count hits
        //   0 the session is stopped and the EventSub subscription is
        //   released.
        //
        // ## What `onDiscard` does
        //
        //   A tab disappeared before its `onOpen` ran, so it holds no
        //   refcount — but its mounted ChatScreen may already have built
        //   the session through `registry.session(...)`. Tears that
        //   session down unless another tab holds it.
        //
        // ## Sendable note
        //
        // The closures capture only `Sendable` values: `account` is a
        // SwiftData @Model (non-Sendable), so they take `userId` / `login`
        // as Strings instead.
        .onAppear {
            // The open-channel tab state lives on `navigation`; bind it once
            // so the wiring below reads the same way it did when ChatTabsModel
            // was a direct `@State`.
            let chatTabs = navigation.chatTabs

            // This shell is now live for the account (see
            // `ShellSessionOwners`). Recorded as Strings for `onDisappear`,
            // which must not read `account`. A repeated `onAppear` re-wires,
            // so its earlier token no longer stands for a live shell.
            let sessionOwner = UUID()
            if let previous = mentionWatchTokens.sessionScope {
                ShellSessionOwners.live[previous.accountUserId]?.remove(previous.owner)
            }
            ShellSessionOwners.live[account.userId, default: []].insert(sessionOwner)
            mentionWatchTokens.sessionScope = (accountUserId: account.userId, owner: sessionOwner)

            // 0. Scope compose drafts to this account. Before hydration, so
            //    every ChatScreen the restored tabs mount reads this
            //    account's drafts (first run after upgrade also adopts the
            //    pre-scoping drafts — see `DraftStorage.activate`).
            DraftStorage.activate(accountUserId: account.userId)

            // 1. Wire callbacks.
            //
            // Capture stable Strings (`userId`, `login`) rather than the
            // non-Sendable SwiftData `@Model` Account. The closure is
            // stored on `ChatTabsModel.onOpen` for the session lifetime
            // — capturing Account directly would retain it indefinitely
            // (no `weak` possible on `@Model`) and create undefined
            // behavior if multi-account/sign-out ever invalidates the
            // SwiftData context. Matches the existing `onClose` shape.
            // `chatTabs` MUST be weak here: this closure is stored on
            // `chatTabs.onOpen` itself, so a strong capture is a self-retain
            // cycle — the old ChatTabsModel (plus its tabs, TabPersistence,
            // and MentionWatchTokens) would leak on every account switch,
            // since RootView's `.id(userId)` rebuilds AppShell each time.
            chatTabs.onOpen = {
                [weak channelSessionRegistry, weak chatTabs, weak navigation = self.navigation, mentionWatchTokens,
                 accountUserId = account.userId,
                 accountLogin = account.login] tab in
                guard let registry = channelSessionRegistry else { return }
                var failed: [ChannelDescriptor] = []
                for channel in tab.channels {
                    do {
                        try await AppShell.acquireAndWatch(
                            channel, tabId: tab.id, registry: registry,
                            chatTabs: chatTabs, navigation: navigation, tokens: mentionWatchTokens,
                            accountUserId: accountUserId, accountLogin: accountLogin
                        )
                    } catch is CancellationError {
                        // Expected if a release races acquire (rapid
                        // open-then-close). Swallow silently.
                    } catch {
                        // The registry already rolled this acquire back, so
                        // the tab holds nothing for the channel. Retried
                        // below.
                        logger.error("acquire failed for \(channel.channelLoginName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        failed.append(channel)
                    }
                }
                guard !failed.isEmpty else { return }
                // Retry with backoff while the tab stays open — on a task of
                // its own, so a channel that can't start doesn't hold up the
                // restored tabs queued behind this one. `onClose` cancels
                // and awaits it before releasing, which keeps a late acquire
                // from landing after the tab's release.
                let unacquired = failed
                mentionWatchTokens.retries[tab.id] = Task {
                    [weak registry, weak chatTabs, weak navigation, mentionWatchTokens] in
                    var remaining = unacquired
                    for delay in AppShell.acquireRetryDelays {
                        do {
                            try await Task.sleep(for: delay)
                        } catch {
                            return
                        }
                        guard let registry,
                              chatTabs?.tabs.contains(where: { $0.id == tab.id }) == true
                        else { return }
                        var stillFailing: [ChannelDescriptor] = []
                        for channel in remaining {
                            do {
                                try await AppShell.acquireAndWatch(
                                    channel, tabId: tab.id, registry: registry,
                                    chatTabs: chatTabs, navigation: navigation, tokens: mentionWatchTokens,
                                    accountUserId: accountUserId, accountLogin: accountLogin
                                )
                            } catch is CancellationError {
                                // The key was released under us; nothing to hold.
                            } catch {
                                stillFailing.append(channel)
                            }
                        }
                        remaining = stillFailing
                        if remaining.isEmpty { return }
                    }
                    let unacquiredCount = remaining.count
                    logger.error("acquire still failing for \(unacquiredCount) channel(s) of a tab; giving up until it is reopened")
                }
            }
            chatTabs.onClose = {
                [weak channelSessionRegistry, mentionWatchTokens,
                 accountUserId = account.userId] tab in
                // Settle a pending acquire retry first: whatever it managed
                // to acquire is released below with the rest.
                if let retry = mentionWatchTokens.retries.removeValue(forKey: tab.id) {
                    retry.cancel()
                    await retry.value
                }
                guard let registry = channelSessionRegistry else { return }
                // Unsubscribe the mention watchers BEFORE releasing, while
                // the tab's own refcount still keeps the session alive.
                // `existingSession` never builds one: if the session is
                // already gone, so are its subscribers.
                for entry in mentionWatchTokens.byTab[tab.id] ?? [] {
                    guard let session = registry.existingSession(
                        accountUserId: accountUserId, channelId: entry.channelId
                    ) else { continue }
                    await session.unsubscribe(entry.token)
                }
                mentionWatchTokens.byTab[tab.id] = nil
                for channel in tab.channels {
                    await registry.release(accountUserId: accountUserId, channelId: channel.channelId)
                }
            }
            chatTabs.onDiscard = {
                [weak channelSessionRegistry, accountUserId = account.userId] tab in
                guard let registry = channelSessionRegistry else { return }
                for channel in tab.channels {
                    await registry.releaseUnowned(accountUserId: accountUserId, channelId: channel.channelId)
                }
            }

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
        // Then `releaseAll` sweeps up whatever the tabs didn't own (a session
        // a chat page built without its tab ever acquiring it). It runs
        // only after the last tab release, so it finds exactly what is left
        // over — not acquires those releases are still waiting on, nor one a
        // multi-channel open has yet to make.
        //
        // Deliberately doesn't read `account` here: on account removal the
        // SwiftData `@Model` may already be deleted when this fires, and
        // touching a deleted model's properties traps. The release closures
        // captured `userId` as a String back when they were wired.
        .onDisappear {
            logger.notice("AppShell disappearing; tearing down chat tabs")
            let releases = navigation.chatTabs.tearDown()
            guard let registry = channelSessionRegistry,
                  let scope = mentionWatchTokens.sessionScope else { return }
            Task {
                await releases?.value
                // Another shell is live for the account: it came back
                // (switched away and back, or this shell re-appeared) while
                // the releases ran, or a second window is showing it. The
                // sessions still in the registry are that shell's — its
                // tabs hold refcounts on them.
                guard ShellSessionOwners.retire(scope.owner, forAccountUserId: scope.accountUserId) else { return }
                await registry.releaseAll(forAccountUserId: scope.accountUserId)
            }
        }
    }

    /// Waits between retries of a tab's failed `acquire`.
    private static let acquireRetryDelays: [Duration] = [.seconds(2), .seconds(6), .seconds(15)]

    /// Acquires `channel`'s session for the tab (one refcount) and installs
    /// the tab's mention watcher on it. Throws what `registry.acquire`
    /// throws; the registry has rolled the refcount back by then.
    private static func acquireAndWatch(
        _ channel: ChannelDescriptor,
        tabId: UUID,
        registry: ChannelSessionRegistry,
        chatTabs: ChatTabsModel?,
        navigation: AppNavigation?,
        tokens: MentionWatchTokens,
        accountUserId: String,
        accountLogin: String
    ) async throws {
        let session = try await registry.acquire(
            accountUserId: accountUserId,
            accountLogin: accountLogin,
            channelId: channel.channelId,
            channelLoginName: channel.channelLoginName
        )
        // Mention watcher: session-level (not ChatTranscriptModel)
        // so @-mentions land the red dot even for tabs whose
        // page isn't mounted. The handler is deliberately
        // tiny — a substring check per message — and runs on
        // its own task per drained batch, so it never holds
        // up the session or the transcript.
        //
        // It also feeds the Activity inbox: @-mentions, plus
        // highlight-keyword hits (keywords read at tab open,
        // like the transcript's own highlighting).
        let keywordMatcher = HighlightMatcher(keywords: HighlightSettings.keywords())
        let token = await session.subscribe(onBatch: {
            [weak chatTabs, weak navigation, channel, keywordMatcher] batch in
            var mentioned = false
            var hits: [ActivityStore.Entry] = []
            for update in batch {
                guard case .message(let normalized) = update,
                      !normalized.line.isHistorical,
                      normalized.message.chatterUserId != accountUserId
                else { continue }
                let text = normalized.message.message.text
                let isMention = ChatTabsModel.containsMention(of: accountLogin, in: text)
                guard isMention || keywordMatcher.matches(normalized.line.runs) else { continue }
                mentioned = mentioned || isMention
                let line = normalized.line
                hits.append(ActivityStore.Entry(
                    id: line.id,
                    channel: channel,
                    authorDisplayName: line.authorDisplayName,
                    authorColor: line.authorColor,
                    text: text,
                    timestamp: line.timestamp,
                    reason: isMention ? .mention : .keyword
                ))
            }
            if mentioned {
                await chatTabs?.markMention(tabId: tabId)
            }
            if !hits.isEmpty {
                await navigation?.recordActivity(hits, fromTab: tabId)
            }
        })
        tokens.byTab[tabId, default: []]
            .append((channelId: channel.channelId, token: token))
    }
}

/// Which `AppShell`s are live for each account, by a token minted each time
/// a shell wires itself up. A shell that goes away sweeps the account's
/// leftover sessions only if no other shell is live for it once its tab
/// releases have finished. Switching away and straight back mounts a new
/// shell for the same account, and a second window (iPad) has a shell of its
/// own on the same registry: the sweep ignores refcounts, so it must not run
/// under either.
@MainActor
private enum ShellSessionOwners {
    static var live: [String: Set<UUID>] = [:]

    /// Takes `owner` out of the account's live shells. True only when it
    /// was still there and was the last one, which is when the caller may
    /// sweep.
    static func retire(_ owner: UUID, forAccountUserId accountUserId: String) -> Bool {
        guard live[accountUserId]?.remove(owner) != nil else { return false }
        guard live[accountUserId]?.isEmpty == true else { return false }
        live[accountUserId] = nil
        return true
    }
}

/// Top-level navigation state for a signed-in user: which tab is showing
/// (`selectedTab`) and the open-channel tab state (`chatTabs`). A reference
/// type so it can be injected into the environment by identity — that's what
/// keeps `\.openChannel` (which stores this model, see `OpenChannelAction`) a
/// stable environment value across `AppShell.body` re-evaluations.
///
/// The three "switch to the Chats tab" intents — opening a channel, resuming
/// a chat from Home, and the empty-state "go Home" — are methods here so the
/// `selectedTab` write lives in one place instead of being duplicated at each
/// call site.
@MainActor
@Observable
final class AppNavigation {
    /// Which top-level tab is visible.
    var selectedTab: AppShell.AppTab = .home

    /// Open-channel tab state (which channels are open, which is active).
    /// Owned here so navigation state has a single home; injected separately
    /// via `\.chatTabs` for the chat header's switcher.
    let chatTabs = ChatTabsModel()

    /// Which Home top tab is showing (Live / Following).
    var homeSection: HomeSection = .live

    /// Mentions + keyword hits across open chats (the Activity tab).
    let activity = ActivityStore()

    /// Open `channel` as a chat tab and land the user in its chat — the
    /// Chats tab with the chat pushed — "tap a channel anywhere → land in
    /// its chat," from any tab. (`open` presents the tab, which pushes it.)
    func openChannel(_ channel: ChannelDescriptor, intent: ChatOpenIntent = .implicit) {
        chatTabs.open(channel: channel, intent: intent)
        selectedTab = .chats
    }

    /// The Chats empty state's "See who's live": Home → Live.
    func showLive() {
        homeSection = .live
        selectedTab = .home
    }

    /// Whether `tabId`'s chat is what the user is looking at: the Chats tab
    /// with the pager pushed on that page, and the app in the foreground.
    func isShowingChat(tabId: UUID) -> Bool {
        guard selectedTab == .chats, chatTabs.isPresented, chatTabs.activeTabId == tabId else {
            return false
        }
        #if os(iOS)
        return UIApplication.shared.applicationState == .active
        #else
        return true
        #endif
    }

    /// Files a tab's mention / keyword hits in the Activity inbox. Hits from
    /// the chat on screen are filed as read — the user is looking at them,
    /// and counting them only bumped the badge (and re-ran the shell's
    /// `TabView`) for nothing.
    func recordActivity(_ hits: [ActivityStore.Entry], fromTab tabId: UUID) {
        activity.record(hits, asRead: isShowingChat(tabId: tabId))
    }
}

#if os(iOS)
/// The floating mini player over every tab. Its own view so the state it
/// depends on (selected tab, chat presented, playing, PiP) is observed here
/// rather than by `AppShell`.
private struct MiniPlayerHost: View {
    let navigation: AppNavigation
    let playback: PlaybackCenter

    @AppStorage(PlayerSettings.systemPictureInPictureKey) private var useSystemPictureInPicture = false

    /// A chat is on screen (Chats tab with the pager pushed) — the stream
    /// shows in its header there, so no mini player. Not while the system
    /// PiP window is showing the stream either — the mini player would just
    /// be a black "playing in picture in picture" tile.
    private var showsMiniPlayer: Bool {
        let chatOnScreen = navigation.selectedTab == .chats
            && navigation.chatTabs.isPresented
            && !navigation.chatTabs.tabs.isEmpty
        return playback.isPlaying && !chatOnScreen && !playback.controller.isPictureInPictureActive
    }

    var body: some View {
        ZStack {
            if showsMiniPlayer {
                MiniPlayerOverlay(center: playback) { channel in
                    navigation.openChannel(channel)
                }
            }
        }
        // Scoped to the overlay. On the TabView itself this animated the
        // WHOLE app tree in the transaction where `showsMiniPlayer` flips —
        // which is exactly the chat push / pop — so the navigation
        // transition, toolbar and tab-bar changes all picked up an extra
        // implicit animation.
        .animation(.snappy(duration: 0.3), value: showsMiniPlayer)
        .onChange(of: showsMiniPlayer) { _, shows in
            if shows { handOffToSystemPictureInPicture() }
        }
    }

    /// "Picture in Picture When Leaving Chat": once the mini player has
    /// taken the video, hand it to the system PiP window. PiP can only start
    /// from a player that's on screen, hence going via the mounted tile
    /// rather than straight from the chat header mid-pop. If PiP can't start
    /// (not ready yet, or the web player refuses), the mini player simply
    /// stays — nothing is lost. Audio-only keeps its pill.
    private func handOffToSystemPictureInPicture() {
        guard useSystemPictureInPicture,
              !playback.audioOnly || playback.controller.nativeFailed else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard showsMiniPlayer,
                  playback.controller.canPictureInPicture,
                  !playback.controller.isPictureInPictureActive else { return }
            playback.controller.togglePictureInPicture()
        }
    }
}
#endif

/// Mutable box for mention-watcher subscription tokens. A `@MainActor`
/// class (not a `@State` value type) because the long-stored
/// `onOpen`/`onClose` closures on `ChatTabsModel` need to mutate it
/// outside the view-update cycle.
@MainActor
private final class MentionWatchTokens {
    /// One entry per channel per open tab: which subscription to remove
    /// from which session when the tab closes.
    var byTab: [UUID: [(channelId: String, token: UUID)]] = [:]

    /// Background retries of a tab's failed acquires, by tab id. The tab's
    /// `onClose` cancels and awaits its entry before releasing.
    var retries: [UUID: Task<Void, Never>] = [:]

    /// The account this shell wired itself for and its `ShellSessionOwners`
    /// token, for the teardown in `onDisappear`.
    var sessionScope: (accountUserId: String, owner: UUID)?
}

