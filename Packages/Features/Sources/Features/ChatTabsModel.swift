import Foundation
import SwiftUI

/// Snapshot of one open chat tab — what the tab strip displays.
///
/// `id == channelId` so SwiftUI's diffing tracks individual tabs across
/// add/remove animations. The login + display name + profile-image are
/// captured at open-time so the tab strip can render without a separate
/// fetch round-trip.
public struct OpenChannelDescriptor: Hashable, Identifiable, Sendable {
    public let channelId: String
    public let channelLoginName: String
    public let channelDisplayName: String
    public let profileImageURL: URL?

    public var id: String { channelId }

    public init(
        channelId: String,
        channelLoginName: String,
        channelDisplayName: String,
        profileImageURL: URL?
    ) {
        self.channelId = channelId
        self.channelLoginName = channelLoginName
        self.channelDisplayName = channelDisplayName
        self.profileImageURL = profileImageURL
    }
}

/// Owns the *UI* state for the Chat tab: which channels appear in the tab
/// strip, which one is currently visible.
///
/// Why this is separate from `ChannelSessionRegistry`:
///   - The registry holds the actor-isolated session objects (data layer).
///     Sessions stay in the registry for fast re-open; closing a tab strip
///     entry doesn't necessarily destroy the session.
///   - This model holds the user's UI selection (which tab is visible, which
///     tabs exist). Pure SwiftUI state.
///
/// Close-X behavior: removes the descriptor from `openChannels` and (for now)
/// leaves the session in the registry alive. Re-opening from the Follows tab
/// reuses the same session — instant, no re-subscribe to EventSub needed.
/// True "delete the Twitch subscription" requires TwitchKit upstream support;
/// when added, `close(channelId:)` can also call `registry.leave(...)`.
@MainActor
@Observable
public final class ChatTabsModel {

    public private(set) var openChannels: [OpenChannelDescriptor] = []

    /// The currently-visible tab. `nil` when no tabs are open (the Chat tab
    /// shows its empty-state CTA in that case).
    public var activeChannelId: String?

    public init() {}

    /// Adds the descriptor as a tab (or moves it to active if already open)
    /// and selects it. Called from the Follows tab when a channel is tapped.
    public func open(_ descriptor: OpenChannelDescriptor) {
        if !openChannels.contains(where: { $0.channelId == descriptor.channelId }) {
            openChannels.append(descriptor)
        }
        activeChannelId = descriptor.channelId
    }

    /// Closes the tab for `channelId`. If the closed tab was active, falls
    /// back to the first remaining (or `nil` if none).
    public func close(channelId: String) {
        let wasActive = (activeChannelId == channelId)
        openChannels.removeAll { $0.channelId == channelId }
        if wasActive {
            activeChannelId = openChannels.first?.channelId
        }
    }
}

// MARK: - Environment plumbing

private struct ChatTabsModelKey: EnvironmentKey {
    /// nil default for the same MainActor-isolation reason as other Features
    /// environment values — `@MainActor` instances can't be constructed in
    /// a nonisolated static context. AppShell provides the real value.
    static let defaultValue: ChatTabsModel? = nil
}

public extension EnvironmentValues {
    /// UI state for the Chat tab's open channels. Injected by `AppShell`.
    var chatTabs: ChatTabsModel? {
        get { self[ChatTabsModelKey.self] }
        set { self[ChatTabsModelKey.self] = newValue }
    }
}
