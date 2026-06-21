import Testing
@testable import ChatModel

/// Locks `ChatLine.hasLocalizedDisplayName` — the precomputed flag that lets
/// the renderer skip the per-body `displayName.lowercased() != login` check
/// (two heap allocations) on the ~95% of chatters whose display name is just
/// their login. The trigger must mirror `ChatAppearance.loginAnnotation`'s
/// (the Features-layer cross-check test `LoginNameAnnotationTests` guards the
/// agreement from the other side).
struct ChatLineLocalizedNameTests {

    private func line(display: String, login: String) -> ChatLine {
        ChatLine(id: "1", authorDisplayName: display, authorUserLogin: login, runs: [])
    }

    @Test func flagsTrulyLocalizedName() {
        #expect(line(display: "デレク", login: "derek").hasLocalizedDisplayName)
    }

    @Test func ignoresCaseOnlyDifference() {
        // "Derek" vs "derek" is just the signup capitalization, not a
        // localized name — no annotation, so the flag is false.
        #expect(!line(display: "Derek", login: "derek").hasLocalizedDisplayName)
    }

    @Test func falseWhenNamesMatchExactly() {
        #expect(!line(display: "derek", login: "derek").hasLocalizedDisplayName)
    }

    @Test func falseWhenLoginEmpty() {
        // System/bubble lines carry no login — nothing to annotate against.
        #expect(!line(display: "Charity Event", login: "").hasLocalizedDisplayName)
    }

    @Test func falseWhenDisplayEmpty() {
        #expect(!line(display: "", login: "derek").hasLocalizedDisplayName)
    }

    @Test func preservedAcrossMarkingDeleted() {
        let original = line(display: "デレク", login: "derek")
        #expect(original.markingDeleted().hasLocalizedDisplayName)
    }
}
