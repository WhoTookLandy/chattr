import SwiftUI
import Core
import os
#if canImport(UIKit)
import UIKit
#endif

private let logger = AppLogger.make("Features.AppNavigation")

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

    /// Home's navigation stack (`HomeScreen` binds to it), so a navigation
    /// intent can push Settings.
    var homePath: [HomeRoute] = []

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

    /// Carries out a navigation intent: the one place a destination
    /// requested from outside the view tree (a `chattr://open/...` link)
    /// lands. `resolveChannel` turns a login into its channel; when it
    /// throws (no such channel, offline) nothing changes.
    func handle(
        _ intent: NavigationIntent,
        resolveChannel: @MainActor (String) async throws -> ChannelDescriptor
    ) async {
        switch intent {
        case .openChannel(let login):
            do {
                let channel = try await resolveChannel(login)
                openChannel(channel)
            } catch {
                logger.warning("Couldn't open #\(login, privacy: .public) from a link: \(error.localizedDescription, privacy: .public)")
            }
        case .showFollowing:
            homePath = []
            homeSection = .following
            selectedTab = .home
        case .showSettings:
            homePath = [.profile]
            selectedTab = .home
        }
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
