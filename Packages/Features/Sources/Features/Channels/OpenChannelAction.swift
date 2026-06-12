import SwiftUI
import Core
import TwitchKit

/// Environment action invoked when the user taps a channel anywhere in the
/// app (Home, Follows — Live OR All view, search). Opens the channel as a
/// new chat tab and makes it active.
///
/// The core currency is `ChannelDescriptor` — the platform-qualified
/// channel identity — so this seam never erases which platform a channel
/// lives on. The Twitch-typed conveniences below are the only places that
/// say `.twitch`; when a second platform arrives it adds its own overload
/// and the core path is already correct.
///
/// `Sendable` so the environment-key static default (`nil`) doesn't trip
/// Swift 6's mutable-global-variable check.
///
/// The captured closure is `@MainActor` because AppShell's implementation
/// mutates `chatTabsModel` — `@MainActor`-isolated SwiftUI state.
public struct OpenChannelAction: Sendable {
    private let perform: @MainActor @Sendable (ChannelDescriptor) -> Void

    public init(perform: @MainActor @Sendable @escaping (ChannelDescriptor) -> Void) {
        self.perform = perform
    }

    /// Primary entry point — `callAsFunction` lets call sites read as
    /// `openChannel(descriptor)`.
    @MainActor
    public func callAsFunction(_ channel: ChannelDescriptor) {
        perform(channel)
    }

    /// Convenience for FollowedChannel call sites (the All view).
    @MainActor
    public func callAsFunction(channel: FollowedChannel, profileImageURL: URL?) {
        perform(ChannelDescriptor(
            platform: .twitch,
            channelId: channel.broadcasterId,
            channelLoginName: channel.broadcasterLogin,
            channelDisplayName: channel.broadcasterName,
            profileImageURL: profileImageURL
        ))
    }

    /// Convenience for TwitchStream call sites (the Live view, Home).
    @MainActor
    public func callAsFunction(stream: TwitchStream, profileImageURL: URL?) {
        perform(ChannelDescriptor(
            platform: .twitch,
            channelId: stream.userId,
            channelLoginName: stream.userLogin,
            channelDisplayName: stream.userName,
            profileImageURL: profileImageURL
        ))
    }
}

public extension EnvironmentValues {
    /// Open the given channel in the Chat tab. `nil` when the action hasn't
    /// been injected (e.g. in previews); call sites should fall back gracefully.
    @Entry var openChannel: OpenChannelAction? = nil
}
