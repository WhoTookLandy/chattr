import Foundation
import SwiftData
import Core
import os

private let logger = AppLogger.make("Features.TabPersistence")

/// Thin SwiftData wrapper for `PersistedChatTab` rows. Owns "how do tabs
/// hit disk" so `ChatTabsModel` stays SwiftData-agnostic.
///
/// ## Why a helper class, not direct ModelContext calls in ChatTabsModel
///
/// ChatTabsModel is the *UI state* type — it should stay focused on
/// "which tabs are open, which is active." Threading SwiftData
/// `ModelContext` calls through it would couple the in-memory model to a
/// persistence framework, making it harder to test and harder to swap
/// the storage layer later (e.g., to a key-value store if we ever ship
/// a simpler "no SwiftData" build).
///
/// Instead `ChatTabsModel` calls into `TabPersistence?` via an optional
/// reference. Tests that don't care about persistence leave it `nil`;
/// the production wiring in AppShell hands in a real instance.
///
/// ## Isolation
///
/// `@MainActor` because SwiftData's main `ModelContext` is `@MainActor`-
/// bound (the same reasoning as `AccountStore`). Operations are
/// lightweight (a handful of model objects per call), so this doesn't
/// block the thread meaningfully.
///
/// ## Account scoping
///
/// Each instance is bound to one account (`accountUserId`) and only ever
/// reads or writes that account's rows — AppShell builds one per signed-in
/// account, so account B never restores (or overwrites) account A's tabs.
@MainActor
public final class TabPersistence {

    private let modelContainer: ModelContainer

    /// `Account.userId` whose rows this instance reads and writes.
    public let accountUserId: String

    public init(modelContainer: ModelContainer, accountUserId: String) {
        self.modelContainer = modelContainer
        self.accountUserId = accountUserId
    }

    /// Fetch this account's persisted tabs in user-defined order. Called
    /// once per account appearance (by AppShell's hydration `.task`) to seed
    /// `ChatTabsModel`.
    ///
    /// Order is the source of truth for left-to-right position in the
    /// strip — fetched sorted by `order` ascending, then by `addedAt` as a
    /// tie-break (defensive: if two rows somehow share the same `order`,
    /// the older one wins position).
    ///
    /// ## Legacy rows (pre-`AppSchemaV2`)
    ///
    /// Rows written before tabs were account-scoped migrate with an empty
    /// `accountUserId`. They are *adopted* by the first account that
    /// hydrates after the upgrade — stamped with its id and saved — rather
    /// than dropped: the pre-upgrade strip almost always belonged to the
    /// account that was active at upgrade time, which is the one that
    /// launches first. After adoption no legacy rows remain, so later
    /// accounts start from their own (initially empty) strip.
    public func fetchAll() throws -> [PersistedChatTab] {
        let context = modelContainer.mainContext
        // Locals, not `self.` reads: `#Predicate` can only capture values.
        let owner = accountUserId
        let legacyOwner = ""
        let descriptor = FetchDescriptor<PersistedChatTab>(
            predicate: #Predicate<PersistedChatTab> { row in
                row.accountUserId == owner || row.accountUserId == legacyOwner
            },
            sortBy: [
                SortDescriptor(\.order, order: .forward),
                SortDescriptor(\.addedAt, order: .forward),
            ]
        )
        let rows = try context.fetch(descriptor)

        if !owner.isEmpty {
            let legacyRows = rows.filter { $0.accountUserId.isEmpty }
            for row in legacyRows {
                row.accountUserId = owner
            }
            if !legacyRows.isEmpty {
                let adopted = legacyRows.count
                do {
                    try context.save()
                    logger.notice("Adopted \(adopted) legacy tab row(s) for account \(owner, privacy: .public)")
                } catch {
                    // Non-fatal: the rows are already stamped in the context,
                    // so the next successful `save(tabs:)` persists the
                    // adoption. Hydration proceeds with them either way.
                    logger.error("Saving adopted legacy tab rows failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        return rows
    }

    /// Save this account's full in-memory tab list.
    ///
    /// Strategy: upsert against the account's existing rows in one context
    /// save — update `order` / `channels` on rows that are still open, insert
    /// new tabs, delete rows that are no longer in the strip (closed tabs and
    /// any corrupt rows `toChatTab()` dropped at hydrate). Rows owned by
    /// other accounts are never touched. Unchanged rows aren't dirtied, and
    /// when nothing changed at all the save is skipped entirely.
    ///
    /// Tab counts are small (rarely > 5), so the per-call fetch is cheap;
    /// what matters is not churning delete+insert for every row on every
    /// reorder or close.
    ///
    /// `order` is re-numbered to 0, 1, 2, … on every write to keep values
    /// contiguous and prevent gradual drift (e.g., after many inserts at
    /// position 0, you could end up with negative or huge ints otherwise).
    public func save(tabs: [ChatTab]) throws {
        let context = modelContainer.mainContext
        let owner = accountUserId
        let existing = try context.fetch(FetchDescriptor<PersistedChatTab>(
            predicate: #Predicate<PersistedChatTab> { row in
                row.accountUserId == owner
            }
        ))
        // `id` is `.unique`, so duplicates can't exist; the uniquing closure
        // is only there so a corrupt store can't trap here.
        let rowsById = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let openIds = Set(tabs.map(\.id))

        for row in existing where !openIds.contains(row.id) {
            context.delete(row)
        }
        for (index, tab) in tabs.enumerated() {
            if let row = rowsById[tab.id] {
                if row.order != index { row.order = index }
                if row.channels != tab.channels { row.channels = tab.channels }
            } else {
                context.insert(PersistedChatTab(from: tab, order: index, accountUserId: owner))
            }
        }

        guard context.hasChanges else { return }
        try context.save()
        logger.info("Saved \(tabs.count) tab(s) to SwiftData")
    }

    /// Delete every row this account owns. Called when the account itself
    /// is removed (see `AccountLocalData.remove`) so its strip doesn't
    /// linger on disk. Legacy unowned rows (`accountUserId == ""`) are left
    /// for the next account to adopt. No save when there's nothing to delete.
    public func deleteAll() throws {
        let context = modelContainer.mainContext
        let owner = accountUserId
        let rows = try context.fetch(FetchDescriptor<PersistedChatTab>(
            predicate: #Predicate<PersistedChatTab> { row in
                row.accountUserId == owner
            }
        ))
        guard !rows.isEmpty else { return }
        for row in rows {
            context.delete(row)
        }
        try context.save()
        logger.notice("Deleted \(rows.count) tab row(s) for removed account \(owner, privacy: .public)")
    }
}
