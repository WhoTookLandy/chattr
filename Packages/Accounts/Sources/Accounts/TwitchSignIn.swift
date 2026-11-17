import AuthenticationServices
import Foundation
import TwitchKit
import Core
import os

private let logger = AppLogger.make("Accounts.TwitchSignIn")

/// Centralized Twitch OAuth sign-in flow, shared by `SignInView`
/// (first-launch / re-auth) and the in-app account switcher
/// ("Add Account").
///
/// Before this existed, the flow was inline in `SignInView.signIn()`,
/// which meant adding a second account would have had to duplicate the
/// OAuth URL construction, `OAuthFlow.run`, and `AccountStore.add`
/// plumbing — including the scope list (a duplicate-source-of-truth risk
/// if the two drifted). Centralizing here keeps one definition of "what
/// it means to sign in to chattr."
///
/// UI-free by design: the window the auth sheet presents from is supplied
/// by the caller through the `presentationAnchor` provider. The UIKit
/// window lookup lives in `Features` (`TwitchSignIn+Presentation.swift`),
/// which also offers the anchor-less `run(accountStore:clientId:)`
/// convenience the views call.
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
    /// - `userReadModeratedChannels`: attach-time pre-seed of the
    ///   mod-only affordances. `/moderation/channels` answers "which
    ///   channels does THIS user moderate" with the user's own token —
    ///   unlike `/moderation/moderators`, which needs the BROADCASTER's
    ///   auth — so Delete Message appears the moment chat opens instead
    ///   of after the user's first sent message echoes back with a mod
    ///   badge. NOTE: same re-sign-in caveat as chat_settings — until
    ///   then the fetch fails unauthorized and chattr falls back to
    ///   badge observation (see
    ///   `ChannelSessionRegistry.moderatedChannelIds(forAccountUserId:)`).
    /// - `moderatorRead{BlockedTerms,UnbanRequests,BannedUsers,Warnings,
    ///   Moderators,Vips}`: the remainder of the `channel.moderate` v2
    ///   EventSub bundle. The subscription demands ALL of seven
    ///   read-or-manage scope pairs; our existing
    ///   `moderatorManageChatMessages` + `moderatorManageChatSettings`
    ///   satisfy two, these six cover the rest. chattr only consumes the
    ///   `mod`/`unmod` actions (live mod-status downgrade/upgrade — see
    ///   `ChannelSession.enableModerationEvents`), but Twitch doesn't
    ///   offer a narrower subscription. Same harmless-for-non-mods
    ///   rationale as the manage scopes: the subscribe is only attempted
    ///   once mod status is already established, and Twitch rejects it
    ///   server-side otherwise. Same re-sign-in caveat too — pre-scope
    ///   tokens get a swallowed 403 on subscribe and mod status simply
    ///   stays attach-time-static, exactly the pre-existing behavior.
    /// - `userReadBlockedUsers` / `userManageBlockedUsers`: the Twitch
    ///   block list (`BlockStore`) — Get User Block List needs the read
    ///   scope, Block / Unblock User need the manage scope. Same re-sign-in
    ///   caveat: older tokens keep the locally cached block list, and
    ///   block/unblock roll back with an unauthorized error until the
    ///   account signs in again.
    /// - `moderatorManageBannedUsers` / `moderatorManageWarnings`: the user
    ///   card's moderation row — timeout / ban / unban (POST + DELETE
    ///   `/moderation/bans`) and warn (POST `/moderation/warnings`). Same
    ///   harmless-for-non-mods rationale as the other manage scopes, and the
    ///   same re-sign-in caveat: an older token lacks them, which
    ///   `HelixChatActions` detects from the token's granted scopes BEFORE
    ///   any request (a 401 would make TwitchKit wipe the stored token) and
    ///   reports as `ModerationActionError.needsSignInAgain` — a "sign out
    ///   and back in" message on the card.
    public static let scopes: [TwitchScope] = [
        .userReadEmail,
        .userReadChat,
        .userWriteChat,
        .userReadFollows,
        .userReadEmotes,
        .userReadModeratedChannels,
        .moderatorManageChatMessages,
        .moderatorManageChatSettings,
        .moderatorManageBannedUsers,
        .moderatorManageWarnings,
        .moderatorReadBlockedTerms,
        .moderatorReadUnbanRequests,
        .moderatorReadBannedUsers,
        .moderatorReadWarnings,
        .moderatorReadModerators,
        .moderatorReadVips,
        .userReadBlockedUsers,
        .userManageBlockedUsers,
        // Viewer list (GET /chat/chatters) for channels you moderate.
        .moderatorReadChatters,
        .clipsEdit, // Create Clip (POST /clips); pre-scope tokens get 401 → CreateClipSheet asks to sign in again.
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
    /// `AccountStore.add` is account-count-agnostic. `add` also writes the
    /// new account's userId to the active-account UserDefaults key
    /// (`AccountStore.activeAccountUserIdKey`), so it becomes active
    /// automatically — RootView's `@AppStorage` observes that key.
    ///
    /// - Parameter presentationAnchor: Returns the window to present the
    ///   auth sheet from, or nil if none is available. Called once, on the
    ///   main actor, before the sheet is shown.
    /// - Returns: the newly-added `Account`.
    /// - Throws: `AppError` if no window anchor is available; rethrows
    ///   OAuth / network errors from the flow.
    @discardableResult
    public static func run(
        accountStore: AccountStore,
        clientId: String,
        presentationAnchor: @MainActor () -> ASPresentationAnchor?
    ) async throws -> Account {
        let oauthClient = TwitchOAuthClient(
            clientId: clientId,
            redirectUri: redirectURI
        )
        let authURL = oauthClient.authorizationCodeURL(scopes: scopes)

        #if canImport(UIKit)
        guard let anchor = presentationAnchor() else {
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
