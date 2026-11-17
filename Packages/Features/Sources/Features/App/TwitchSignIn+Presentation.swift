import AuthenticationServices
import Accounts
import Core
#if canImport(UIKit)
import SwiftUI
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
    /// already signed in. "Use browser instead" (or no window to present
    /// from) falls back to the `ASWebAuthenticationSession` flow.
    @MainActor
    @discardableResult
    static func run(accountStore: AccountStore, clientId: String) async throws -> Account {
        #if canImport(UIKit)
        switch await presentDeviceCodeSheet(accountStore: accountStore, clientId: clientId) {
        case .signedIn(let account)?:
            return account
        case .cancelled?:
            throw AppError(message: "Sign in cancelled")
        case .useBrowser?, nil:
            break
        }
        #endif
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

    #if canImport(UIKit)
    /// Presents `DeviceCodeSignInSheet` over the top-most view controller and
    /// waits for its outcome. Returns nil if there's nothing to present from.
    ///
    /// Presented through UIKit rather than a `.sheet` modifier so callers
    /// (`SignInView`, `AccountSwitcherView`) keep calling one async function
    /// and need no sheet state of their own. When the sheet finishes on its
    /// own (signed in / use browser) it's dismissed here, and the outcome is
    /// delivered only once the dismissal completes — so the browser flow's
    /// auth sheet can present right after.
    @MainActor
    private static func presentDeviceCodeSheet(
        accountStore: AccountStore,
        clientId: String
    ) async -> DeviceCodeSignInModel.Outcome? {
        guard var top = foregroundWindow()?.rootViewController else { return nil }
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        let presenter = top
        // `Outcome` carries a non-Sendable `Account`, so it rides in a
        // main-actor box and the continuation only signals completion.
        let result = OutcomeBox()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            weak var hostRef: UIViewController?
            let model = DeviceCodeSignInModel(accountStore: accountStore, clientId: clientId) { outcome in
                result.outcome = outcome
                if let host = hostRef, host.presentingViewController != nil, !host.isBeingDismissed {
                    host.dismiss(animated: true) { continuation.resume() }
                } else {
                    // Already dismissed (swipe-down / Cancel).
                    continuation.resume()
                }
            }
            let host = UIHostingController(rootView: DeviceCodeSignInSheet(model: model))
            hostRef = host
            if let sheet = host.sheetPresentationController {
                sheet.detents = [.large()]
                sheet.prefersGrabberVisible = true
            }
            presenter.present(host, animated: true)
        }
        return result.outcome
    }

    @MainActor
    private final class OutcomeBox {
        var outcome: DeviceCodeSignInModel.Outcome?
    }
    #endif
}
