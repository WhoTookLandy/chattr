#if os(iOS)
import CoreGraphics

/// The video tile's resting widths (16:9). Pinching snaps to the nearest.
enum MiniPlayerSize: String, CaseIterable {
    case small, medium, large

    static let storageKey = "chattr.miniPlayer.size"

    var width: CGFloat {
        switch self {
        case .small: 160
        case .medium: 208
        case .large: 288
        }
    }

    /// The size whose width is closest to `width`.
    static func nearest(to width: CGFloat) -> MiniPlayerSize {
        allCases.min { abs($0.width - width) < abs($1.width - width) } ?? .medium
    }
}
#endif
