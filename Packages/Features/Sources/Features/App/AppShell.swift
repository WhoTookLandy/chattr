import SwiftUI
import SwiftData
import Accounts
import Channels
import Core
import os

private let logger = AppLogger.make("Features.AppShell")

/// Top-level shell for a signed-in user. Four tabs:
///
///   - **Home**: live follows + open-chat pills + the full follow list as
///     a push. The app's landing surface — answers "who's live?" on open.
///   - **Chats**: the paged chat surface (`ChatTabsScreen`), unchanged.
///   - **You**: profile / appearance / storage — the old Profile sheet's
///     content as a persistent destination.
///   - **Search**: open any channel by name (`role: .search` gives it the
///     system's trailing-edge treatment; the field morphs from the tab).
///
/// Sheets remain only for genuinely transient tasks (the open-tabs
/// switcher); primary destinations are tabs.
///
/// AppShell owns:
///   - `selectedTab`: which top-level tab is visible. `openChannel` and
///     Home's resume-chat action write `.chats` here so "tap a channel
///     anywhere → land in its chat" works from every tab.
///   - `chatTabsModel`: the open-channel tab state (which channels are open,
///     which is active), injected via `\.chatTabs` and surfaced in the
///     chat header's switcher.
///
/// It also injects the `\.openChannel` action (open a channel as a new chat
/// tab — used by Home, Following, and Search row taps) and, in a single
/// appearance `.task`, wires `ChatTabsModel`'s `onOpen`/`onClose` to the
/// session registry's acquire/release refcounting, installs
/// `TabPersistence`, and hydrates persisted tabs on cold start.
public struct AppShell: View {
    private let account: Account
    private let accountStore: AccountStore
    /// Twitch client id, threaded down to ProfileScreen → the account
    /// switcher so "Add Account" can run the OAuth flow.
    private let clientId: String

    /// The app's top-level destinations.
    enum AppTab: Hashable {
        case home, chats, you, search
    }

    @State private var selectedTab: AppTab = .home
    @State private var chatTabsModel = ChatTabsModel()

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
        TabView(selection: $selectedTab) {
            Tab("Home", systemImage: "house", value: AppTab.home) {
                HomeScreen(
                    account: account,
                    accountStore: accountStore,
                    onResumeChat: { tab in
                        chatTabsModel.activeTabId = tab.id
                        selectedTab = .chats
                    }
                )
            }
            Tab("Chats", systemImage: "bubble.left.and.bubble.right", value: AppTab.chats) {
                ChatTabsScreen(
                    account: account,
                    accountStore: accountStore,
                    goHome: { selectedTab = .home }
                )
            }
            Tab("You", systemImage: "person.crop.circle", value: AppTab.you) {
                NavigationStack {
                    ProfileScreen(account: account, accountStore: accountStore, clientId: clientId)
                }
            }
            // `role: .search` separates the tab on the trailing edge and
            // morphs it into the search field on activation (iOS 26).
            Tab(value: AppTab.search, role: .search) {
                AddChannelView(
                    account: account,
                    accountStore: accountStore,
                    showsCancelButton: false
                )
            }
        }
        .chatTabBarMinimize()
        .environment(\.chatTabs, chatTabsModel)
        .environment(\.openChannel, OpenChannelAction { channelId, login, displayName, profileImageURL in
            let descriptor = ChannelDescriptor(
                channelId: channelId,
                channelLoginName: login,
                channelDisplayName: displayName,
                profileImageURL: profileImageURL
            )
            chatTabsModel.open(channel: descriptor)
            // Land the user in the chat they just opened, from any tab.
            selectedTab = .chats
        })
        // Single appearance task that does, in this exact order:
        //
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
            // 1. Wire callbacks.
            //
            // Capture stable Strings (`userId`, `login`) rather than the
            // non-Sendable SwiftData `@Model` Account. The closure is
            // stored on `ChatTabsModel.onOpen` for the session lifetime
            // — capturing Account directly would retain it indefinitely
            // (no `weak` possible on `@Model`) and create undefined
            // behavior if multi-account/sign-out ever invalidates the
            // SwiftData context. Matches the existing `onClose` shape.
            chatTabsModel.onOpen = {
                [weak channelSessionRegistry,
                 accountUserId = account.userId,
                 accountLogin = account.login] tab in
                guard let registry = channelSessionRegistry else { return }
                for channel in tab.channels {
                    do {
                        _ = try await registry.acquire(
                            accountUserId: accountUserId,
                            accountLogin: accountLogin,
                            channelId: channel.channelId,
                            channelLoginName: channel.channelLoginName
                        )
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
            chatTabsModel.onClose = { [weak channelSessionRegistry, accountUserId = account.userId] tab in
                guard let registry = channelSessionRegistry else { return }
                for channel in tab.channels {
                    await registry.release(accountUserId: accountUserId, channelId: channel.channelId)
                }
            }

            // 2. Install persistence (uses the container injected by
            //    chattrApp's `.modelContainer(...)`). Construct lazily
            //    here so AppShell doesn't have to take the container as
            //    an init parameter — `@Environment(\.modelContext)` is
            //    the canonical SwiftUI accessor.
            let persistence = TabPersistence(modelContainer: modelContext.container)
            chatTabsModel.persistence = persistence

            // 3. Hydrate. This fires `onOpen` for each restored tab in
            //    order, which acquires sessions in the registry. The
            //    actual EventSub subscriptions happen asynchronously
            //    inside each acquire — the UI shows the restored tab
            //    pills immediately, and messages start flowing in the
            //    chat panel as soon as each subscription confirms.
            chatTabsModel.hydrateFromPersistence()
            logger.info("AppShell wired tab callbacks + persistence; hydration kicked off")
        }
    }
}

private extension View {
    /// `.tabBarMinimizeBehavior` is iOS/iPadOS-only; the Features package
    /// also compiles for macOS where the modifier doesn't exist.
    @ViewBuilder
    func chatTabBarMinimize() -> some View {
        #if os(iOS)
        self.tabBarMinimizeBehavior(.onScrollDown)
        #else
        self
        #endif
    }
}
