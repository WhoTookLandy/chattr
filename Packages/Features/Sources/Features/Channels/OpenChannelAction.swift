import SwiftUI
import TwitchKit

/// Environment action invoked when the user taps a channel anywhere in the
/// app (Follows tab — Live OR All view). Opens the channel as a new chat
/// tab and makes it active.
///
/// Takes plain fields rather than a `FollowedChannel` so the Live view can
/// dispatch from a `TwitchStream` source without synthesizing a fake
/// `FollowedChannel` (which would also imply a fake `followedAt` date that
/// downstream code might trust).
///
/// `Sendable` so the environment-key static default (`nil`) doesn't trip
/// Swift 6's mutable-global-variable check.
///
/// The captured closure is `@MainActor` because AppShell's implementation
/// mutates `chatTabsModel` — `@MainActor`-isolated SwiftUI state.
public struct OpenChannelAction: Sendable {
    private let perform: @MainActor @Sendable (
        _ channelId: String,
        _ login: String,
        _ displayName: String,
        _ profileImageURL: URL?
    ) -> Void

    public init(
        perform: @MainActor @Sendable @escaping (
            _ channelId: String,
            _ login: String,
            _ displayName: String,
            _ profileImageURL: URL?
        ) -> Void
    ) {
        self.perform = perform
    }

    /// `callAsFunction` lets call sites read as
    /// `openChannel(channelId: x, login: y, displayName: z, profileImageURL: w)`.
    @MainActor
    public func callAsFunction(
        channelId: String,
        login: String,
        displayName: String,
        profileImageURL: URL?
    ) {
        perform(channelId, login, displayName, profileImageURL)
    }

    /// Convenience for FollowedChannel call sites (the All view).
    @MainActor
    public func callAsFunction(channel: FollowedChannel, profileImageURL: URL?) {
        perform(channel.broadcasterId, channel.broadcasterLogin, channel.broadcasterName, profileImageURL)
    }

    /// Convenience for TwitchStream call sites (the Live view).
    @MainActor
    public func callAsFunction(stream: TwitchStream, profileImageURL: URL?) {
        perform(stream.userId, stream.userLogin, stream.userName, profileImageURL)
    }
}

public extension EnvironmentValues {
    /// Open the given channel in the Chat tab. `nil` when the action hasn't
    /// been injected (e.g. in previews); call sites should fall back gracefully.
    @Entry var openChannel: OpenChannelAction? = nil
}
