import Foundation
import Core

// ChatPlatform moved to Core — the Accounts package needs it for the
// platform-aware Account model, and Accounts can't depend on Features.

/// A single channel on a single platform. Replaces the previous
/// `OpenChannelDescriptor` (which was implicitly Twitch-only and 1:1 with
/// a tab). A channel may now appear in multiple tabs simultaneously; the
/// registry deduplicates the underlying `ChannelSession` so we still only
/// open one EventSub subscription per channel regardless of how many tabs
/// reference it.
///
/// Composite identity (`platform/channelId`) means same-named channels on
/// different platforms are treated as distinct (e.g., `twitch/xqc` ≠
/// `kick/xqc`).
public struct ChannelDescriptor: Hashable, Codable, Sendable, Identifiable {
    public let platform: ChatPlatform
    public let channelId: String
    public let channelLoginName: String
    public let channelDisplayName: String
    public let profileImageURL: URL?

    public var id: String { "\(platform.rawValue)/\(channelId)" }

    public init(
        platform: ChatPlatform = .twitch,
        channelId: String,
        channelLoginName: String,
        channelDisplayName: String,
        profileImageURL: URL?
    ) {
        self.platform = platform
        self.channelId = channelId
        self.channelLoginName = channelLoginName
        self.channelDisplayName = channelDisplayName
        self.profileImageURL = profileImageURL
    }
}

/// A tab in the Chat screen's horizontal navigation. Always contains at
/// least one channel; today exactly one for the MVP, future allows N for
/// the multi-channel merged-chat feature.
///
/// `id` is a stable UUID — independent from the channels' IDs so the user
/// can have multiple tabs containing the same channel set (e.g., one tab
/// with just lirik, another with lirik + shroud). The UUID also serves as
/// the `.scrollPosition(id:)` anchor in the paged ScrollView (commit C)
/// and the SwiftData primary key (commit E).
public struct ChatTab: Hashable, Codable, Sendable, Identifiable {
    public let id: UUID
    public var channels: [ChannelDescriptor]

    public init(id: UUID = UUID(), channels: [ChannelDescriptor]) {
        precondition(!channels.isEmpty, "ChatTab must have at least one channel")
        self.id = id
        self.channels = channels
    }

    /// Convenience for single-channel tabs (the common case today).
    public init(id: UUID = UUID(), channel: ChannelDescriptor) {
        self.init(id: id, channels: [channel])
    }

    // MARK: - Display

    /// Tab pill label, derived from the contained channels:
    ///   - 1 channel:  "Lirik"          → broadcaster display name verbatim
    ///   - 2 channels: "Lirik · shroud" → middle-dot separator (Twitch convention)
    ///   - 3+:         "Lirik + 2"      → first + count-of-others, pill-width friendly
    public var displayName: String {
        switch channels.count {
        case 0:
            // Precondition guards against this in init, but if a future code
            // path mutates `channels` to empty, render something reasonable.
            return "Chat"
        case 1:
            return channels[0].channelDisplayName
        case 2:
            return "\(channels[0].channelDisplayName) · \(channels[1].channelDisplayName)"
        default:
            return "\(channels[0].channelDisplayName) + \(channels.count - 1)"
        }
    }

    /// Avatar URL for the tab. Uses the first channel's profile image — for
    /// multi-channel tabs the strip cell could render a small "stack" of
    /// avatars later. Today: just the leader.
    public var profileImageURL: URL? {
        channels.first?.profileImageURL
    }

    /// Convenience for view code that needs to know "does this tab include
    /// channel X?" — used by the FollowsStore-aware UI to mark already-open
    /// channels visually in the list.
    public func contains(channelId: String, platform: ChatPlatform = .twitch) -> Bool {
        channels.contains { $0.platform == platform && $0.channelId == channelId }
    }
}
