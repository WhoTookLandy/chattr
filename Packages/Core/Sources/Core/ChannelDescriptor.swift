import Foundation

/// A single channel on a single platform — the app-wide currency type for
/// channel identity. Replaces the previous `OpenChannelDescriptor` (which
/// was implicitly Twitch-only and 1:1 with a tab). A channel may appear in
/// multiple tabs simultaneously; the registry deduplicates the underlying
/// `ChannelSession` so we still only open one EventSub subscription per
/// channel regardless of how many tabs reference it.
///
/// Composite identity (`platform/channelId`) means same-named channels on
/// different platforms are treated as distinct (e.g., `twitch/xqc` ≠
/// `kick/xqc`). Anything that keys storage by channel — drafts, caches —
/// should key on `id`, never on the bare `channelId`, so platform-2
/// channels can never collide with platform-1 entries.
///
/// Lives in Core (same rationale as `ChatPlatform`): the UI layer
/// (tabs, channel rows), the Channels package (session keying), and
/// Accounts-adjacent code all need to name it, and none of them can
/// depend on Features.
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
