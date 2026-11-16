import SwiftUI

/// SwiftUI environment plumbing for `FollowsStore`.
///
/// RootView owns the store (`@State`, so the follow list survives chat
/// push/pop) and injects it once; Home and the follow list read it.
///
/// Non-optional at the read site, precondition-backed: the storage is
/// optional only because `FollowsStore` is `@MainActor` and can't be built
/// in the key's nonisolated static context. Reading it without a RootView
/// (or `UIPreviewRoot`) ancestor is a wiring bug, so the accessor traps with
/// a message instead of making every reader `guard let` it.
private struct FollowsStoreKey: EnvironmentKey {
    static let defaultValue: FollowsStore? = nil
}

extension EnvironmentValues {
    /// The active account's followed-channel cache. Injected by `RootView`.
    var followsStore: FollowsStore {
        get {
            guard let store = self[FollowsStoreKey.self] else {
                preconditionFailure("\\.followsStore read outside RootView — inject it with .environment(\\.followsStore, …)")
            }
            return store
        }
        set { self[FollowsStoreKey.self] = newValue }
    }
}
