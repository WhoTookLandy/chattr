import Testing
import Foundation
import Core
@testable import Features

/// `NavigationIntent(url:)`: which `chattr://` links are navigation, and
/// which are not (the sign-in callback, anything unknown, bad logins).
@Suite("NavigationIntent link parsing")
struct NavigationIntentParsingTests {

    private func intent(_ link: String) -> NavigationIntent? {
        URL(string: link).flatMap { NavigationIntent(url: $0) }
    }

    @Test("A channel link opens that login")
    func channelLink() {
        #expect(intent("chattr://open/channel/shroud") == .openChannel(login: "shroud"))
        #expect(intent("chattr://open/channel/a_b_1") == .openChannel(login: "a_b_1"))
        #expect(intent("chattr://open/channel/shroud/") == .openChannel(login: "shroud"))
    }

    @Test("Scheme, host and ASCII capitals in the login are case-insensitive")
    func caseFolding() {
        #expect(intent("chattr://open/channel/xQc") == .openChannel(login: "xqc"))
        #expect(intent("CHATTR://OPEN/channel/Shroud") == .openChannel(login: "shroud"))
    }

    @Test("Following and Settings links")
    func sectionLinks() {
        #expect(intent("chattr://open/following") == .showFollowing)
        #expect(intent("chattr://open/settings") == .showSettings)
    }

    @Test("The browser sign-in callback is not a navigation link")
    func ignoresSignInCallback() {
        #expect(intent("chattr://oauth-complete?access_token=at-1&refresh_token=rt-1&expires_in=14400") == nil)
        #expect(intent("chattr://oauth-complete?error=access_denied") == nil)
        #expect(intent("chattr://oauth-complete/channel/shroud") == nil)
    }

    @Test("Other schemes, hosts and paths are ignored", arguments: [
        "https://open/channel/shroud",
        "twitch://open/channel/shroud",
        "chattr:open/channel/shroud",
        "chattr://channel/shroud",
        "chattr://open",
        "chattr://open/",
        "chattr://open/channel",
        "chattr://open/channel/",
        "chattr://open/channel/shroud/extra",
        "chattr://open/following/extra",
        "chattr://open/Following",
        "chattr://open/profile",
    ])
    func ignoresUnknownLinks(link: String) {
        #expect(intent(link) == nil)
    }

    @Test("A login must be 1 to 25 characters of a-z, 0-9 and _", arguments: [
        "chattr://open/channel/bad-name",
        "chattr://open/channel/bad.name",
        "chattr://open/channel/bad%20name",
        "chattr://open/channel/b%61d",
        "chattr://open/channel/caf%C3%A9",
        "chattr://open/channel/abcdefghijklmnopqrstuvwxyz",
    ])
    func rejectsInvalidLogins(link: String) {
        #expect(intent(link) == nil)
    }

    @Test("Login length limits and non-ASCII look-alikes")
    func normalizedLogin() {
        #expect(NavigationIntent.normalizedLogin("a") == "a")
        #expect(NavigationIntent.normalizedLogin("abcdefghijklmnopqrstuvwxy") == "abcdefghijklmnopqrstuvwxy")
        #expect(NavigationIntent.normalizedLogin("abcdefghijklmnopqrstuvwxyz") == nil)
        #expect(NavigationIntent.normalizedLogin("") == nil)
        #expect(NavigationIntent.normalizedLogin("has space") == nil)
        // KELVIN SIGN lowercases to an ASCII "k"; it is still not a login.
        #expect(NavigationIntent.normalizedLogin("\u{212A}appa") == nil)
        #expect(NavigationIntent.normalizedLogin("caf\u{E9}") == nil)
    }
}

/// `AppNavigation.handle`: where each intent lands.
@Suite("AppNavigation intents")
@MainActor
struct AppNavigationIntentTests {

    private struct ResolveFailure: Error {}

    private func descriptor(login: String) -> ChannelDescriptor {
        // Unique id so draft pruning can't collide with other suites'
        // UserDefaults entries.
        ChannelDescriptor(
            channelId: "\(login)-\(UUID().uuidString)", channelLoginName: login,
            channelDisplayName: login, profileImageURL: nil
        )
    }

    @Test("A channel intent resolves the login and lands in its chat")
    func openChannelLandsInChat() async {
        let navigation = AppNavigation()
        var asked: [String] = []

        await navigation.handle(.openChannel(login: "shroud")) { login in
            asked.append(login)
            return descriptor(login: login)
        }

        #expect(asked == ["shroud"])
        #expect(navigation.selectedTab == .chats)
        #expect(navigation.chatTabs.tabs.map { $0.channels[0].channelLoginName } == ["shroud"])
        #expect(navigation.chatTabs.isPresented)
    }

    @Test("A login that can't be resolved changes nothing")
    func unresolvedChannelChangesNothing() async {
        let navigation = AppNavigation()

        await navigation.handle(.openChannel(login: "nobody")) { _ in
            throw ResolveFailure()
        }

        #expect(navigation.selectedTab == .home)
        #expect(navigation.chatTabs.tabs.isEmpty)
    }

    @Test("Following lands on Home's Following section, at the root")
    func showFollowing() async {
        let navigation = AppNavigation()
        navigation.selectedTab = .activity
        navigation.homePath = [.profile]

        await navigation.handle(.showFollowing) { login in descriptor(login: login) }

        #expect(navigation.selectedTab == .home)
        #expect(navigation.homeSection == .following)
        #expect(navigation.homePath.isEmpty)
    }

    @Test("Settings asks Home for its Settings screen")
    func showSettings() async {
        let navigation = AppNavigation()
        navigation.selectedTab = .chats

        await navigation.handle(.showSettings) { login in descriptor(login: login) }

        #expect(navigation.selectedTab == .home)
        #expect(navigation.homePath == [.profile])
    }
}
