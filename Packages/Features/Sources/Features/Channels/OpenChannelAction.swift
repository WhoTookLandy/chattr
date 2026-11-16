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
/// `Sendable` so the environment-key static default (the no-op action)
/// doesn't trip Swift 6's mutable-global-variable check. The no-op default
/// is what previews and detached views get — call sites never unwrap.
///
/// ## Why a stable reference, not a stored closure
///
/// This stores the `AppNavigation` model (a `@MainActor @Observable`, hence
/// `Sendable`) rather than a `(ChannelDescriptor) -> Void` closure. The
/// difference is observation cost: SwiftUI compares environment values to
/// decide which readers re-evaluate, and it compares structs field-by-field.
/// A *closure* field can't be compared, so SwiftUI treats the value as
/// changed on every `AppShell.body` pass and invalidates every reader of
/// `\.openChannel` (Home / Follows / Search rows). A *reference* field
/// compares by identity — `OpenChannelAction(navigation)` rebuilt each body
/// pass but holding the same `@State`-owned `AppNavigation` pointer compares
/// equal, so readers don't spuriously invalidate. (See the SwiftUI
/// "closures in the environment" guidance — custom env actions don't get the
/// framework's special-cased comparison that `OpenURLAction` etc. enjoy.)
public struct OpenChannelAction: Sendable {
    /// `nil` only for the environment default (no AppShell ancestor), which
    /// makes every call a no-op.
    private let navigation: AppNavigation?

    init(_ navigation: AppNavigation) {
        self.navigation = navigation
    }

    /// The do-nothing action — the environment default.
    private init() {
        self.navigation = nil
    }

    public static let noop = OpenChannelAction()

    /// Primary entry point — `callAsFunction` lets call sites read as
    /// `openChannel(descriptor)`.
    @MainActor
    public func callAsFunction(_ channel: ChannelDescriptor) {
        navigation?.openChannel(channel)
    }

    /// Convenience for FollowedChannel call sites (the All view).
    @MainActor
    public func callAsFunction(channel: FollowedChannel, profileImageURL: URL?) {
        callAsFunction(ChannelDescriptor(
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
        callAsFunction(ChannelDescriptor(
            platform: .twitch,
            channelId: stream.userId,
            channelLoginName: stream.userLogin,
            channelDisplayName: stream.userName,
            profileImageURL: profileImageURL
        ))
    }
}

public extension EnvironmentValues {
    /// Open the given channel in the Chat tab. Injected by `AppShell`; the
    /// default (previews, detached views) is a no-op.
    @Entry var openChannel: OpenChannelAction = .noop
}
