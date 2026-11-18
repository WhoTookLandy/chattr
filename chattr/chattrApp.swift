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

@main
struct chattrApp: App {
    /// The public Client ID of chattr's registered Twitch application (not
    /// a secret, so it is fine to commit). The client secret never ships:
    /// sign-in uses the Device Code Grant, and the browser flow's code
    /// exchange and every token refresh go through the chattr-auth bridge,
    /// which holds the secret. To build against your own Twitch app,
    /// replace this value.
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
        // The versioned schema, its migration plan and the recovery from a
        // store that won't open all live in Features (`AppModelContainer`,
        // `AppSchema.swift`), where tests can reach them.
        let (container, openedExistingStore) = AppModelContainer.open()
        self.modelContainer = container
        let store = AccountStore(modelContainer: container, clientId: Self.clientId)
        // Removing an account also drops what Features persists for it
        // (tabs, drafts, block cache). Wired here because Accounts can't
        // import Features.
        store.onAccountRemoved = { userId in
            AccountLocalData.remove(forAccountUserId: userId, modelContainer: container)
        }
        self.accountStore = store
        let registry = ChannelSessionRegistry(accountStore: store)
        self.channelSessionRegistry = registry
        // Re-authorizing an account swaps its TwitchClient; open sessions
        // still hold the old one. Wired here because Accounts can't import
        // Channels. Weak: the store would otherwise retain the registry,
        // which retains the store.
        store.onClientReplaced = { [weak registry] userId in
            guard let registry else { return }
            Task { await registry.clientReplaced(forAccountUserId: userId) }
        }
        // Keychain items outlive an uninstall; the account rows don't. Only
        // when the store on disk opened normally: after a fallback there are
        // no rows, and every signed-in account would look orphaned.
        if openedExistingStore {
            Task { await store.sweepOrphanedCredentials() }
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
