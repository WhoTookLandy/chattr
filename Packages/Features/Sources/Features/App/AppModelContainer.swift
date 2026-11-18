import Foundation
import SwiftData
import Core
import os

private let logger = AppLogger.make("App.Bootstrap")

/// Opens the app's SwiftData store for the composition root (`chattrApp`),
/// recovering from a store that won't open.
///
/// Built against an explicit VersionedSchema + SchemaMigrationPlan
/// (see AppSchema.swift) rather than the bare model list, so future
/// schema changes can ship as MigrationStages instead of crashing
/// existing users at launch. V1 is structurally identical to the
/// old bare schema; V1 stores migrate to the latest version via
/// `AppMigrationPlan`'s stages.
public enum AppModelContainer {

    /// Opens the on-disk SwiftData store, escalating only as far as needed:
    ///
    /// 1. Open it normally.
    /// 2. On failure, retry once — a transient failure (file briefly locked,
    ///    I/O hiccup) shouldn't cost the user anything.
    /// 3. Still failing (a corrupt store, or a schema change the migration
    ///    plan can't express): MOVE the store files aside into a backup
    ///    folder — never delete them — and open a fresh store. The old data
    ///    stays on disk for diagnosis or manual recovery instead of being
    ///    destroyed by what may have been a recoverable error.
    /// 4. If even a fresh on-disk store won't open, run this launch on an
    ///    in-memory store rather than crashing on every launch.
    ///
    /// Losing the local store is survivable — it holds account rows and
    /// persisted tabs; OAuth tokens live in the Keychain, and the user can
    /// sign in again — whereas failing here is a crash on every launch.
    ///
    /// `openedExisting` is true only for steps 1–2: the container holds
    /// whatever account rows were on disk, not a fresh or in-memory store.
    public static func open() -> (container: ModelContainer, openedExisting: Bool) {
        open(storeURL: nil)
    }

    /// `open()` against a given store file. `nil` is the app's own store,
    /// at SwiftData's default location; tests pass a file in a temporary
    /// directory.
    static func open(storeURL: URL?) -> (container: ModelContainer, openedExisting: Bool) {
        let schema = Schema(versionedSchema: AppSchemaLatest.self)
        for attempt in 1...2 {
            do {
                return (try makeContainer(schema: schema, storeURL: storeURL), true)
            } catch {
                logger.fault("Failed to open SwiftData store (attempt \(attempt)): \(String(describing: error), privacy: .public)")
            }
        }

        // A default `ModelConfiguration` resolves to the same store URL the
        // configuration-less initializer above uses.
        // Only reuse the disk location when the WHOLE store (database + WAL +
        // SHM) moved together. A partial move would split the database from
        // its WAL — SQLite can lose committed transactions that way — so the
        // move is rolled back and this launch runs in memory instead.
        if moveStoreFilesAside(at: storeURL ?? ModelConfiguration().url) {
            do {
                let container = try makeContainer(schema: schema, storeURL: storeURL)
                logger.notice("Opened a fresh SwiftData store after open failure (previous store backed up)")
                return (container, false)
            } catch {
                logger.fault("Fresh SwiftData store failed to open: \(String(describing: error), privacy: .public). Falling back to an in-memory store for this launch.")
            }
        } else {
            logger.fault("Couldn't back up the SwiftData store intact; leaving it in place and using an in-memory store for this launch.")
        }

        do {
            let container = try ModelContainer(
                for: schema,
                migrationPlan: AppMigrationPlan.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
            return (container, false)
        } catch {
            fatalError("Failed to initialize SwiftData, even in memory: \(error)")
        }
    }

    /// The on-disk container. With no `storeURL` this is the
    /// configuration-less initializer every build of the app has opened its
    /// store with; the store's location must never change, or existing
    /// installs would start from an empty store.
    private static func makeContainer(schema: Schema, storeURL: URL?) throws -> ModelContainer {
        guard let storeURL else {
            return try ModelContainer(for: schema, migrationPlan: AppMigrationPlan.self)
        }
        return try ModelContainer(
            for: schema,
            migrationPlan: AppMigrationPlan.self,
            configurations: ModelConfiguration(url: storeURL)
        )
    }

    /// Moves a SQLite-backed store and its WAL/SHM sidecars into
    /// `<store dir>/StoreBackups/<timestamp>/`, so a fresh store can be
    /// created without destroying the old data. Missing files are fine.
    /// All-or-nothing: returns true only when every existing file was moved.
    /// If any move fails, the files already moved are put back, so the
    /// database is never separated from its WAL, and false is returned.
    static func moveStoreFilesAside(at storeURL: URL) -> Bool {
        let fileManager = FileManager.default
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backupDir = storeURL.deletingLastPathComponent()
            .appendingPathComponent("StoreBackups", isDirectory: true)
            .appendingPathComponent(stamp, isDirectory: true)
        let paths = [storeURL.path, storeURL.path + "-shm", storeURL.path + "-wal"]
        do {
            try fileManager.createDirectory(at: backupDir, withIntermediateDirectories: true)
        } catch {
            logger.error("Couldn't create store backup folder: \(error.localizedDescription, privacy: .public)")
            return false
        }
        var moved: [(from: String, to: String)] = []
        for path in paths where fileManager.fileExists(atPath: path) {
            let destination = backupDir.appendingPathComponent((path as NSString).lastPathComponent).path
            do {
                try fileManager.moveItem(atPath: path, toPath: destination)
                moved.append((from: path, to: destination))
                logger.notice("Moved store file \(path, privacy: .public) to \(destination, privacy: .public)")
            } catch {
                logger.error("Couldn't move store file \(path, privacy: .public): \(error.localizedDescription, privacy: .public). Restoring the files already moved.")
                for item in moved.reversed() {
                    do {
                        try fileManager.moveItem(atPath: item.to, toPath: item.from)
                    } catch {
                        logger.fault("Couldn't restore store file \(item.from, privacy: .public) from \(item.to, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                }
                return false
            }
        }
        return true
    }
}
