import Foundation
import SwiftUI

/// Owns the *UI* state for the Chat tab: which tabs are open, which one is
/// currently visible. Tab-centric rather than channel-centric — a tab is the
/// user-facing concept; the channels inside it are an implementation detail
/// that today happens to be 1:1 with the tab but in the future may be N:1.
///
/// Why this is separate from `ChannelSessionRegistry`:
///   - The registry holds the actor-isolated session objects (data layer).
///     A `ChannelSession` is per-(account × channel) and may be referenced
///     by multiple tabs (commit E adds reference counting for clean
///     deallocation).
///   - This model holds the user's UI selection (which tab is visible,
///     which tabs exist). Pure SwiftUI state.
///
/// Close-X behavior: removes the tab from `tabs` and fires the `onClose`
/// callback. AppShell wires that callback to call
/// `registry.leave(accountUserId:channelId:)` for each channel in the tab.
/// Sessions that are still referenced by other tabs survive (ref-count >
/// 0 after the leave); orphaned sessions are torn down. The user's
/// EventSub subscription on Twitch's side is properly released via
/// TwitchKit's `eventSub.unsubscribe(id:)` (added in v0.2.1).
@MainActor
@Observable
public final class ChatTabsModel {

    /// All currently-open tabs, in user-defined order.
    public private(set) var tabs: [ChatTab] = []

    /// The currently-visible tab. `nil` when no tabs are open (the Chat tab
    /// shows its empty-state CTA in that case). Public-settable so the
    /// `.scrollPosition(id:)` binding in the paged ScrollView (commit C)
    /// can write back when the user swipes between pages.
    public var activeTabId: UUID?

    /// Called when a tab is closed. AppShell wires this to iterate the tab's
    /// channels and call `registry.leave(accountUserId:channelId:)` for each.
    /// Passing the full `ChatTab` (rather than just an ID) lets AppShell
    /// iterate the channels without needing a separate lookup.
    public var onClose: (@MainActor (ChatTab) async -> Void)?

    public init() {}

    // MARK: - Open

    /// Adds the tab to the strip and makes it active. If a tab with the same
    /// `id` already exists, this no-ops on the list but still switches the
    /// active tab to it — useful for "open this channel" idempotency.
    public func open(_ tab: ChatTab) {
        if !tabs.contains(where: { $0.id == tab.id }) {
            tabs.append(tab)
        }
        activeTabId = tab.id
    }

    /// Convenience for the common case: open a single channel as a new tab.
    /// Returns the new tab's id so callers can reference it (e.g., to switch
    /// focus or persist).
    @discardableResult
    public func open(channel: ChannelDescriptor) -> UUID {
        // If an existing tab has just this channel, re-open it rather than
        // creating a duplicate (idempotent open-from-follows).
        if let existing = tabs.first(where: { $0.channels.count == 1 && $0.channels[0] == channel }) {
            activeTabId = existing.id
            return existing.id
        }
        let tab = ChatTab(channel: channel)
        tabs.append(tab)
        activeTabId = tab.id
        return tab.id
    }

    // MARK: - Close

    /// Closes the tab with the given id. Updates UI state synchronously (so
    /// the pill disappears immediately) and fires the `onClose` callback
    /// asynchronously to let AppShell tear down the underlying channel
    /// sessions.
    ///
    /// If the closed tab was active, falls back to the previous tab (or the
    /// new first if the closed tab was index 0). Returns to no-selection only
    /// when the last tab is closed.
    public func close(tabId: UUID) {
        guard let closedIndex = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let closed = tabs.remove(at: closedIndex)
        let wasActive = (activeTabId == tabId)
        if wasActive {
            // Prefer the tab to the left for "natural" rightward-close UX.
            // If we closed index 0, fall to the new index 0 (which was 1).
            if closedIndex > 0 {
                activeTabId = tabs[closedIndex - 1].id
            } else {
                activeTabId = tabs.first?.id
            }
        }
        if let onClose {
            Task { await onClose(closed) }
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
