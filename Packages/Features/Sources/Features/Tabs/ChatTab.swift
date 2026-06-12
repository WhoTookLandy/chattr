import Foundation
import Core

// ChatPlatform and ChannelDescriptor both live in Core — the Accounts
// package needs the former for the platform-aware Account model, the
// Channels package needs the latter for platform-safe keying, and
// neither can depend on Features.

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

    /// The channels this tab renders. `private(set)` so the non-empty
    /// invariant established in `init` actually holds — when the
    /// multi-channel feature needs mutation, it gets named mutating
    /// methods here that preserve the invariant (e.g. a `remove` that
    /// refuses to drop the last channel) rather than open-ended access.
    public private(set) var channels: [ChannelDescriptor]

    public init(id: UUID = UUID(), channels: [ChannelDescriptor]) {
        precondition(!channels.isEmpty, "ChatTab must have at least one channel")
        self.id = id
        self.channels = channels
    }

    /// Convenience for single-channel tabs (the common case today).
    public init(id: UUID = UUID(), channel: ChannelDescriptor) {
        self.init(id: id, channels: [channel])
    }

    /// Validating decoder — `Codable` synthesis would otherwise bypass the
    /// non-empty precondition, letting a corrupted persistence blob
    /// construct the one state the type promises is impossible. Throwing
    /// here surfaces corruption as a decode error the persistence layer
    /// already handles, instead of a later index-out-of-range crash in
    /// `displayName`. (`encode(to:)` stays synthesized.)
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let channels = try container.decode([ChannelDescriptor].self, forKey: .channels)
        guard !channels.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .channels,
                in: container,
                debugDescription: "ChatTab requires at least one channel"
            )
        }
        self.id = id
        self.channels = channels
    }

    private enum CodingKeys: String, CodingKey {
        case id, channels
    }

    // MARK: - Display

    /// Tab pill label, derived from the contained channels:
    ///   - 1 channel:  "Lirik"          → broadcaster display name verbatim
    ///   - 2 channels: "Lirik · shroud" → middle-dot separator (Twitch convention)
    ///   - 3+:         "Lirik + 2"      → first + count-of-others, pill-width friendly
    ///
    /// `channels` is non-empty by construction (`private(set)` + the init
    /// precondition), so the switch needs no empty case.
    public var displayName: String {
        switch channels.count {
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
}
