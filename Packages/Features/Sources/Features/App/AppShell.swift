import SwiftUI
import SwiftData
import Accounts
import Channels
import Core
import os

private let logger = AppLogger.make("Features.AppShell")

/// Top-level navigation shell for a signed-in user: a TabView with two tabs.
///
///   - `Follows` — the channel list (ChannelListScreen) inside its own
///     NavigationStack so the Settings push still works.
///   - `Chat` — the multi-channel chat surface (ChatTabsScreen) inside its
///     own NavigationStack so future channel-specific drill-downs (mods,
///     viewers, etc.) can push.
///
/// Each tab's NavigationStack is independent — they don't share back-stacks.
///
/// ## Modern Tab struct syntax (iOS 18+)
///
/// Uses the `Tab(_:systemImage:value:content:)` initializer rather than the
/// pre-iOS-18 "subview + .tabItem + .tag" pattern. Benefits:
///   - Unlocks `Tab(role: .search)` for future search-specific tabs (gets
///     iOS 26's morph-from-tab-icon-to-search-field animation automatically).
///   - Unlocks `.sidebarAdaptable` for iPad layouts (sidebar in landscape,
///     bottom tabs in portrait) with `TabSection` groupings.
///   - Unlocks `.hidden(_:)` with state preservation, `.customizationID(_:)`
///     for user-rearrangeable tab orders persisted via `TabViewCustomization`.
///   - Composes cleanly with `.tabBarMinimizeBehavior(_:)` (iOS 26+).
///
/// ## Auto-minimize on scroll
///
/// `.tabBarMinimizeBehavior(.onScrollDown)` collapses the bottom tab bar to
/// a compact form when the user scrolls down through tab content, and
/// re-expands on scroll up. Both our tabs have meaningful scroll content
/// (Follows = channel list, Chat = paged ChatScreens with their own scroll
/// views), so the behavior is contextual: more vertical real estate while
/// reading; chrome reappears when the user goes back to the top.
///
/// AppShell owns:
///   - `selectedTab`: which tab is visible.
///   - `chatTabsModel`: the open-channel tab strip state.
///
/// It exposes both via `@Environment` to descendants, plus an
/// `OpenChannelAction` closure that descendants (specifically
/// `ChannelListScreen`'s row tap) invoke to "open this channel in chat" —
/// the closure both adds the channel to the model AND switches the tab.
public struct AppShell: View {
    private let account: Account
    private let accountStore: AccountStore
    /// Twitch client id, threaded down to ProfileScreen → the account
    /// switcher so "Add Account" can run the OAuth flow.
    private let clientId: String

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
        ChatTabsScreen(
            account: account,
            accountStore: accountStore,
            clientId: clientId
        )
        .environment(\.chatTabs, chatTabsModel)
        .environment(\.openChannel, OpenChannelAction { channelId, login, displayName, profileImageURL in
            let descriptor = ChannelDescriptor(
                channelId: channelId,
                channelLoginName: login,
                channelDisplayName: displayName,
                profileImageURL: profileImageURL
            )
            chatTabsModel.open(channel: descriptor)
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
