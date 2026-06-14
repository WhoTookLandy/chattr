import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Fills for the compose bar's two trailing circle buttons.
///
/// The bar pairs a charcoal emote circle with a warm orange send circle —
/// same size, different weight — mirroring the Claude composer, where a
/// dark mic circle sits beside the orange send circle. "Open emotes"
/// reads as a quiet control; "post this" reads as the single CTA. The
/// app's `AccentColor` asset is system blue, deliberately NOT used here.
///
/// Both live in the design system (not inlined in the view) so the shades
/// have one home if they spread to other surfaces later.
public extension Color {

    /// Warm orange fill for the send button. Constant across light/dark —
    /// a vivid accent that must stay unmistakably "the send button."
    static let sendButton = Color(red: 0.886, green: 0.420, blue: 0.235) // ~#E26B3C

    /// Fill for the emote button — a filled circle echoing the Claude mic
    /// button. A *translucent* tint (light-on-dark, dark-on-light) rather
    /// than a fixed grey: the compose pill is a glass surface over a
    /// near-black chat, so a solid charcoal disc (the literal mic shade)
    /// vanishes into it. A translucent fill always sits a step lighter
    /// than whatever's behind it, so the circle reads in both schemes —
    /// the same trick the nav back/gear glass circles use.
    static let emoteButton: Color = {
        #if canImport(UIKit)
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 1, alpha: 0.16)
                : UIColor(white: 0, alpha: 0.06)
        })
        #elseif canImport(AppKit)
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 1, alpha: 0.16)
                : NSColor(white: 0, alpha: 0.06)
        })
        #else
        Color(white: 1, opacity: 0.16)
        #endif
    }()
}
