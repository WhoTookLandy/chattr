import SwiftUI
import Accounts

/// SwiftUI environment plumbing for `AccountStore`.
///
/// Injected once by `RootView` (and `UIPreviewRoot`), so screens read it
/// from the environment instead of threading it through every init.
///
/// Non-optional at the read site: the key's storage is optional only
/// because `AccountStore` is `@MainActor` and needs a `ModelContainer`, so
/// no default instance can exist in the key's nonisolated static context.
/// Reading it outside a RootView ancestor is a wiring bug, and the accessor
/// traps with a message that names the missing injection instead of letting
/// every caller carry a `guard let`.
private struct AccountStoreKey: EnvironmentKey {
    static let defaultValue: AccountStore? = nil
}

extension EnvironmentValues {
    /// The app's account registry. Always injected by `RootView`.
    var accountStore: AccountStore {
        get {
            guard let store = self[AccountStoreKey.self] else {
                preconditionFailure("\\.accountStore read outside RootView — inject it with .environment(\\.accountStore, …)")
            }
            return store
        }
        set { self[AccountStoreKey.self] = newValue }
    }
}
