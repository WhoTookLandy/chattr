//
//  chattrApp.swift
//  chattr
//

import Accounts
import Channels
import Core
import DesignSystem
import Features
import SwiftData
import SwiftUI
import os

private let logger = AppLogger.make("App.Bootstrap")

@main
struct chattrApp: App {
    // ────────────────────────────────────────────────────────────────────────
    // ⚠️ REPLACE `TWITCH_CLIENT_ID_HERE` with the Client ID from dev.twitch.tv
    // for the chattr application Andrew registered. Note: this is the public
    // client ID, not the client secret — that's fine to commit. For Twitch's
    // authorization-code flow with a mobile/installed app, the client secret
    // is NOT required when using PKCE. (TwitchKit's TwitchOAuthClient handles
    // the flow.)
    // ────────────────────────────────────────────────────────────────────────
    static let clientId = "b3lzm4vxuqw81u2gb478deff8o3tmh"

    let modelContainer: ModelContainer
    let accountStore: AccountStore
    /// App-wide registry of live `ChannelSession`s. Owned by the app (not by
    /// any view) so chat sessions survive view-tree churn — re-entering a
    /// channel returns the existing session rather than creating a new one
    /// that would try (and fail) to re-subscribe to the same EventSub topic.
    let channelSessionRegistry: ChannelSessionRegistry

    init() {
        // Configure Nuke's shared image pipeline once, before any view (and
        // thus any LazyImage for badges/emotes/avatars) materializes. This is
        // one-time app setup, so the app entry point — not a view body — is the
        // correct home for it. Previously called from RootView.body, where it
        // re-ran (guarded, but wastefully) on every re-evaluation.
        ImagePipelineSetup.configure()
        // PersistedChatTab is the SwiftData projection of ChatTab — added
        // in commit E so chat tabs survive cold start. Lives in the
        // Features package alongside the runtime ChatTab struct it
        // mirrors.
        //
        // Built against an explicit VersionedSchema + SchemaMigrationPlan
        // (see AppSchema.swift) rather than the bare model list, so future
        // schema changes can ship as MigrationStages instead of crashing
        // existing users at launch. V1 is structurally identical to the
        // old bare schema; V1 stores migrate to the latest version via
        // `AppMigrationPlan`'s stages.
        let schema = Schema(versionedSchema: AppSchemaLatest.self)
        let container = Self.makeModelContainer(schema: schema)
        self.modelContainer = container
        let store = AccountStore(modelContainer: container, clientId: Self.clientId)
        // Removing an account also drops what Features persists for it
        // (tabs, drafts, block cache). Wired here because Accounts can't
        // import Features.
        store.onAccountRemoved = { userId in
            AccountLocalData.remove(forAccountUserId: userId, modelContainer: container)
        }
        self.accountStore = store
        self.channelSessionRegistry = ChannelSessionRegistry(accountStore: store)
    }

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
    private static func makeModelContainer(schema: Schema) -> ModelContainer {
        for attempt in 1...2 {
            do {
                return try ModelContainer(for: schema, migrationPlan: AppMigrationPlan.self)
            } catch {
                logger.fault("Failed to open SwiftData store (attempt \(attempt)): \(String(describing: error), privacy: .public)")
            }
        }

        // A default `ModelConfiguration` resolves to the same store URL the
        // configuration-less initializer above uses.
        let backedUp = moveStoreFilesAside(at: ModelConfiguration().url)

        do {
            let container = try ModelContainer(for: schema, migrationPlan: AppMigrationPlan.self)
            logger.notice("Opened a fresh SwiftData store after open failure (previous store \(backedUp ? "backed up" : "not backed up", privacy: .public))")
            return container
        } catch {
            logger.fault("Fresh SwiftData store failed to open: \(String(describing: error), privacy: .public). Falling back to an in-memory store for this launch.")
        }

        do {
            return try ModelContainer(
                for: schema,
                migrationPlan: AppMigrationPlan.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
        } catch {
            fatalError("Failed to initialize SwiftData, even in memory: \(error)")
        }
    }

    /// Moves a SQLite-backed store and its WAL/SHM sidecars into
    /// `<store dir>/StoreBackups/<timestamp>/`, so a fresh store can be
    /// created without destroying the old data. Missing files are fine.
    /// Returns true when every existing file was moved; on a move failure the
    /// remaining files are left in place and the caller's fresh open proceeds
    /// anyway (and will fail again if the store is still unusable).
    private static func moveStoreFilesAside(at storeURL: URL) -> Bool {
        let fileManager = FileManager.default
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backupDir = storeURL.deletingLastPathComponent()
            .appendingPathComponent("StoreBackups", isDirectory: true)
            .appendingPathComponent(stamp, isDirectory: true)
        let paths = [storeURL.path, storeURL.path + "-shm", storeURL.path + "-wal"]
        var allMoved = true
        do {
            try fileManager.createDirectory(at: backupDir, withIntermediateDirectories: true)
        } catch {
            logger.error("Couldn't create store backup folder: \(error.localizedDescription, privacy: .public)")
            return false
        }
        for path in paths where fileManager.fileExists(atPath: path) {
            let destination = backupDir.appendingPathComponent((path as NSString).lastPathComponent)
            do {
                try fileManager.moveItem(atPath: path, toPath: destination.path)
                logger.notice("Moved store file \(path, privacy: .public) to \(destination.path, privacy: .public)")
            } catch {
                allMoved = false
                logger.error("Couldn't move store file \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return allMoved
    }

    /// Observed by `@AppStorage`; SettingsScreen writes through the same key
    /// so changes propagate without manual notification plumbing.
    @AppStorage(AppearanceMode.storageKey) private var appearanceModeRaw: String = AppearanceMode.system.rawValue

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                // Design-review harness: `-uiPreview` boots the tab shell
                // with mock data, no sign-in. See `UIPreviewRoot`.
                if ProcessInfo.processInfo.arguments.contains("-uiPreview") {
                    UIPreviewRoot()
                } else {
                    rootView
                }
                #else
                rootView
                #endif
            }
            // nil = follow system (the default). SwiftUI's preferredColorScheme
            // recurses through child environments, so all sheets/navs honor it.
            .preferredColorScheme(
                (AppearanceMode(rawValue: appearanceModeRaw) ?? .system).preferredColorScheme
            )
        }
    }

    private var rootView: some View {
        RootView(
            accountStore: accountStore,
            clientId: Self.clientId,
            channelSessionRegistry: channelSessionRegistry
        )
        .modelContainer(modelContainer)
    }
}
