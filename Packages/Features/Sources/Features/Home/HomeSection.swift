import SwiftUI

/// Home's three top-level sections. Lives on `AppNavigation` so "open a
/// channel" from anywhere can land on Chats, and "see who's live" on Live.
public enum HomeSection: String, CaseIterable, Hashable, Sendable {
    case live, following

    var title: String {
        switch self {
        case .live: "Live"
        case .following: "Following"
        }
    }
}
