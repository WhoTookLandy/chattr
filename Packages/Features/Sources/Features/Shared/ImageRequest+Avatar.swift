import CoreGraphics
import Foundation
import Nuke

extension ImageRequest {
    /// A request for a circular avatar displayed at `side` × `side` points.
    ///
    /// Twitch profile images are typically 300×300 px; decoding and caching
    /// them full-size for a 20–64 pt circle wastes decode time and memory-
    /// cache space across long follow lists. The resize processor downsamples
    /// to the displayed size (in points, scaled for the screen), aspect-fill
    /// and centre-cropped to a square — matching the `scaledToFill()` +
    /// `Circle()` clip the rows already apply. The processed image is cached
    /// under its own key, so different sizes of one avatar don't collide.
    ///
    /// Returns nil for a nil URL so `LazyImage(request:)` shows its
    /// placeholder, same as `LazyImage(url: nil)`.
    static func avatar(url: URL?, side: CGFloat) -> ImageRequest? {
        guard let url else { return nil }
        return ImageRequest(
            url: url,
            processors: [
                ImageProcessors.Resize(
                    size: CGSize(width: side, height: side),
                    unit: .points,
                    contentMode: .aspectFill,
                    crop: true
                )
            ]
        )
    }
}
