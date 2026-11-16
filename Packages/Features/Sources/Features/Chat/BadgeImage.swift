import SwiftUI
import Channels
import NukeUI

/// Inline chat badge in a fixed 18pt square (scaled with the chat text
/// size). The box is reserved from the first layout pass, so the row never
/// reflows when the image lands; while loading — or after a failure — the
/// slot is simply empty, with no stand-in icon (rows read cleaner without
/// one, and the username + message render regardless).
///
/// `interpolation(.high)` matters: badges are bitmaps downsampled from 72px
/// (source 4x) to 54px physical pixels on @3x devices, and small icons look
/// jagged without high-quality interpolation.
struct BadgeImage: View {
    let entry: ChatBadgeEntry
    /// Size multiplier from the chat text-size setting.
    var scale: CGFloat = 1

    var body: some View {
        LazyImage(url: entry.url) { state in
            if let image = state.image {
                image
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                // Empty slot; the fixed frame below keeps the space.
                Color.clear.frame(width: 0, height: 0)
            }
        }
        .frame(width: 18 * scale, height: 18 * scale)
        .accessibilityLabel(entry.title ?? "Chat badge")
    }
}
