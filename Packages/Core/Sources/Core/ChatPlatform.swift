import Foundation

/// Platform a chat identity or channel lives on. Single case today
/// (`.twitch`) — the enum exists now so every reference to "a channel"
/// or "an account" already carries a platform tag, removing the need to
/// retrofit every type when Kick / YouTube Live / etc. arrive.
///
/// Lives in Core (not Features) because both the UI layer (channel
/// descriptors, tabs) and the Accounts package (platform-aware sign-in,
/// per-platform active account) need it, and Accounts can't depend on
/// Features.
///
/// `Codable` so the SwiftData persistence layer can round-trip platform
/// values without a string conversion at the boundary.
public enum ChatPlatform: String, Codable, Hashable, Sendable, CaseIterable {
    case twitch
    // Future:
    // case kick
    // case youtube

    /// Human-readable platform name for section headers and switcher UI.
    public var displayName: String {
        switch self {
        case .twitch: return "Twitch"
        }
    }
}
