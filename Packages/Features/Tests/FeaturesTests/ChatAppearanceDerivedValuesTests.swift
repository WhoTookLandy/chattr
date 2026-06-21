import SwiftUI
import Testing
@testable import Features

/// Locks the `font` / `imageScale` derivation from `textSizePoints`. These
/// were computed properties (re-evaluated on every `ChatRow.body`, allocating
/// a `Font` each time); they're now stored once at `init`. The observable
/// values must be identical before and after that change.
@MainActor
struct ChatAppearanceDerivedValuesTests {

    @Test func defaultSizeProducesCalloutFontAndUnitScale() {
        let appearance = ChatAppearance()
        #expect(appearance.font == .system(size: ChatAppearance.defaultTextSizePoints))
        #expect(appearance.imageScale == 1.0)
    }

    @Test func fontTracksTextSizePoints() {
        let appearance = ChatAppearance(textSizePoints: 20)
        #expect(appearance.font == .system(size: 20))
    }

    @Test func imageScaleIsSizeOverDefault() {
        let appearance = ChatAppearance(textSizePoints: 24)
        // 24 / 16 = 1.5. Compare CGFloat-to-CGFloat with a tolerance rather
        // than an exact `==` against a Double expression — mixed CGFloat/Double
        // equality is a fragile-float trap, not a correctness signal.
        #expect(abs(appearance.imageScale - 1.5) < 0.0001)
    }

    @Test func smallerSizeShrinksImageScaleBelowOne() {
        let appearance = ChatAppearance(textSizePoints: 12)
        #expect(appearance.imageScale < 1.0)
        #expect(abs(appearance.imageScale - 0.75) < 0.0001) // 12 / 16
    }
}
