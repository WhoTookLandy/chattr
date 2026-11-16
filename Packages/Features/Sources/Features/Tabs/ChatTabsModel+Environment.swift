import SwiftUI

/// SwiftUI environment plumbing for `ChatTabsModel`.
///
/// AppShell owns the signed-in account's model (via `AppNavigation`) and
/// injects it once; Home and the Chats tab read it.
///
/// Non-optional at the read site, precondition-backed: the storage is
/// optional only because `ChatTabsModel` is `@MainActor` and can't be built
/// in the key's nonisolated static context. Reading it without an AppShell
/// (or `UIPreviewRoot`) ancestor is a wiring bug, so the accessor traps with
/// a message instead of making every reader unwrap it.
private struct ChatTabsModelKey: EnvironmentKey {
    static let defaultValue: ChatTabsModel? = nil
}

extension EnvironmentValues {
    /// UI state for the Chat tab's open channels. Injected by `AppShell`.
    var chatTabs: ChatTabsModel {
        get {
            guard let model = self[ChatTabsModelKey.self] else {
                preconditionFailure("\\.chatTabs read outside AppShell — inject it with .environment(\\.chatTabs, …)")
            }
            return model
        }
        set { self[ChatTabsModelKey.self] = newValue }
    }
}
