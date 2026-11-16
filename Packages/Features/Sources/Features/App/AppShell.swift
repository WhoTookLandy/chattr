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
/// tab — used by Home, Following, and Search row taps) and, in a single
/// appearance `.task`, wires `ChatTabsModel`'s `onOpen`/`onClose` to the
/// session registry's acquire/release refcounting, installs the
/// account-scoped `TabPersistence`, and hydrates persisted tabs on cold
/// start. On disappear (account switch / sign-out) it tears the tab model
/// down, releasing every session it acquired.
public struct AppShell: View {
    private let account: Account
    private let accountStore: AccountStore
    /// Twitch client id, threaded down to ProfileScreen → the account
    /// switcher so "Add Account" can run the OAuth flow.
    private let clientId: String

    /// The app's top-level destinations.
    enum AppTab: Hashable {
        case home, activity, you, search
    }

    @State private var navigation = AppNavigation()

    /// Subscription tokens for the per-tab mention watchers installed in
    /// `onOpen`, keyed by tab id, one entry per channel in the tab. Held in
    /// a reference type (not view `@State` value) so the long-stored
    /// `onOpen`/`onClose` closures can mutate it.
    @State private var mentionWatchTokens = MentionWatchTokens()

    #if canImport(UIKit)
    /// The account avatar rendered for the You tab (see `ProfileTabIcon`).
    @State private var profileIcon: UIImage?
    #endif

    /// The You tab's icon: the avatar once loaded, else the symbol.
    private var profileTabImage: Image {
        #if canImport(UIKit)
        if let profileIcon { return Image(uiImage: profileIcon) }
        #endif
        return ProfileTabIcon.fallback
    }

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
            // Home carries Live / Following / Chats as top tabs (see
            // `HomeScreen`), leaving this bar for app-wide destinations.
            Tab(value: AppTab.home) {
                HomeScreen(
                    account: account,
                    accountStore: accountStore,
                    section: $navigation.homeSection
                )
            } label: {
                Image(systemName: "house")
            }
            .accessibilityLabel("Home")
            Tab(value: AppTab.activity) {
                ActivityScreen(
                    store: navigation.activity,
                    onOpen: { channel in navigation.openChannel(channel) }
                )
            } label: {
                Image(systemName: "bell")
            }
            // Mentions + keyword hits since Activity was last viewed.
            // 0 hides the badge.
            .badge(navigation.activity.unreadCount)
            .accessibilityLabel("Activity")
            Tab(value: AppTab.you) {
                NavigationStack {
                    ProfileScreen(account: account, accountStore: accountStore, clientId: clientId)
                }
            } label: {
                profileTabImage
            }
            .accessibilityLabel("You")
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
        // Injected by identity: `OpenChannelAction` stores the stable
        // `navigation` reference (not a per-body closure), so this env value
        // compares equal across body passes and doesn't churn its readers.
        .environment(\.openChannel, OpenChannelAction(navigation))
        #if canImport(UIKit)
        .task(id: account.profileImageURL) {
            profileIcon = await ProfileTabIcon.load(urlString: account.profileImageURL)
        }
        #endif
        // Single appearance task that does, in this exact order:
        //
        //   0. Point `DraftStorage` at this account's drafts.
        //   1. Wire `onOpen` / `onClose` on the ChatTabsModel — these
        //      bridge to the registry's `acquire` / `release` so refcounts
        //      track tab lifetime.
        //   2. Install the `TabPersistence` handle so future mutations
        //      write through to SwiftData.
        //   3. Hydrate any persisted tabs from disk — fires the freshly-
        //      wired `onOpen` for each so the registry acquires their
        //      sessions and EventSub subscriptions resume.
        //
        // Why one `.task` instead of one `.onAppear` + one `.task`:
        // ordering. `.onAppear` runs synchronously and `.task` runs
        // asynchronously, so on paper the callbacks would be set before
        // hydration begins anyway — but combining them into one explicit
        // sequence makes the dependency obvious to the next reader and
        // immune to SwiftUI scheduling subtleties.
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
        // ## Sendable note
        //
        // Both closures capture only `Sendable` values: `account` is a
        // SwiftData @Model (non-Sendable), so we pass it directly to
        // `registry.acquire` only after the closure has hopped onto
        // `@MainActor` — Account is touched on main, never crossed a
        // boundary. `onClose` captures `accountUserId` alone (String) for
        // the same reason but at the value-type level.
        .task {
            // The open-channel tab state lives on `navigation`; bind it once
            // so the wiring below reads the same way it did when ChatTabsModel
            // was a direct `@State`.
            let chatTabs = navigation.chatTabs

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
            let activity = navigation.activity
            chatTabs.onOpen = {
                [weak channelSessionRegistry, weak chatTabs, weak activity, mentionWatchTokens,
                 accountUserId = account.userId,
                 accountLogin = account.login] tab in
                guard let registry = channelSessionRegistry else { return }
                for channel in tab.channels {
                    do {
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
                            [weak chatTabs, weak activity, tabId = tab.id, channel, keywordMatcher] batch in
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
                                await activity?.record(hits)
                            }
                        })
                        mentionWatchTokens.byTab[tab.id, default: []]
                            .append((channelId: channel.channelId, token: token))
                    } catch is CancellationError {
                        // Expected if a release races acquire (rapid
                        // open-then-close). Swallow silently.
                    } catch {
                        // Construction failure here is rare — usually
                        // CancellationError above. Log and continue;
                        // the user's next interaction with the tab
                        // will re-trigger the acquire path.
                        logger.error("acquire failed for \(channel.channelLoginName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
            chatTabs.onClose = {
                [weak channelSessionRegistry, mentionWatchTokens,
                 accountUserId = account.userId,
                 accountLogin = account.login] tab in
                guard let registry = channelSessionRegistry else { return }
                // Unsubscribe the mention watchers BEFORE releasing: the
                // tab's own refcount keeps the session alive here, so
                // `registry.session` resolves via its fast path (returns
                // the existing instance, constructs nothing).
                for entry in mentionWatchTokens.byTab[tab.id] ?? [] {
                    guard let channel = tab.channels.first(where: { $0.channelId == entry.channelId }),
                          let session = try? await registry.session(
                              accountUserId: accountUserId,
                              accountLogin: accountLogin,
                              channelId: entry.channelId,
                              channelLoginName: channel.channelLoginName
                          ) else { continue }
                    await session.unsubscribe(entry.token)
                }
                mentionWatchTokens.byTab[tab.id] = nil
                for channel in tab.channels {
                    await registry.release(accountUserId: accountUserId, channelId: channel.channelId)
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

            // 3. Hydrate. This fires `onOpen` for each restored tab in
            //    order, which acquires sessions in the registry. The
            //    actual EventSub subscriptions happen asynchronously
            //    inside each acquire — the UI shows the restored tab
            //    pills immediately, and messages start flowing in the
            //    chat panel as soon as each subscription confirms.
            chatTabs.hydrateFromPersistence()
            logger.info("AppShell wired tab callbacks + persistence; hydration kicked off")
        }
        // Teardown: release every session this account's tabs acquired.
        // RootView's `.id(userId)` replaces this AppShell on account switch
        // (and removes it on sign-out), which fires `onDisappear` on the old
        // instance — its `navigation.chatTabs` is still the old account's
        // model here. Without this, nothing balanced the `onOpen` acquires
        // and every switch leaked the previous account's chat sessions and
        // EventSub subscriptions. `tearDown()` releases each acquired tab
        // exactly once, skips opens that hadn't started, and doesn't touch
        // the account's saved tabs; it is reversible (if this same AppShell
        // re-appeared, the `.task` above would re-wire and re-hydrate).
        //
        // Deliberately doesn't read `account` here: on account removal the
        // SwiftData `@Model` may already be deleted when this fires, and
        // touching a deleted model's properties traps. The release closures
        // captured `userId` as a String back when they were wired.
        .onDisappear {
            logger.notice("AppShell disappearing; tearing down chat tabs")
            navigation.chatTabs.tearDown()
        }
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

    /// Which Home top tab is showing (Live / Following / Chats).
    var homeSection: HomeSection = .live

    /// Mentions + keyword hits across open chats (the Activity tab).
    let activity = ActivityStore()

    /// Open `channel` as a chat tab and land the user in its chat — Home →
    /// Chats with the chat pushed — "tap a channel anywhere → land in its
    /// chat," from any tab. (`open` makes the tab active, which pushes it.)
    func openChannel(_ channel: ChannelDescriptor) {
        chatTabs.open(channel: channel)
        homeSection = .chats
        selectedTab = .home
    }
}

/// Mutable box for mention-watcher subscription tokens. A `@MainActor`
/// class (not a `@State` value type) because the long-stored
/// `onOpen`/`onClose` closures on `ChatTabsModel` need to mutate it
/// outside the view-update cycle.
@MainActor
private final class MentionWatchTokens {
    /// One entry per channel per open tab: which subscription to remove
    /// from which session when the tab closes.
    var byTab: [UUID: [(channelId: String, token: UUID)]] = [:]
}

