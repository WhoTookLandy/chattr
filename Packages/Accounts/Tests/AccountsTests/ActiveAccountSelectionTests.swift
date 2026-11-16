import Testing
import Foundation
import Core
@testable import Accounts

@Suite("ActiveAccountSelection (UserDefaults)")
struct ActiveAccountSelectionTests {

    /// A throwaway defaults suite so tests never touch `.standard`.
    private static func makeSelection() -> ActiveAccountSelection {
        let defaults = UserDefaults(suiteName: "chattr.tests.selection.\(UUID().uuidString)")!
        return ActiveAccountSelection(defaults: defaults)
    }

    @Test("select writes the platform's key")
    func selectWrites() {
        let selection = Self.makeSelection()
        #expect(selection.selectedUserId(on: .twitch) == nil)

        selection.select(userId: "42", on: .twitch)

        #expect(selection.selectedUserId(on: .twitch) == "42")
        #expect(selection.defaults.string(forKey: "chattr.activeAccountUserId") == "42")
    }

    @Test("clear(ifSelected:) only clears a matching selection")
    func clearOnlyMatching() {
        let selection = Self.makeSelection()
        selection.select(userId: "42", on: .twitch)

        selection.clear(ifSelected: "7", on: .twitch)
        #expect(selection.selectedUserId(on: .twitch) == "42")

        selection.clear(ifSelected: "42", on: .twitch)
        #expect(selection.selectedUserId(on: .twitch) == nil)
    }
}
