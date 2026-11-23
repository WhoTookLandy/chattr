import Foundation
import Core
import os

private let logger = AppLogger.make("Features.DraftStorage")

/// Per-account, per-channel chat draft persistence backed by UserDefaults.
///
/// ## Why UserDefaults instead of SwiftData
///
/// Drafts are short, non-sensitive, and inherently transient — the user
/// types "wb", swipes to another channel, comes back to find their "wb"
/// still in the compose bar. UserDefaults is the right storage tool for
/// "small transient user state":
///
///   - **Size**: tens to hundreds of characters per channel × ~10
///     active channels = a few KB at most. Well below the UserDefaults
///     per-key 4MB recommendation.
///   - **Security**: drafts are not credentials. The user can read them
///     directly in the compose bar; persisting them at the same trust
///     level is fine.
///   - **Schema cost**: SwiftData would need either a new @Model or a
///     migration to add a field to `PersistedChatTab`. UserDefaults
///     needs neither.
///   - **Access pattern**: load once on mount; keystrokes go through
///     `scheduleSave`, which debounces (~400ms) so a burst of typing costs
///     one dictionary read-modify-write instead of one per keystroke.
///     `flushPendingSaves()` (compose bar disappearing, app leaving the
///     foreground) writes anything still pending immediately.
///   - **Lifetime**: a channel's draft is pruned when its last tab closes
///     (`remove(forChannels:)`, called by `ChatTabsModel.close`), and an
///     account's drafts go with the account (`removeAll(forAccount:)`).
///
/// ## Account scoping
///
/// Drafts are per account — the same channel open under two accounts keeps
/// two drafts. Each account's drafts live in their own dictionary
/// (`storageKey(forAccount:)`). The channel-keyed API below reads and writes
/// the **active** account's dictionary, set by AppShell via
/// `activate(accountUserId:)` before it hydrates any tab, so compose-bar
/// call sites don't need to know which account they belong to.
///
/// With no active account (unit tests, previews) the API falls back to the
/// pre-scoping legacy dictionary. On upgrade, the first account to activate
/// adopts whatever the legacy dictionary holds (`migrateLegacyDrafts`) — the
/// same "first account adopts legacy data" rule as `TabPersistence`.
///
/// ## Storage shape
///
/// Within a dictionary, drafts are keyed by `ChannelDescriptor.ID` — the
/// composite "platform/channelId" string — so same-numbered channels on
/// different platforms can never share a draft. Empty drafts are removed
/// rather than stored as empty strings — keeps the dictionary tight and
/// means "no draft" reads as nil consistently.
public enum DraftStorage {

    /// Pre-account-scoping UserDefaults key. Read by the one-shot migration
    /// and used directly only when no account is active. The name says
    /// "byChannelId" but entries are keyed by the composite
    /// `ChannelDescriptor.ID` (see the bare-channelId fallback in `load`).
    static let legacyStorageKey = "chattr.drafts.byChannelId"

    /// UserDefaults key for one account's drafts dictionary.
    static func storageKey(forAccount accountUserId: String) -> String {
        "chattr.drafts.byAccount.\(accountUserId)"
    }

    // MARK: - Active account

    /// `Account.userId` whose drafts the channel-keyed API uses, or nil for
    /// the legacy dictionary. Lock-guarded rather than `@MainActor` so the
    /// nonisolated `load` / `save` can read it.
    private static let activeAccount = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// The dictionary key the channel-keyed API currently targets.
    private static var activeStorageKey: String {
        activeAccount.withLock { $0 }.map(storageKey(forAccount:)) ?? legacyStorageKey
    }

    /// Point the channel-keyed API at `accountUserId`'s drafts, adopting any
    /// legacy (pre-scoping) drafts into that account first. AppShell calls
    /// this when an account's shell appears, before hydrating its tabs.
    ///
    /// Pending debounced saves don't need flushing first: each remembers the
    /// account it was typed under (see `pendingDrafts`).
    @MainActor
    public static func activate(accountUserId: String) {
        migrateLegacyDrafts(toAccount: accountUserId)
        setActiveAccount(accountUserId)
    }

    /// Scope switch without the legacy migration. Internal so tests can
    /// scope (and un-scope, with nil) without moving other tests' drafts.
    static func setActiveAccount(_ accountUserId: String?) {
        activeAccount.withLock { $0 = accountUserId }
    }

    /// One-shot upgrade step: move every legacy draft into
    /// `accountUserId`'s dictionary (its own existing drafts win on
    /// conflict) and delete the legacy key, so later accounts start empty.
    /// No-op once the legacy key is gone.
    static func migrateLegacyDrafts(toAccount accountUserId: String, defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: legacyStorageKey) != nil else { return }
        let legacy = defaults.dictionary(forKey: legacyStorageKey) as? [String: String] ?? [:]
        if !legacy.isEmpty {
            let key = storageKey(forAccount: accountUserId)
            var scoped = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
            scoped.merge(legacy) { current, _ in current }
            defaults.set(scoped, forKey: key)
            logger.notice("Adopted \(legacy.count) legacy draft(s) for account \(accountUserId, privacy: .public)")
        }
        defaults.removeObject(forKey: legacyStorageKey)
    }

    /// Drop every draft (stored and pending) belonging to `accountUserId`.
    /// Called when the account is removed (see `AccountLocalData.remove`).
    @MainActor
    public static func removeAll(forAccount accountUserId: String) {
        let key = storageKey(forAccount: accountUserId)
        pendingDrafts.withLock { _ = $0.removeValue(forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
    }

    // MARK: - Reads and immediate writes

    /// Returns the draft for a channel (preferring any unsaved debounced
    /// keystrokes in `pendingDrafts` over disk), or an empty string if none.
    /// Returning a String (not String?) keeps the call site simple — the
    /// compose bar always needs *something* to seed its state, and `""` is
    /// the correct "no draft" value visually.
    ///
    /// Falls back to the pre-composite bare-channelId key once, so
    /// drafts written before the keying change survive the upgrade
    /// (they're re-saved under the composite key on the next edit).
    public static func load(forChannel id: ChannelDescriptor.ID) -> String {
        let key = activeStorageKey
        if let pending = pendingDrafts.withLock({ $0[key]?[id] }) {
            return pending.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : pending
        }
        let dict = storedDrafts(key)
        if let draft = dict[id] { return draft }
        // Legacy fallback: keys written before the composite-ID change
        // were the bare channelId (the part after the "/").
        if let slash = id.firstIndex(of: "/") {
            let legacyKey = String(id[id.index(after: slash)...])
            return dict[legacyKey] ?? ""
        }
        return ""
    }

    /// Saves a draft for a channel immediately, clearing any pending
    /// debounced save for it so an older timer can never overwrite this write.
    /// Empty / whitespace-only texts are REMOVED from storage rather than
    /// persisted as empty strings — the dictionary stays tight and
    /// reload-after-empty correctly reads as "no draft" instead of "empty draft."
    ///
    /// Per-keystroke callers should use `scheduleSave` instead: every call
    /// here re-reads and rewrites the whole drafts dictionary.
    public static func save(forChannel id: ChannelDescriptor.ID, text: String) {
        let key = activeStorageKey
        pendingDrafts.withLock { _ = $0[key]?.removeValue(forKey: id) }
        var dict = storedDrafts(key)
        apply(text, forChannel: id, to: &dict)
        UserDefaults.standard.set(dict, forKey: key)
    }

    /// Clear a specific channel's draft, including any debounced save still
    /// pending for it (which would otherwise resurrect the draft when it
    /// fires). Used by `ChatTranscriptModel.send` after a send, so the next
    /// channel-mount doesn't restore a draft the user just sent.
    @MainActor
    public static func clear(forChannel id: ChannelDescriptor.ID) {
        let key = activeStorageKey
        pendingDrafts.withLock { _ = $0[key]?.removeValue(forKey: id) }
        var dict = storedDrafts(key)
        guard dict.removeValue(forKey: id) != nil else { return }
        UserDefaults.standard.set(dict, forKey: key)
    }

    // MARK: - Debounced saves

    /// How long typing must pause before pending drafts are written.
    static let saveDebounce: Duration = .milliseconds(400)

    /// Latest unsaved text per channel, grouped by the storage key (account)
    /// that was active when it was typed, written by the next flush.
    /// Lock-guarded so nonisolated `load` / `save` stay consistent with
    /// pending debounced edits without forcing main-actor hops.
    private static let pendingDrafts = OSAllocatedUnfairLock<[String: [ChannelDescriptor.ID: String]]>(initialState: [:])

    /// The debounce timer. One timer for all channels: a flush writes every
    /// pending channel in one read-modify-write per account dictionary.
    @MainActor private static var pendingFlush: Task<Void, Never>?

    /// Records `text` as the channel's draft and (re)starts the debounce
    /// timer. The compose bar calls this on every keystroke; storage is
    /// touched once typing pauses for `saveDebounce`, or on
    /// `flushPendingSaves()`.
    @MainActor
    public static func scheduleSave(forChannel id: ChannelDescriptor.ID, text: String) {
        let key = activeStorageKey
        pendingDrafts.withLock { $0[key, default: [:]][id] = text }
        pendingFlush?.cancel()
        pendingFlush = Task { @MainActor in
            try? await Task.sleep(for: saveDebounce)
            // A newer keystroke (or an explicit flush) cancelled this timer
            // and owns the write now.
            guard !Task.isCancelled else { return }
            flushPendingSaves()
        }
    }

    /// Writes every pending draft now and stops the debounce timer. Call when
    /// the compose bar goes away or the app leaves the foreground, so the
    /// last keystrokes aren't lost to the debounce window. No-op (and no
    /// UserDefaults write) when nothing is pending.
    @MainActor
    public static func flushPendingSaves() {
        pendingFlush?.cancel()
        pendingFlush = nil
        let batches = pendingDrafts.withLock { state -> [String: [ChannelDescriptor.ID: String]] in
            guard !state.isEmpty else { return [:] }
            let snapshot = state
            state.removeAll()
            return snapshot
        }
        guard !batches.isEmpty else { return }
        for (key, batch) in batches {
            let original = storedDrafts(key)
            var dict = original
            for (id, text) in batch {
                apply(text, forChannel: id, to: &dict)
            }
            guard dict != original else { continue }
            UserDefaults.standard.set(dict, forKey: key)
        }
    }

    /// Drops the active account's drafts (stored and pending) for channels
    /// the user no longer has open — called by `ChatTabsModel.close` for
    /// channels whose last tab just closed. Also drops each channel's
    /// pre-composite legacy key. One UserDefaults write at most, none if
    /// nothing was stored.
    @MainActor
    public static func remove(forChannels ids: [ChannelDescriptor.ID]) {
        guard !ids.isEmpty else { return }
        let key = activeStorageKey
        pendingDrafts.withLock { state in
            for id in ids {
                state[key]?.removeValue(forKey: id)
            }
        }
        let original = storedDrafts(key)
        var dict = original
        for id in ids {
            dict.removeValue(forKey: id)
            if let slash = id.firstIndex(of: "/") {
                dict.removeValue(forKey: String(id[id.index(after: slash)...]))
            }
        }
        guard dict != original else { return }
        UserDefaults.standard.set(dict, forKey: key)
    }

    // MARK: - Helpers

    private static func storedDrafts(_ key: String) -> [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    /// Applies one draft to `dict`: whitespace-only removes the entry,
    /// anything else stores the UNTRIMMED text so the user's
    /// leading/trailing whitespace (rare but possible — copy-paste from
    /// another app might include it) survives. Only the emptiness check
    /// uses the trim.
    private static func apply(_ text: String, forChannel id: ChannelDescriptor.ID, to dict: inout [String: String]) {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            dict.removeValue(forKey: id)
        } else {
            dict[id] = text
        }
    }
}
