import Foundation
import TwitchKit
import Core
import os
#if canImport(UIKit)
import UIKit
#endif

private let logger = AppLogger.make("Accounts.TwitchSignIn")

/// Centralized Twitch OAuth sign-in flow, shared by `SignInView`
/// (first-launch / re-auth) and the in-app account switcher
/// ("Add Account").
///
/// Before this existed, the flow was inline in `SignInView.signIn()`,
/// which meant adding a second account would have had to duplicate the
/// OAuth URL construction, window-anchor lookup, `OAuthFlow.run`, and
/// `AccountStore.add` plumbing — including the scope list (a
/// duplicate-source-of-truth risk if the two drifted). Centralizing
/// here keeps one definition of "what it means to sign in to chattr."
@MainActor
public enum TwitchSignIn {

    /// The viewer-facing scopes chattr requests. Single source of truth.
    ///
    /// - `userReadEmail` / `userReadChat` / `userWriteChat` /
    ///   `userReadFollows`: core viewer + send capability.
    /// - `userReadEmotes`: launch-time emote-image prefetch
    ///   (`/chat/emotes/user`).
    /// - `moderatorManageChatMessages`: mod-only Delete Message
    ///   affordance. Non-mods approve it harmlessly; Twitch rejects the
    ///   delete server-side if the user isn't actually a mod.
    /// - `moderatorManageChatSettings`: mod-only Chat Modes section in
    ///   the in-chat settings sheet (emote-only, slow mode, …). Same
    ///   harmless-for-non-mods rationale as chat_messages. NOTE:
    ///   accounts signed in before this scope was added must sign in
    ///   again to pick it up — until then the PATCH fails with
    ///   unauthorized and the sheet surfaces the error.
    public static let scopes: [TwitchScope] = [
        .userReadEmail,
        .userReadChat,
        .userWriteChat,
        .userReadFollows,
        .userReadEmotes,
        .moderatorManageChatMessages,
        .moderatorManageChatSettings,
    ]

    /// The redirect URI the Vercel bridge 302-redirects back to. Must
    /// match the Twitch dev-portal registration and the bridge config.
    private static let redirectURI = Endpoints.ChattrAuth.callback.absoluteString

    /// Custom URL scheme the bridge redirects to with exchanged tokens.
    /// `ASWebAuthenticationSession` privileged-intercepts it.
    private static let callbackScheme = "chattr"

    /// Runs the full sign-in flow: build the OAuth URL, present the
    /// `ASWebAuthenticationSession` sheet, exchange happens server-side
    /// (client_secret stays off-device), then `AccountStore.add` does the
    /// `/users` probe + Keychain persistence + SwiftData insert.
    ///
    /// Works for BOTH first sign-in and adding an additional account —
    /// `AccountStore.add` is account-count-agnostic. The new account's
    /// `lastSelectedAt` defaults to `.now`, so it becomes active
    /// automatically (RootView sorts by that descending).
    ///
    /// - Returns: the newly-added `Account`.
    /// - Throws: `AppError` if no window anchor is available; rethrows
    ///   OAuth / network errors from the flow.
    @discardableResult
    public static func run(
        accountStore: AccountStore,
        clientId: String
    ) async throws -> Account {
        let oauthClient = TwitchOAuthClient(
            clientId: clientId,
            redirectUri: redirectURI
        )
        let authURL = oauthClient.authorizationCodeURL(scopes: scopes)

        #if canImport(UIKit)
        guard
            let scene = UIApplication.shared.connectedScenes
                .first(where: { $0 is UIWindowScene }) as? UIWindowScene,
            let anchor = scene.windows.first
        else {
            throw AppError(message: "Couldn't find a window to present sign-in from.")
        }

        let token = try await OAuthFlow.run(
            authURL: authURL,
            callbackScheme: callbackScheme,
            presentationAnchor: anchor
        )
        let account = try await accountStore.add(token: token, scopes: scopes)
        logger.info("Sign-in succeeded for @\(account.login, privacy: .public)")
        return account
        #else
        throw AppError(message: "Sign-in is not supported on this platform.")
        #endif
    }
}
