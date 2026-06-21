import Testing
import ChatModel
@testable import Features

@Suite("Login-name annotation rule")
struct LoginNameAnnotationTests {

    /// `ChatLine.hasLocalizedDisplayName` (precomputed in ChatModel) is the
    /// fast-path gate the renderer uses to skip `loginAnnotation` on the
    /// common case. The two carry the same trigger in different modules, so
    /// this locks them together: for any non-`.off` style, the flag must
    /// agree with "annotation would be produced". Catches drift if one
    /// formula changes without the other.
    @Test("Flag agrees with annotation trigger", arguments: [
        ("デレク", "derek"),   // localized → both true
        ("Shroud", "shroud"), // case-only → both false
        ("ninja", "ninja"),   // exact → both false
        ("デレク", ""),         // no login → both false
        ("", "derek"),        // no display → both false
    ])
    func flagMatchesAnnotationTrigger(_ pair: (display: String, login: String)) {
        let line = ChatLine(
            id: "1", authorDisplayName: pair.display,
            authorUserLogin: pair.login, runs: []
        )
        let annotates = ChatAppearance.loginAnnotation(
            displayName: pair.display, login: pair.login, style: .displayFirst
        ) != nil
        #expect(line.hasLocalizedDisplayName == annotates)
    }

    @Test("Localized name, display-first → (display, login)")
    func localizedDisplayFirst() {
        let pair = ChatAppearance.loginAnnotation(
            displayName: "デレク", login: "derek", style: .displayFirst
        )
        #expect(pair?.primary == "デレク")
        #expect(pair?.secondary == "derek")
    }

    @Test("Localized name, login-first → (login, display)")
    func localizedLoginFirst() {
        let pair = ChatAppearance.loginAnnotation(
            displayName: "デレク", login: "derek", style: .loginFirst
        )
        #expect(pair?.primary == "derek")
        #expect(pair?.secondary == "デレク")
    }

    @Test("Capitalization-only difference → nil (adds nothing)")
    func capitalizationOnly() {
        #expect(ChatAppearance.loginAnnotation(
            displayName: "Shroud", login: "shroud", style: .displayFirst
        ) == nil)
    }

    @Test("Exact match → nil")
    func exactMatch() {
        #expect(ChatAppearance.loginAnnotation(
            displayName: "ninja", login: "ninja", style: .loginFirst
        ) == nil)
    }

    @Test("Off style → nil even when names differ")
    func offStyle() {
        #expect(ChatAppearance.loginAnnotation(
            displayName: "デレク", login: "derek", style: .off
        ) == nil)
    }

    @Test("Empty login → nil")
    func emptyLogin() {
        #expect(ChatAppearance.loginAnnotation(
            displayName: "デレク", login: "", style: .displayFirst
        ) == nil)
    }

    @Test("Empty display name → nil")
    func emptyDisplayName() {
        #expect(ChatAppearance.loginAnnotation(
            displayName: "", login: "derek", style: .displayFirst
        ) == nil)
    }
}
