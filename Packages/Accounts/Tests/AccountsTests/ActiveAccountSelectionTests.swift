import Testing
import Foundation
import Core
@testable import Accounts

@Suite("ActiveAccountSelection (UserDefaults)")
struct ActiveAccountSelectionTests {

    /// Runs `body` against a throwaway defaults suite (so tests never touch
    /// `.standard`), removing the suite afterwards.
    private static func withSelection(_ body: (ActiveAccountSelection) -> Void) {
        let suite = "chattr.tests.selection.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(ActiveAccountSelection(defaults: defaults))
    }

    @Test("select writes the platform's key")
    func selectWrites() {
        Self.withSelection { selection in
            #expect(selection.selectedUserId(on: .twitch) == nil)

            selection.select(userId: "42", on: .twitch)

            #expect(selection.selectedUserId(on: .twitch) == "42")
            #expect(selection.defaults.string(forKey: "chattr.activeAccountUserId") == "42")
        }
    }

    @Test("clear(ifSelected:) only clears a matching selection")
    func clearOnlyMatching() {
        Self.withSelection { selection in
            selection.select(userId: "42", on: .twitch)

            selection.clear(ifSelected: "7", on: .twitch)
            #expect(selection.selectedUserId(on: .twitch) == "42")

            selection.clear(ifSelected: "42", on: .twitch)
            #expect(selection.selectedUserId(on: .twitch) == nil)
        }
    }
}
