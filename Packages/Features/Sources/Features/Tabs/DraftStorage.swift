import Foundation
import Core

/// Per-channel chat draft persistence backed by UserDefaults.
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
///     `flushPendingSaves()` (compose bar disappearing) writes anything
///     still pending immediately.
///   - **Lifetime**: a channel's draft is pruned when its last tab closes
///     (`remove(forChannels:)`, called by `ChatTabsModel.close`), so the
///     dictionary doesn't accumulate drafts for channels the user left.
///
/// ## Storage shape
///
/// All drafts go into a single dictionary under one UserDefaults key,
/// keyed by `ChannelDescriptor.ID` — the composite "platform/channelId"
/// string — so same-numbered channels on different platforms can never
/// share a draft. Empty drafts are removed rather than stored as empty
/// strings — keeps the dictionary tight and means "no draft" reads as
/// nil consistently.
public enum DraftStorage {

    /// UserDefaults key for the drafts dictionary. Prefixed to avoid
    /// clashing with any future plist keys other modules might add.
    /// The name says "byChannelId" but entries are keyed by the
    /// composite `ChannelDescriptor.ID`; the key string is kept for
    /// continuity with existing installs (see the legacy fallback in
    /// `load`).
    private static let storageKey = "chattr.drafts.byChannelId"

    /// Returns the persisted draft for a channel, or an empty string
    /// if none. Returning a String (not String?) keeps the call site
    /// simple — the compose bar always needs *something* to seed its
    /// state, and `""` is the correct "no draft" value visually.
    ///
    /// Falls back to the pre-composite bare-channelId key once, so
    /// drafts written before the keying change survive the upgrade
    /// (they're re-saved under the composite key on the next edit).
    public static func load(forChannel id: ChannelDescriptor.ID) -> String {
        let dict = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String] ?? [:]
        if let draft = dict[id] { return draft }
        // Legacy fallback: keys written before the composite-ID change
        // were the bare channelId (the part after the "/").
        if let slash = id.firstIndex(of: "/") {
            let legacyKey = String(id[id.index(after: slash)...])
            return dict[legacyKey] ?? ""
        }
        return ""
    }

    /// Saves a draft for a channel immediately. Empty / whitespace-only
    /// texts are REMOVED from storage rather than persisted as empty
    /// strings — the dictionary stays tight and reload-after-empty
    /// correctly reads as "no draft" instead of "empty draft."
    ///
    /// Per-keystroke callers should use `scheduleSave` instead: every call
    /// here re-reads and rewrites the whole drafts dictionary.
    public static func save(forChannel id: ChannelDescriptor.ID, text: String) {
        var dict = storedDrafts()
        apply(text, forChannel: id, to: &dict)
        UserDefaults.standard.set(dict, forKey: storageKey)
    }

    /// Clear a specific channel's draft, including any debounced save still
    /// pending for it (which would otherwise resurrect the draft when it
    /// fires). Used by `ChatTranscriptModel.send` after a send, so the next
    /// channel-mount doesn't restore a draft the user just sent.
    @MainActor
    public static func clear(forChannel id: ChannelDescriptor.ID) {
        pendingDrafts.removeValue(forKey: id)
        var dict = storedDrafts()
        guard dict.removeValue(forKey: id) != nil else { return }
        UserDefaults.standard.set(dict, forKey: storageKey)
    }

    // MARK: - Debounced saves

    /// How long typing must pause before pending drafts are written.
    static let saveDebounce: Duration = .milliseconds(400)

    /// Latest unsaved text per channel, written by the next flush.
    @MainActor private static var pendingDrafts: [ChannelDescriptor.ID: String] = [:]

    /// The debounce timer. One timer for all channels: a flush writes every
    /// pending channel in a single read-modify-write.
    @MainActor private static var pendingFlush: Task<Void, Never>?

    /// Records `text` as the channel's draft and (re)starts the debounce
    /// timer. The compose bar calls this on every keystroke; storage is
    /// touched once typing pauses for `saveDebounce`, or on
    /// `flushPendingSaves()`.
    @MainActor
    public static func scheduleSave(forChannel id: ChannelDescriptor.ID, text: String) {
        pendingDrafts[id] = text
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
    /// the compose bar goes away so the last keystrokes aren't lost to the
    /// debounce window. No-op (and no UserDefaults write) when nothing is
    /// pending.
    @MainActor
    public static func flushPendingSaves() {
        pendingFlush?.cancel()
        pendingFlush = nil
        guard !pendingDrafts.isEmpty else { return }
        let batch = pendingDrafts
        pendingDrafts.removeAll()
        let original = storedDrafts()
        var dict = original
        for (id, text) in batch {
            apply(text, forChannel: id, to: &dict)
        }
        guard dict != original else { return }
        UserDefaults.standard.set(dict, forKey: storageKey)
    }

    /// Drops the drafts (stored and pending) for channels the user no longer
    /// has open — called by `ChatTabsModel.close` for channels whose last tab
    /// just closed. Also drops each channel's pre-composite legacy key. One
    /// UserDefaults write at most, none if nothing was stored.
    @MainActor
    public static func remove(forChannels ids: [ChannelDescriptor.ID]) {
        guard !ids.isEmpty else { return }
        let original = storedDrafts()
        var dict = original
        for id in ids {
            pendingDrafts.removeValue(forKey: id)
            dict.removeValue(forKey: id)
            if let slash = id.firstIndex(of: "/") {
                dict.removeValue(forKey: String(id[id.index(after: slash)...]))
            }
        }
        guard dict != original else { return }
        UserDefaults.standard.set(dict, forKey: storageKey)
    }

    // MARK: - Helpers

    private static func storedDrafts() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String] ?? [:]
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
