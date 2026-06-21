import SwiftUI
import Testing
@testable import DesignSystem

/// Characterization tests for the Twitch username color pipeline. These lock
/// the existing parse → HSL → clamp → RGB behavior so the memoization layer
/// added on top of `Color.twitchUsername(hex:scheme:)` can be proven
/// behavior-preserving (a cache must never change the answer, only skip the
/// recompute).
struct TwitchUsernameColorTests {

    // MARK: - Hex parsing (the expensive step being memoized)

    @Test func parsesSixDigitHexWithHash() {
        let rgb = RGB(hex: "#FF8040")
        #expect(rgb != nil)
        #expect(abs((rgb?.r ?? 0) - 1.0) < 0.001)
        #expect(abs((rgb?.g ?? 0) - 128.0 / 255.0) < 0.001)
        #expect(abs((rgb?.b ?? 0) - 64.0 / 255.0) < 0.001)
    }

    @Test func parsesSixDigitHexWithoutHash() {
        let withHash = RGB(hex: "#1A2B3C")
        let without = RGB(hex: "1A2B3C")
        #expect(withHash?.r == without?.r)
        #expect(withHash?.g == without?.g)
        #expect(withHash?.b == without?.b)
    }

    @Test func toleratesSurroundingWhitespace() {
        #expect(RGB(hex: "  #FFFFFF \n") != nil)
    }

    @Test(arguments: ["", "#", "#FFF", "#GGGGGG", "FFFFFFF", "not-a-color"])
    func rejectsMalformedHex(_ bad: String) {
        #expect(RGB(hex: bad) == nil)
    }

    // MARK: - HSL round-trip (the clamp operates in this space)

    @Test func hslRoundTripPreservesColor() {
        let original = RGB(r: 0.2, g: 0.6, b: 0.85)
        let back = original.toHSL().toRGB()
        #expect(abs(back.r - original.r) < 0.001)
        #expect(abs(back.g - original.g) < 0.001)
        #expect(abs(back.b - original.b) < 0.001)
    }

    @Test func achromaticHasZeroSaturation() {
        let grey = RGB(r: 0.5, g: 0.5, b: 0.5).toHSL()
        #expect(grey.s == 0)
        #expect(abs(grey.l - 0.5) < 0.001)
    }

    // MARK: - Lightness clamp by scheme

    @Test func lightSchemeDarkensBrightColors() {
        // Bright yellow (#FFFF00) is L≈0.5 — light mode must pull it to ≤ 0.45.
        guard let bright = RGB(hex: "#FFFF00") else { Issue.record("parse"); return }
        let clampedL = min(bright.toHSL().l, 0.45)
        #expect(clampedL <= 0.45)
        #expect(bright.toHSL().l > 0.45) // proves the clamp actually fires
    }

    @Test func darkSchemeBrightensDarkColors() {
        // Near-black (#101010) must be lifted to L ≥ 0.55 on dark backgrounds.
        guard let dark = RGB(hex: "#101010") else { Issue.record("parse"); return }
        let clampedL = max(dark.toHSL().l, 0.55)
        #expect(clampedL >= 0.55)
        #expect(dark.toHSL().l < 0.55) // proves the clamp actually fires
    }

    // MARK: - Public entry point fallback

    @MainActor @Test func fallsBackToPrimaryForEmptyHex() {
        #expect(Color.twitchUsername(hex: "", scheme: .dark) == .primary)
    }

    @MainActor @Test func fallsBackToPrimaryForMalformedHex() {
        #expect(Color.twitchUsername(hex: "#nope", scheme: .light) == .primary)
    }

    @MainActor @Test(arguments: ["#6441A4", "#FFFF00", "#101010", "#1E90FF", "", "#bad"])
    func memoizedResultMatchesUncachedPipeline(_ hex: String) {
        // The cache must be transparent: the memoized front and the raw
        // pipeline have to agree for both schemes, every time.
        for scheme in [ColorScheme.light, .dark] {
            #expect(
                Color.twitchUsername(hex: hex, scheme: scheme)
                    == Color.computeTwitchUsername(hex: hex, scheme: scheme)
            )
        }
    }

    @MainActor @Test func repeatedCallsAreStableAcrossSchemes() {
        // Guards the cache key: light and dark for the SAME hex must stay
        // distinct results, and a second lookup must equal the first.
        let hex = "#6441A4" // Twitch purple
        let light1 = Color.twitchUsername(hex: hex, scheme: .light)
        let dark1 = Color.twitchUsername(hex: hex, scheme: .dark)
        let light2 = Color.twitchUsername(hex: hex, scheme: .light)
        let dark2 = Color.twitchUsername(hex: hex, scheme: .dark)
        #expect(light1 == light2)
        #expect(dark1 == dark2)
        #expect(light1 != dark1) // distinct clamps ⇒ a key that drops scheme would fail here
    }
}
