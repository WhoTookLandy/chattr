import SwiftUI
import NukeUI

/// Shared renderer for a single emote image.
///
/// Both the inline chat emote (`TwitchEmoteImage`) and the picker grid cell
/// (`EmoteCell`) make the same load-bearing decision: animated emotes decode
/// frame-by-frame through ImageIO via `AnimatedImageView`, while the static
/// majority take Nuke's cheap, memory-cached `LazyImage` path. That branch —
/// not the surrounding layout — is what was duplicated, so it lives here once.
///
/// Call-site-specific differences stay as knobs:
/// - `width`/`height` size the animated renderer's box.
/// - `boxSize` optionally pins the whole view to a fixed frame (picker cells
///   want a square; inline chat emotes leave it `nil` so width follows the
///   glyph's natural aspect ratio).
/// - `staticImage` builds the resolved static `Image` (interpolation, framing).
/// - `placeholder` covers the loading state and — for the static path — the
///   failure state, distinguished by the `failed` flag.
struct EmoteImageView<StaticContent: View, Placeholder: View>: View {
    let url: URL?
    let isAnimated: Bool
    /// Frame for the animated (`AnimatedImageView`) renderer.
    let width: CGFloat
    let height: CGFloat
    let accessibilityLabel: String
    /// Fixed box applied to the whole view, or `nil` to size naturally.
    var boxSize: CGSize? = nil
    @ViewBuilder var staticImage: (Image) -> StaticContent
    @ViewBuilder var placeholder: (_ failed: Bool) -> Placeholder

    var body: some View {
        Group {
            if isAnimated {
                AnimatedImageView(url: url, width: width, height: height) { failed in
                    placeholder(failed)
                }
            } else {
                LazyImage(url: url) { state in
                    if let image = state.image {
                        staticImage(image)
                    } else if state.isLoading {
                        placeholder(false)
                    } else {
                        placeholder(true)
                    }
                }
            }
        }
        // `nil` width/height is a flexible (non-constraining) frame, so inline
        // emotes pass through untouched while picker cells get their square.
        .frame(width: boxSize?.width, height: boxSize?.height)
        .accessibilityLabel(Text(accessibilityLabel))
    }
}
