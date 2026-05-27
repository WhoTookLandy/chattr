import Testing
@testable import EmoteSources

@Suite("EmoteSources placeholder")
struct EmoteSourcesPlaceholderTests {
    // Real provider decoding tests are added in Task 7 of slice-2 once we have
    // all three providers implemented. This file exists only so SPM's testTarget
    // path is non-empty (silences the 'Source files should be located under...'
    // warning we hit during slice-1).
    @Test("EmoteSources scaffolding placeholder")
    func placeholder() {
        // `Bool(true)` indirection avoids Swift Testing's "always passes" tautology
        // warning on `#expect(true)`.
        #expect(Bool(true))
    }
}
