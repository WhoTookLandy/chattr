import SwiftUI
import TwitchKit

/// Environment action invoked when the user taps a channel in the Follows
/// tab. The receiver (AppShell) adds the channel to `ChatTabsModel` and
/// switches the tab selection to Chat.
///
/// This is a closure wrapper rather than passing a direct `ChatTabsModel`
/// because the act of "open this channel" also entails switching tabs —
/// that's owned by `AppShell.selectedTab`, which the leaf views shouldn't
/// know about. The closure encapsulates both side effects behind one verb.
///
/// `Sendable` so the environment-key static default (`nil`) doesn't trip
/// Swift 6's mutable-global-variable check.
///
/// The captured closure is `@MainActor` because AppShell's implementation
/// mutates `selectedTab` and `chatTabsModel` — both `@MainActor`-isolated
/// SwiftUI state. Marking the closure type itself as `@MainActor` lets
/// AppShell's body capture them without "Sendable closure references main-
/// actor state" warnings. The trade-off: `callAsFunction` is also
/// `@MainActor`, so callers must be on the main actor (they always are —
/// they're SwiftUI Views).
public struct OpenChannelAction: Sendable {
    private let perform: @MainActor @Sendable (FollowedChannel, URL?) -> Void

    public init(perform: @MainActor @Sendable @escaping (FollowedChannel, URL?) -> Void) {
        self.perform = perform
    }

    /// `callAsFunction` lets call sites read as `openChannel(channel: x, profileImageURL: y)`
    /// rather than `openChannel.perform(x, y)`. Same idiom Apple uses for `\.openURL`.
    @MainActor
    public func callAsFunction(channel: FollowedChannel, profileImageURL: URL?) {
        perform(channel, profileImageURL)
    }
}

private struct OpenChannelActionKey: EnvironmentKey {
    static let defaultValue: OpenChannelAction? = nil
}

public extension EnvironmentValues {
    /// Open the given channel in the Chat tab. `nil` when the action hasn't
    /// been injected (e.g. in previews); call sites should fall back gracefully
    /// (typically: just do nothing).
    var openChannel: OpenChannelAction? {
        get { self[OpenChannelActionKey.self] }
        set { self[OpenChannelActionKey.self] = newValue }
    }
}
