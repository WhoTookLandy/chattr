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
    ///
    /// Activating a tab marks its mention as seen — looking at the chat IS
    /// acknowledging the ping, no separate "mark read" affordance needed.
    public var activeTabId: UUID? {
        didSet {
            if let activeTabId {
                mentionedTabIds.remove(activeTabId)
            }
        }
    }

    /// Tabs holding an unseen @-mention of the signed-in user — drives the
    /// red dots in the quick-switcher popover and the channel pill.
    /// Populated by the session-level watcher AppShell installs in `onOpen`
    /// (session-level because `TabChatModel` only receives events while its
    /// page is mounted — a background tab's mentions would be missed).
    /// Cleared when the tab becomes active or closes.
    public private(set) var mentionedTabIds: Set<UUID> = []

    /// Flags `tabId` as carrying an unseen mention. No-ops for the active
    /// tab (the user is looking at it) and for unknown ids (a stale watcher
    /// firing after its tab closed).
    public func markMention(tabId: UUID) {
        guard tabId != activeTabId,
              tabs.contains(where: { $0.id == tabId }) else { return }
        mentionedTabIds.insert(tabId)
    }

    /// Whether `text` @-mentions `login` as a whole word — "@landy" matches,
    /// "@landyish" doesn't. Twitch logins are `[a-z0-9_]`, so any other
    /// following character (or end of text) terminates the mention.
    // nonisolated: pure text predicate, called from the @Sendable session
    // event handler off the main actor.
    public nonisolated static func containsMention(of login: String, in text: String) -> Bool {
        guard !login.isEmpty else { return false }
        let haystack = text.lowercased()
        let needle = "@\(login.lowercased())"
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let match = haystack.range(of: needle, range: searchRange) {
            if match.upperBound == haystack.endIndex {
                return true
            }
            let next = haystack[match.upperBound]
            if !(next.isLetter || next.isNumber || next == "_") {
                return true
            }
            searchRange = match.upperBound..<haystack.endIndex
        }
        return false
    }

    /// Called when a tab is opened — either freshly via `open(channel:)` /
    /// `open(_:)`, or restored from persistence at cold start. AppShell
    /// wires this to iterate the tab's channels and call
    /// `registry.acquire(...)` for each — establishing the refcount that
    /// keeps EventSub subscriptions alive while the tab is open.
    ///
    /// Symmetric with `onClose`: every `onOpen` for a tab is balanced by
    /// exactly one `onClose` when the tab is removed, so refcounts stay
    /// honest across the tab's lifetime.
    public var onOpen: (@MainActor @Sendable (ChatTab) async -> Void)?

    /// Called when a tab is closed. AppShell wires this to iterate the tab's
    /// channels and call `registry.release(accountUserId:channelId:)` for
    /// each. Passing the full `ChatTab` (rather than just an ID) lets
    /// AppShell iterate the channels without needing a separate lookup.
    public var onClose: (@MainActor @Sendable (ChatTab) async -> Void)?

    /// On-disk persistence handle. `nil` for tests and for the brief window
    /// before AppShell wires it up; non-nil in production. Each
    /// mutation calls `persistence?.save(tabs:)` so tabs survive cold start.
    ///
    /// Why nullable: keeping ChatTabsModel constructible without a
    /// `ModelContainer` is important for previews and unit tests. The
    /// production injection point is AppShell, which has the container in
    /// scope.
    public var persistence: TabPersistence?

    /// Active hydration Task, stored so it can be cancelled if the model
    /// is torn down (sign-out, multi-account swap) before hydration
    /// completes. Without this, the Task would run to completion against
    /// a potentially-gone registry, firing no-op acquires.
    private var hydrationTask: Task<Void, Never>?

    /// In-flight `onOpen` tasks, keyed by tab id. Tracked so that:
    ///   - a `close` for the same tab can await the acquire before releasing
    ///     (preventing a release-before-acquire race that underflows the
    ///     registry refcount and leaks the channel's EventSub subscription on
    ///     Twitch's side), and
    ///   - teardown (`cancelHydration`) can cancel pending acquires.
    ///
    /// Bounded by the number of currently-open tabs: `close` clears its entry,
    /// and a completed open leaves a single harmless finished `Task` per open
    /// tab. Previously these were fire-and-forget `Task {}`s with neither
    /// tracking nor race protection.
    private var openTasks: [UUID: Task<Void, Never>] = [:]

    public init() {}

    // MARK: - Persistence

    /// Write the current tab list to disk. Best-effort: a save failure logs
    /// and continues — UI state has already been updated, and the next
    /// successful save will overwrite. We never want a SwiftData hiccup to
    /// roll back a UI mutation the user just made.
    private func persistTabs() {
        guard let persistence else { return }
        do {
            try persistence.save(tabs: tabs)
        } catch {
            // Don't surface — tab list is fine in memory. On next mutation
            // we'll try again; on cold start without this save, the user
            // sees the previous snapshot, which is recoverable.
        }
    }

    /// Hydrate tabs from persistence on cold start. Called by AppShell's
    /// `.task` after `persistence` has been wired up. Restores `tabs` in
    /// stored order and fires `onOpen` for each tab so the registry's
    /// refcount + EventSub subscriptions resume.
    ///
    /// Active tab restoration is *not* handled here — that lives in
    /// `@SceneStorage` because it's window-state, not account-data. See
    /// `ChatTabsScreen` for the `@SceneStorage` binding.
    public func hydrateFromPersistence() {
        guard let persistence else { return }
        do {
            let rows = try persistence.fetchAll()
            let restored = rows.map { $0.toChatTab() }
            tabs = restored
            // Cancel any prior hydration that's still in flight (rare —
            // would only happen if hydrate is called twice rapidly).
            hydrationTask?.cancel()
            // Fire onOpen for each so the registry acquires sessions.
            // Done sequentially via a single stored Task so the ordering
            // matches the persisted strip order AND so we can cancel it
            // on teardown (sign-out / multi-account swap).
            if let onOpen {
                hydrationTask = Task {
                    for tab in restored {
                        guard !Task.isCancelled else { return }
                        await onOpen(tab)
                    }
                }
            }
        } catch {
            // Empty start is the safe fallback — the user will see the
            // empty-state on the Chat tab and can re-open whichever
            // channels they want.
        }
    }

    /// Cancel any in-flight hydration. Call this from teardown paths
    /// (sign-out, account swap) where the hydration's onOpen would
    /// fire against a stale registry. Idempotent — no-op if hydration
    /// already completed or wasn't running.
    public func cancelHydration() {
        hydrationTask?.cancel()
        hydrationTask = nil
        // Pending tab acquires would otherwise fire onOpen against a stale
        // registry after teardown.
        for task in openTasks.values { task.cancel() }
        openTasks.removeAll()
    }

    // MARK: - Open

    /// Adds the tab to the strip and makes it active. If a tab with the same
    /// `id` already exists, this no-ops on the list but still switches the
    /// active tab to it — useful for "open this channel" idempotency.
    ///
    /// `onOpen` fires only when a *new* tab is actually appended. The
    /// idempotent re-focus path (same `id` already present) skips it to
    /// keep the refcount honest — re-focusing isn't a new acquisition.
    public func open(_ tab: ChatTab) {
        let isNew = !tabs.contains(where: { $0.id == tab.id })
        if isNew {
            tabs.append(tab)
            persistTabs()
        }
        activeTabId = tab.id
        if isNew, let onOpen {
            openTasks[tab.id] = Task { await onOpen(tab) }
        }
    }

    /// Convenience for the common case: open a single channel as a new tab.
    /// Returns the new tab's id so callers can reference it (e.g., to switch
    /// focus or persist).
    ///
    /// `onOpen` fires only when a new tab is actually appended. The
    /// idempotent re-focus path (same channel already in a single-channel
    /// tab) skips it for the same refcount-honesty reason as `open(_:)`.
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
        persistTabs()
        if let onOpen {
            openTasks[tab.id] = Task { await onOpen(tab) }
        }
        return tab.id
    }

    // MARK: - Reorder

    /// Reorders open tabs (drag-to-reorder in the channel switcher). Mirrors
    /// `Array.move(fromOffsets:toOffset:)` semantics so it can back an
    /// `.onMove` in a SwiftUI `List`/`ForEach`. Persists the new order;
    /// `activeTabId` is unaffected because it tracks identity, not index.
    public func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        tabs.move(fromOffsets: source, toOffset: destination)
        persistTabs()
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
        mentionedTabIds.remove(tabId)
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
        persistTabs()
        if let onClose {
            // Await any in-flight acquire for this tab before releasing, so the
            // registry refcount is settled first. Closing mid-acquire would
            // otherwise let release run ahead of acquire, underflowing the
            // count and leaking the channel's EventSub subscription.
            let pendingOpen = openTasks[tabId]
            openTasks[tabId] = nil
            Task {
                await pendingOpen?.value
                await onClose(closed)
            }
        }
    }
}

// MARK: - Environment plumbing

public extension EnvironmentValues {
    /// UI state for the Chat tab's open channels. Injected by `AppShell`.
    /// nil default for the same MainActor-isolation reason as other Features
    /// environment values — `@MainActor` instances can't be constructed in
    /// a nonisolated static context. AppShell provides the real value.
    @Entry var chatTabs: ChatTabsModel? = nil
}
