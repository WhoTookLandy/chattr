import SwiftUI
import NukeUI

/// Shared renderer for a single emote image.
///
/// Every emote surface — the inline Twitch emote (`TwitchEmoteImage`), the
/// inline 7TV / BTTV / FFZ emote (`ThirdPartyEmoteImage`), and the picker
/// grid cell (`EmoteCell`) — makes the same load-bearing decision: animated
/// emotes decode frame-by-frame through ImageIO via `AnimatedImageView`,
/// while the static majority take Nuke's cheap, memory-cached `LazyImage`
/// path. That branch — not the surrounding layout — is what was duplicated,
/// so it lives here once.
///
/// Call-site-specific differences stay as knobs:
/// - `width`/`height` size the animated renderer's box.
/// - `boxSize` optionally pins the whole view to a fixed frame (inline chat
///   emotes pin their metadata-derived box so a row never reflows; picker
///   cells pin a square).
/// - `animate` false shows an animated emote's poster frame. It still takes
///   the frame decoder rather than `LazyImage`: a first-frame-only decode
///   renders delta-encoded WebPs (blank opening frame) as empty space,
///   while the decoder picks the first VISIBLE frame.
/// - `staticImage` builds the resolved static `Image` (interpolation, framing).
/// - `placeholder` covers loading (`failed == false`) and failure
///   (`failed == true`).
struct EmoteImageView<StaticContent: View, Placeholder: View>: View {
    let url: URL?
    let isAnimated: Bool
    /// Frame for the animated (`AnimatedImageView`) renderer.
    let width: CGFloat
    let height: CGFloat
    let accessibilityLabel: String
    /// Fixed box applied to the whole view, or `nil` to size naturally.
    var boxSize: CGSize? = nil
    /// From `ChatAppearance.animatedEmotes`; see the type docs.
    var animate: Bool = true
    @ViewBuilder var staticImage: (Image) -> StaticContent
    @ViewBuilder var placeholder: (_ failed: Bool) -> Placeholder

    var body: some View {
        Group {
            if isAnimated {
                AnimatedImageView(url: url, width: width, height: height, animate: animate) { failed in
                    placeholder(failed)
                }
            } else {
                LazyImage(url: url) { state in
                    if let image = state.image {
                        staticImage(image)
                    } else {
                        // Failed only on an actual error: before the load
                        // starts the state is neither loading nor failed,
                        // and that first frame should show the loading
                        // stand-in, not the failure one.
                        placeholder(state.error != nil)
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
