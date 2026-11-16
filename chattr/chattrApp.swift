//
//  chattrApp.swift
//  chattr
//

import Accounts
import Channels
import DesignSystem
import Features
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
            // old bare schema; V1 stores migrate to the latest version via
            // `AppMigrationPlan`'s stages.
            let schema = Schema(versionedSchema: AppSchemaLatest.self)
            let container = try ModelContainer(
                for: schema,
                migrationPlan: AppMigrationPlan.self
            )
            self.modelContainer = container
            let store = AccountStore(modelContainer: container, clientId: Self.clientId)
            self.accountStore = store
            self.channelSessionRegistry = ChannelSessionRegistry(accountStore: store)
        } catch {
            fatalError("Failed to initialize SwiftData: \(error)")
        }
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
