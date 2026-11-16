import Foundation
import SwiftUI
import Core

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
/// `registry.release(accountUserId:channelId:)` for each channel in the tab.
/// Sessions that are still referenced by other tabs survive (ref-count >
/// 0 after the release); orphaned sessions are torn down. The user's
/// EventSub subscription on Twitch's side is properly released via
/// TwitchKit's `eventSub.unsubscribe(id:)` (added in v0.2.1).
///
/// ## Open/close balance
///
/// Every `onOpen` is scheduled through `scheduleOpen`, which records a task
/// in `openTasks` resolving to whether `onOpen` actually ran. Every release
/// path (`close`, `tearDown`) *removes* that entry, awaits it, and calls
/// `onClose` only if it resolved `true`. Removing the entry is what makes the
/// release exactly-once (a tab can't be released by both `close` and
/// `tearDown`), and awaiting it is what keeps release from running ahead of
/// an in-flight acquire.
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
    /// (session-level because `ChatTranscriptModel` only receives events while its
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
    /// exactly one `onClose` when the tab is closed or the model is torn
    /// down, so refcounts stay honest across the tab's lifetime. A tab whose
    /// `onOpen` never ran gets no `onClose` either.
    public var onOpen: (@MainActor @Sendable (ChatTab) async -> Void)?

    /// Called when a tab is closed (or released by `tearDown()`). AppShell
    /// wires this to iterate the tab's channels and call
    /// `registry.release(accountUserId:channelId:)` for each. Passing the full
    /// `ChatTab` (rather than just an ID) lets AppShell iterate the channels
    /// without needing a separate lookup.
    public var onClose: (@MainActor @Sendable (ChatTab) async -> Void)?

    /// On-disk persistence handle, scoped to the signed-in account. `nil`
    /// for tests and for the brief window before AppShell wires it up (and
    /// again after `tearDown()`); non-nil in production. Each mutation calls
    /// `persistence?.save(tabs:)` so tabs survive cold start.
    ///
    /// Why nullable: keeping ChatTabsModel constructible without a
    /// `ModelContainer` is important for previews and unit tests. The
    /// production injection point is AppShell, which has the container in
    /// scope.
    public var persistence: TabPersistence?

    /// True once a successful hydrate has run for THIS model instance (reset
    /// by `tearDown()`). `hydrateFromPersistence()` is idempotent against it:
    /// a second call (e.g. AppShell's `.task` re-firing) is a no-op, so it
    /// can't churn `tabs` 0→1 and spuriously tear down + rebuild a live
    /// channel session. A genuine account swap creates a fresh model (AppShell
    /// is `.id(userId)`), which hydrates the new account's tabs.
    private var hasHydrated = false

    /// Bumped by `tearDown()`. Each scheduled open captures the generation it
    /// was created in and skips `onOpen` if the model was torn down before it
    /// started — that's how teardown cancels *pending* acquires (including
    /// the not-yet-reached tail of a hydration) without cancelling one that
    /// is already mid-flight.
    private var generation = 0

    /// In-flight / completed `onOpen` tasks, keyed by tab id, resolving to
    /// whether `onOpen` actually ran for the tab. Tracked so that:
    ///   - `close` can await the acquire before releasing (preventing a
    ///     release-before-acquire race that underflows the registry refcount
    ///     and leaks the channel's EventSub subscription on Twitch's side) —
    ///     this includes tabs restored by hydration, and
    ///   - `close` / `tearDown` release a tab only if it was acquired, and
    ///     only once (each removes the entry it consumes).
    ///
    /// Bounded by the number of currently-open tabs: release paths remove
    /// their entries, and a completed open leaves a single finished `Task`
    /// per open tab.
    private var openTasks: [UUID: Task<Bool, Never>] = [:]

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

    /// Hydrate tabs from persistence on cold start (or account appearance).
    /// Called by AppShell's `.task` after `persistence` has been wired up.
    /// Restores `tabs` in stored order and fires `onOpen` for each tab so the
    /// registry's refcount + EventSub subscriptions resume. Corrupt rows
    /// (no channels) are skipped.
    ///
    /// Active tab restoration is *not* handled here — that lives in
    /// `@SceneStorage` because it's window-state, not account-data. See
    /// `ChatTabsScreen` for the `@SceneStorage` binding.
    public func hydrateFromPersistence() {
        guard let persistence else { return }
        // Idempotent: only hydrate once per model. A re-run would reset `tabs`
        // and re-fire onOpen, which (paired with a transient empty save) churns
        // the registry refcount and tears down a live session for no reason.
        guard !hasHydrated else { return }
        do {
            let restored = try persistence.fetchAll().compactMap { $0.toChatTab() }
            tabs = restored
            hasHydrated = true
            // One recorded task per tab, each chained after the previous so
            // acquires run sequentially in persisted strip order. Recording
            // them per tab (rather than one opaque hydration task) is what lets
            // `close` on a restored tab wait for — or skip — its acquire.
            var previous: Task<Bool, Never>?
            for tab in restored {
                previous = scheduleOpen(tab, after: previous)
            }
        } catch {
            // Empty start is the safe fallback — the user will see the
            // empty-state on the Chat tab and can re-open whichever
            // channels they want.
        }
    }

    /// Release everything this model holds in the session registry: called by
    /// AppShell when it goes away (account switch, sign-out). After this:
    ///   - opens that haven't started yet (e.g. the rest of a hydration)
    ///     never call `onOpen`;
    ///   - every tab whose `onOpen` ran — or is mid-flight, which is awaited
    ///     rather than cancelled, since cancelling an acquire part-way and
    ///     then releasing would unbalance the refcount — gets exactly one
    ///     `onClose`;
    ///   - `persistence` is detached, so nothing about the teardown is
    ///     written to disk (the account's saved strip stays intact).
    ///
    /// Idempotent: a second call finds no recorded opens and does nothing.
    /// `tabs` is left as-is (the view is leaving anyway), and the hydrate
    /// guard is reset so that if this same model re-appears, AppShell's
    /// `.task` re-wires persistence and re-hydrates — re-acquiring what was
    /// released here.
    public func tearDown() {
        generation &+= 1
        hasHydrated = false
        persistence = nil
        let pending = openTasks
        openTasks.removeAll()
        let releases = tabs.compactMap { tab in pending[tab.id].map { (tab, $0) } }
        releaseAfterOpen(releases)
    }

    /// Schedules `onOpen(tab)` (after `prior`, if given) and records it in
    /// `openTasks`. The task resolves `false` without calling `onOpen` if the
    /// model was torn down, or the tab closed, before it got to run. Returns
    /// `nil` (records nothing) when no `onOpen` is wired.
    @discardableResult
    private func scheduleOpen(_ tab: ChatTab, after prior: Task<Bool, Never>? = nil) -> Task<Bool, Never>? {
        guard let onOpen else { return nil }
        let scheduledGeneration = generation
        let tabId = tab.id
        let task = Task { [weak self] () async -> Bool in
            _ = await prior?.value
            guard let self,
                  self.generation == scheduledGeneration,
                  self.tabs.contains(where: { $0.id == tabId })
            else { return false }
            await onOpen(tab)
            return true
        }
        openTasks[tabId] = task
        return task
    }

    /// Fires `onClose` for each tab whose recorded open resolves `true`,
    /// sequentially, after that open completes. Callers must already have
    /// removed the entries from `openTasks` (that removal is the
    /// exactly-once guarantee).
    private func releaseAfterOpen(_ releases: [(ChatTab, Task<Bool, Never>)]) {
        guard let onClose, !releases.isEmpty else { return }
        Task {
            for (tab, openTask) in releases {
                guard await openTask.value else { continue }
                await onClose(tab)
            }
        }
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
        if isNew {
            scheduleOpen(tab)
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
        scheduleOpen(tab)
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

    /// Closes the tab with the given id. See `close(tabIds:)`.
    public func close(tabId: UUID) {
        close(tabIds: [tabId])
    }

    /// Closes the tabs with the given ids (unknown ids are ignored). Updates
    /// UI state synchronously (so the rows disappear immediately), persists
    /// ONCE for the whole batch, prunes the compose drafts of channels no
    /// longer open in any tab, and fires `onClose` asynchronously to let
    /// AppShell tear down the underlying channel sessions.
    ///
    /// If a closed tab was active, falls back to the previous tab (or the
    /// new first if the closed tab was index 0). Returns to no-selection only
    /// when the last tab is closed.
    public func close(tabIds: [UUID]) {
        var closedTabs: [ChatTab] = []
        for tabId in tabIds {
            guard let closedIndex = tabs.firstIndex(where: { $0.id == tabId }) else { continue }
            closedTabs.append(tabs.remove(at: closedIndex))
            mentionedTabIds.remove(tabId)
            if activeTabId == tabId {
                // Prefer the tab to the left for "natural" rightward-close UX.
                // If we closed index 0, fall to the new index 0 (which was 1).
                if closedIndex > 0 {
                    activeTabId = tabs[closedIndex - 1].id
                } else {
                    activeTabId = tabs.first?.id
                }
            }
        }
        guard !closedTabs.isEmpty else { return }
        persistTabs()

        // A draft belongs to a channel, not a tab: keep it while any remaining
        // tab still shows that channel.
        let stillOpen = Set(tabs.flatMap { $0.channels.map(\.id) })
        let orphanedChannels = Set(closedTabs.flatMap { $0.channels.map(\.id) })
            .subtracting(stillOpen)
        DraftStorage.remove(forChannels: Array(orphanedChannels))

        // Each release awaits its tab's acquire (including one still queued by
        // hydration) so the registry refcount is settled first — releasing
        // mid-acquire would underflow the count and leak the channel's EventSub
        // subscription. A tab whose acquire never ran resolves `false` and is
        // not released at all.
        let releases = closedTabs.compactMap { tab in
            openTasks.removeValue(forKey: tab.id).map { (tab, $0) }
        }
        releaseAfterOpen(releases)
    }
}
