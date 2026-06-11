import Testing
@testable import Features

@Suite("Login-name annotation rule")
struct LoginNameAnnotationTests {

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
