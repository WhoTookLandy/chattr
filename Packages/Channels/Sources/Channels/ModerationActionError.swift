import Foundation
import TwitchKit

/// A ban / timeout / unban / warn that Twitch refused, reduced to what the
/// user card can say about it.
public enum ModerationActionError: Error, Sendable, Equatable, LocalizedError {
    /// The sign-in lacks the scope (`moderator:manage:banned_users` /
    /// `moderator:manage:warnings`): the account signed in before chattr
    /// asked for them, and refreshing never adds scopes — only signing in
    /// again does. Usually thrown BEFORE any request, from the token's
    /// granted-scope list (`HelixChatActions.requireGrantedScope`); also the
    /// mapping for a request still unauthorized after `HelixAuthRetry`'s
    /// bridge refresh + retry (a token with no recorded scope list).
    case needsSignInAgain
    /// Twitch said no and explained why ("The user specified in user_id is
    /// already banned.", "not one of the broadcaster's moderators", …).
    case rejected(String)

    public var errorDescription: String? {
        switch self {
        case .needsSignInAgain:
            return "chattr needs new permissions for moderation tools. Sign out and sign back in to enable them."
        case .rejected(let message):
            return message
        }
    }

    /// Maps a Helix failure; nil for errors that aren't Twitch refusing the
    /// action (network, cancellation …) — callers rethrow those unchanged.
    static func from(_ error: any Error) -> ModerationActionError? {
        switch error {
        case let alreadyMapped as ModerationActionError:
            // The scope pre-check in `HelixChatActions` throws this directly.
            return alreadyMapped
        case HelixError.unauthorized, HelixError.oauth, HelixError.notAuthenticated:
            return .needsSignInAgain
        case HelixError.forbidden(let apiError),
             HelixError.badRequest(let apiError),
             HelixError.conflict(let apiError),
             HelixError.unprocessable(let apiError):
            return .rejected(apiError.message)
        default:
            return nil
        }
    }
}
