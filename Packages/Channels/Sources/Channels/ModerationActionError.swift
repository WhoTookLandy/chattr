import Foundation
import TwitchKit

/// A ban / timeout / unban / warn that Twitch refused, reduced to what the
/// user card can say about it.
public enum ModerationActionError: Error, Sendable, Equatable, LocalizedError {
    /// Still unauthorized AFTER `HelixAuthRetry`'s bridge refresh + retry.
    /// A freshly refreshed token that's still refused means it lacks the
    /// scope (`moderator:manage:banned_users` / `moderator:manage:warnings`):
    /// the account signed in before chattr asked for them, and refreshing
    /// never adds scopes — only signing in again does.
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
