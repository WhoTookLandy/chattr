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
@MainActor
public final class TabPersistence {

    private let modelContainer: ModelContainer

    public init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    /// Fetch all persisted tabs in user-defined order. Called once on app
    /// launch (by AppShell's hydration `.task`) to seed `ChatTabsModel`.
    ///
    /// Order is the source of truth for left-to-right position in the
    /// strip — fetched sorted by `order` ascending, then by `addedAt` as a
    /// tie-break (defensive: if two rows somehow share the same `order`,
    /// the older one wins position).
    public func fetchAll() throws -> [PersistedChatTab] {
        let context = modelContainer.mainContext
        var descriptor = FetchDescriptor<PersistedChatTab>()
        descriptor.sortBy = [
            SortDescriptor(\.order, order: .forward),
            SortDescriptor(\.addedAt, order: .forward),
        ]
        return try context.fetch(descriptor)
    }

    /// Save the full in-memory tab list. Strategy: replace the entire
    /// persisted set on every write.
    ///
    /// ## Why replace-all instead of diff-based
    ///
    /// Tab edits are rare and tab counts are small (rarely > 5). The
    /// "diff in-memory state against on-disk state" code is complex and
    /// error-prone; a wholesale replace is O(N) but N is tiny. Trade-off
    /// favors correctness and simplicity.
    ///
    /// `order` is re-numbered to 0, 1, 2, … on every write to keep values
    /// contiguous and prevent gradual drift (e.g., after many inserts at
    /// position 0, you could end up with negative or huge ints otherwise).
    public func save(tabs: [ChatTab]) throws {
        let context = modelContainer.mainContext

        // Drop existing rows. Using mainContext + delete-all + insert-all
        // lets the @Query observers re-fire with the new snapshot.
        let existing = try context.fetch(FetchDescriptor<PersistedChatTab>())
        for row in existing {
            context.delete(row)
        }

        // Insert the current snapshot with contiguous order indices.
        for (index, tab) in tabs.enumerated() {
            let row = PersistedChatTab(from: tab, order: index)
            context.insert(row)
        }

        try context.save()
        logger.info("Saved \(tabs.count) tab(s) to SwiftData")
    }

    /// Clear all persisted tabs. Called from `forceSignOut` (in a future
    /// commit) so a re-signed-in user starts with a clean strip — their
    /// previous tabs may reference channels they no longer want to see.
    public func clearAll() throws {
        let context = modelContainer.mainContext
        let existing = try context.fetch(FetchDescriptor<PersistedChatTab>())
        for row in existing {
            context.delete(row)
        }
        try context.save()
        logger.info("Cleared all persisted tabs")
    }
}
