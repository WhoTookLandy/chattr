//
//  chattrApp.swift
//  chattr
//

import Accounts
import Channels
import DesignSystem
import Features
import OSLog
import SwiftData
import SwiftUI
import TwitchKit

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

    /// Outcome of standing up the SwiftData stack at launch. Held as state
    /// (rather than three non-optional `let`s) so a container-init failure —
    /// e.g. a corrupted store after an interrupted update or a botched
    /// migration — shows a recovery screen instead of `fatalError`-crashing
    /// on every launch, which would permanently brick the install. See
    /// `StoreRecoveryView`.
    @State private var state: AppInitState

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "chattr",
        category: "AppInit"
    )

    init() {
        // Configure Nuke's shared image pipeline once, before any view (and
        // thus any LazyImage for badges/emotes/avatars) materializes. This is
        // one-time app setup, so the app entry point — not a view body — is the
        // correct home for it. Previously called from RootView.body, where it
        // re-ran (guarded, but wastefully) on every re-evaluation.
        ImagePipelineSetup.configure()
        _state = State(initialValue: Self.makeState())
    }

    /// Builds the SwiftData container and the stores that depend on it, or
    /// captures the failure for the recovery UI. Static so it can run from
    /// `init` and be re-run after a reset without touching `self`.
    private static func makeState() -> AppInitState {
        do {
            // PersistedChatTab is the SwiftData projection of ChatTab — added
            // in commit E so chat tabs survive cold start. Lives in the
            // Features package alongside the runtime ChatTab struct it
            // mirrors.
            //
            // Built against an explicit VersionedSchema + SchemaMigrationPlan
            // (see AppSchema.swift) rather than the bare model list, so future
            // schema changes can ship as MigrationStages instead of crashing
            // existing users at launch. V1 is structurally identical to the
            // old bare schema, so current installs open without migrating.
            let schema = Schema(versionedSchema: AppSchemaV1.self)
            let container = try ModelContainer(
                for: schema,
                migrationPlan: AppMigrationPlan.self
            )
            let store = AccountStore(modelContainer: container, clientId: clientId)
            let registry = ChannelSessionRegistry(accountStore: store)
            return .ready(container: container, accountStore: store, registry: registry)
        } catch {
            logger.error("SwiftData container init failed: \(String(describing: error), privacy: .public)")
            return .failed(error)
        }
    }

    /// Best-effort deletion of the default SwiftData store (and its WAL
    /// sidecars) so the next `makeState()` can recreate it from scratch.
    /// Clears chattr's locally stored chat tabs, channel cache, and the
    /// local account roster (Keychain-held OAuth tokens are untouched, but
    /// the user may need to re-select/sign in to an account).
    private static func resetStore() {
        let base = URL.applicationSupportDirectory
        for name in ["default.store", "default.store-shm", "default.store-wal"] {
            try? FileManager.default.removeItem(at: base.appending(path: name))
        }
    }

    /// Observed by `@AppStorage`; SettingsScreen writes through the same key
    /// so changes propagate without manual notification plumbing.
    @AppStorage(AppearanceMode.storageKey) private var appearanceModeRaw: String = AppearanceMode.system.rawValue

    var body: some Scene {
        WindowGroup {
            content
                // nil = follow system (the default). SwiftUI's preferredColorScheme
                // recurses through child environments, so all sheets/navs honor it.
                .preferredColorScheme(
                    (AppearanceMode(rawValue: appearanceModeRaw) ?? .system).preferredColorScheme
                )
        }
    }

    @ViewBuilder private var content: some View {
        #if DEBUG
        // Design-review harness: `-uiPreview` boots the tab shell
        // with mock data, no sign-in. See `UIPreviewRoot`.
        if ProcessInfo.processInfo.arguments.contains("-uiPreview") {
            UIPreviewRoot()
        } else {
            mainContent
        }
        #else
        mainContent
        #endif
    }

    @ViewBuilder private var mainContent: some View {
        switch state {
        case let .ready(container, accountStore, registry):
            RootView(
                accountStore: accountStore,
                clientId: Self.clientId,
                channelSessionRegistry: registry
            )
            .modelContainer(container)
        case let .failed(error):
            StoreRecoveryView(error: error) {
                Self.resetStore()
                state = Self.makeState()
            }
        }
    }

    /// Whether the SwiftData stack came up, or the error to recover from.
    /// App-wide registry of live `ChannelSession`s is carried in `.ready`:
    /// it's owned by the app (not by any view) so chat sessions survive
    /// view-tree churn — re-entering a channel returns the existing session
    /// rather than creating a new one that would try (and fail) to
    /// re-subscribe to the same EventSub topic.
    private enum AppInitState {
        case ready(container: ModelContainer, accountStore: AccountStore, registry: ChannelSessionRegistry)
        case failed(any Error)
    }
}

/// Shown when the SwiftData container can't be opened at launch. Offers a
/// destructive, recoverable reset instead of letting the app `fatalError`
/// on every launch — a crash loop the user can only escape by deleting the
/// app. The `error` is retained for logging/diagnostics (already logged in
/// `makeState`), not surfaced verbatim to avoid leaking internal detail.
private struct StoreRecoveryView: View {
    let error: any Error
    let onReset: () -> Void

    @State private var didReset = false

    var body: some View {
        ContentUnavailableView {
            Label("Couldn’t Open Your Data", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            Text("chattr couldn’t load its local data. This can happen after an interrupted update. Resetting clears chattr’s locally stored chat tabs and channel cache — you may need to sign in again.")
        } actions: {
            Button(role: .destructive) {
                didReset = true
                onReset()
            } label: {
                Text("Reset Local Data")
            }
            .buttonStyle(.borderedProminent)
            .disabled(didReset)
        }
    }
}
