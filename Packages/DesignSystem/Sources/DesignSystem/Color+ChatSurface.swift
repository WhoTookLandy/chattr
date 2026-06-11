import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The chat transcript's background surface.
///
/// Plain `systemBackground` renders chat on pure black in dark mode —
/// harsh against the message text and visibly different from Twitch's
/// own chat surface, which sits a few percent above black (#18181B).
/// This color lifts the dark surface just enough to soften the contrast
/// while staying unmistakably "dark mode", and gives light mode a faint
/// off-white so chat doesn't read as a bare white page.
///
/// Values are deliberately close to Twitch's web/app chat surfaces
/// (dark #18181B-family, light #F7F7F8) so usernames colored by
/// `Color.twitchUsername(hex:scheme:)` keep the contrast they were
/// clamped for.
public extension Color {

    static let chatSurface: Color = {
        #if canImport(UIKit)
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 22 / 255, green: 22 / 255, blue: 25 / 255, alpha: 1)    // #161619
                : UIColor(red: 247 / 255, green: 247 / 255, blue: 248 / 255, alpha: 1) // #F7F7F8
        })
        #elseif canImport(AppKit)
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(red: 22 / 255, green: 22 / 255, blue: 25 / 255, alpha: 1)
                : NSColor(red: 247 / 255, green: 247 / 255, blue: 248 / 255, alpha: 1)
        })
        #else
        Color(red: 22 / 255, green: 22 / 255, blue: 25 / 255)
        #endif
    }()
}
