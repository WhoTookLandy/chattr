import SwiftUI
import Nuke
#if canImport(UIKit)
import UIKit
#endif

/// The You tab's icon: the signed-in account's avatar as a small circle
/// (Twitch-style), so the tab bar also shows WHICH account is active — the
/// thing a multi-account app most needs to make obvious.
///
/// Tab bar items only render `Image`s (not arbitrary views like
/// `LazyImage`), so the avatar is fetched through Nuke, drawn into a
/// fixed-size circular bitmap, and marked `.alwaysOriginal` so the tab bar
/// doesn't flatten it into a tint silhouette. Falls back to the SF Symbol
/// until it loads, and always on macOS.
enum ProfileTabIcon {
    /// Point size of the rendered circle — matches SF Symbol tab glyphs.
    static let side: CGFloat = 28

    static var fallback: Image { Image(systemName: "person.crop.circle") }

    #if canImport(UIKit)
    /// Main-actor: the fetch itself is async inside Nuke; the 28pt redraw
    /// is trivial, and staying on main avoids handing a UIImage across
    /// isolation domains.
    @MainActor
    static func load(urlString: String) async -> UIImage? {
        guard let url = URL(string: urlString),
              let request = ImageRequest.avatar(url: url, side: side),
              let image = try? await ImagePipeline.shared.image(for: request)
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        let rounded = UIGraphicsImageRenderer(size: rect.size).image { _ in
            UIBezierPath(ovalIn: rect).addClip()
            image.draw(in: rect)
        }
        return rounded.withRenderingMode(.alwaysOriginal)
    }
    #endif
}
