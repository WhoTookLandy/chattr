import AuthenticationServices
import Accounts
#if canImport(UIKit)
import UIKit
#endif

/// UI glue for the UI-free `TwitchSignIn` flow in `Accounts`: resolves the
/// window the OAuth sheet presents from. Lives in `Features` so the
/// `Accounts` domain package stays free of UIKit.
extension TwitchSignIn {

    /// Runs the shared sign-in flow with the store's Twitch client id,
    /// presenting from the app's foreground window. Used by `SignInView`
    /// and the account switcher.
    @MainActor
    @discardableResult
    static func run(accountStore: AccountStore) async throws -> Account {
        try await run(
            accountStore: accountStore,
            clientId: accountStore.clientId,
            presentationAnchor: foregroundWindow
        )
    }

    /// The key window of the foreground-active window scene, falling back to
    /// the first connected window scene (e.g. during a scene transition).
    @MainActor
    static func foregroundWindow() -> ASPresentationAnchor? {
        #if canImport(UIKit)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        return scene?.keyWindow ?? scene?.windows.first
        #else
        return nil
        #endif
    }
}
