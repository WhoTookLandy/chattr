import Foundation
import CoreGraphics

/// Resolution cap for the native player. `auto` lets AVPlayer adapt freely.
enum PlayerQuality: String, CaseIterable, Identifiable {
    case auto, p1080, p720, p480, p360

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: "Auto"
        case .p1080: "1080p"
        case .p720: "720p"
        case .p480: "480p"
        case .p360: "360p"
        }
    }

    /// `.zero` = no cap (AVFoundation's sentinel).
    var maximumResolution: CGSize {
        switch self {
        case .auto: .zero
        case .p1080: CGSize(width: 1920, height: 1080)
        case .p720: CGSize(width: 1280, height: 720)
        case .p480: CGSize(width: 854, height: 480)
        case .p360: CGSize(width: 640, height: 360)
        }
    }
}
