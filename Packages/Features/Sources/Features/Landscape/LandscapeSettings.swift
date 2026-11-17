import SwiftUI

/// Preferences for watching a stream with chat in landscape. Stored with
/// `@AppStorage` under these keys, like `PlayerSettings`.
///
/// Settings rows: `LandscapeSettingsScreen` (linked from You → Video). When
/// the Features/Settings registry lands, register that screen there.
enum LandscapeSettings {
    /// Which side of the video the chat column sits on.
    static let chatSideKey = "chattr.landscape.chatSide"
    /// Chat beside the video, or a translucent column over it.
    static let layoutKey = "chattr.landscape.layout"
    /// The chat column's width in points, set by dragging the divider.
    static let chatWidthKey = "chattr.landscape.chatWidth"
    /// How opaque the chat surface is in the "over video" layout.
    static let overlayOpacityKey = "chattr.landscape.overlayOpacity"

    static let defaultChatWidth: Double = 340
    static let defaultOverlayOpacity: Double = 0.55
    static let overlayOpacityRange: ClosedRange<Double> = 0.15...0.9

    /// Narrowest usable chat column: a username plus a few words per line.
    static let minChatWidth: CGFloat = 240
    /// Widest the chat may get, as a share of the screen — the video keeps
    /// the rest.
    static let maxChatFraction: CGFloat = 0.6

    /// The largest chat width allowed in a container `containerWidth` wide.
    static func maxChatWidth(containerWidth: CGFloat) -> CGFloat {
        max(minChatWidth, (containerWidth * maxChatFraction).rounded())
    }

    /// `width` clamped to the allowed range. Before the container has been
    /// measured (`containerWidth == 0`) only the minimum applies.
    static func clampedChatWidth(_ width: CGFloat, containerWidth: CGFloat) -> CGFloat {
        let upper = containerWidth > 0 ? maxChatWidth(containerWidth: containerWidth) : .greatestFiniteMagnitude
        return min(max(width, minChatWidth), upper)
    }
}

/// Which side of the video the chat sits on in landscape.
enum LandscapeChatSide: String, CaseIterable, Identifiable {
    case right
    case left

    var id: String { rawValue }

    var label: String {
        switch self {
        case .right: "Right"
        case .left: "Left"
        }
    }

    /// The chat column's horizontal edge.
    var edge: Edge.Set {
        switch self {
        case .right: .trailing
        case .left: .leading
        }
    }

    var alignment: Alignment {
        switch self {
        case .right: .trailing
        case .left: .leading
        }
    }
}

/// How chat and video share a landscape screen.
enum LandscapeLayoutMode: String, CaseIterable, Identifiable {
    /// Video and chat side by side; neither covers the other.
    case beside
    /// Video fills the screen; chat is a translucent column over it.
    case overlay

    var id: String { rawValue }

    var label: String {
        switch self {
        case .beside: "Chat beside video"
        case .overlay: "Chat over video"
        }
    }
}

/// What a chat page's landscape stage is doing, handed down the environment
/// to the few views inside the chat column that care (the stream header,
/// the chat surface). Equatable, so SwiftUI only re-renders those readers
/// when it actually changes — on rotation or a settings change, never per
/// frame of a divider drag (the drag is local to `LandscapeDividerHandle`).
struct LandscapeStageContext: Equatable {
    /// The video is showing on the landscape stage beside / under the chat.
    var isActive = false
    /// Opacity of the chat surface: 1 except in the "over video" layout.
    var surfaceOpacity: Double = 1

    static let inactive = LandscapeStageContext()
}

extension EnvironmentValues {
    @Entry var landscapeStage = LandscapeStageContext.inactive
}
