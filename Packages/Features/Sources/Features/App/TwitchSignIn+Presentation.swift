import AuthenticationServices
import Accounts
import Core
#if canImport(UIKit)
import UIKit
#endif

/// UI glue for the UI-free `TwitchSignIn` flow in `Accounts`: resolves the
/// window the OAuth sheet presents from. Lives in `Features` so the
/// `Accounts` domain package stays free of UIKit.
extension TwitchSignIn {

    /// Runs the shared sign-in flow. Used by `SignInView` and the account
    /// switcher (first sign-in, add account, re-authorize).
    ///
    /// Primary path: the Device Code Grant sheet (`DeviceCodeSignInSheet`) —
    /// approve on Twitch, ideally in the Twitch app where the user is
    /// already signed in. "Use browser instead", a client Twitch won't run
    /// the device flow for, or a sheet UIKit couldn't present falls back to
    /// the `ASWebAuthenticationSession` flow. Cancelling the calling task
    /// closes the sheet and stops polling.
    @MainActor
    @discardableResult
    static func run(accountStore: AccountStore, clientId: String) async throws -> Account {
        #if canImport(UIKit)
        switch await DeviceCodeSheetSession.present(accountStore: accountStore, clientId: clientId) {
        case .signedIn(let account)?:
            return account
        case .cancelled?:
            throw AppError(message: "Sign in cancelled")
        case .useBrowser?, nil:
            break
        }
        #endif
        try Task.checkCancellation()
        return try await runInBrowser(accountStore: accountStore, clientId: clientId)
    }

    /// The `ASWebAuthenticationSession` flow, presenting from the app's
    /// foreground window.
    @MainActor
    @discardableResult
    static func runInBrowser(accountStore: AccountStore, clientId: String) async throws -> Account {
        try await run(
            accountStore: accountStore,
            clientId: clientId,
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
