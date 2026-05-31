import Foundation
import SwiftData

/// A locally persisted Twitch account.
///
/// One row per signed-in Twitch identity. Tokens are *not* stored here —
/// they live in TwitchKit's `KeychainTokenStore` keyed by `tokenNamespace`.
/// This row stores the public-ish identity bits the UI needs.
@Model
public final class Account {
    /// Twitch user_id — the canonical stable identifier.
    @Attribute(.unique)
    public var userId: String

    /// Twitch login (lowercase username, e.g. "xqc").
    public var login: String

    /// Twitch display name (preserved capitalization, e.g. "xQc").
    public var displayName: String

    /// URL string to the user's profile image (Twitch hosts these).
    public var profileImageURL: String

    /// The `tokenNamespace` value passed to `TwitchClient` for this account.
    /// Constructed once at sign-in and never changes.
    public var tokenNamespace: String

    /// When this account was added. Used as a tiebreaker in the account
    /// switcher when `lastSelectedAt` values collide (e.g. all existing
    /// accounts got the same default after the migration).
    public var addedAt: Date

    /// When this account was last made active (tapped in the switcher, or
    /// added). The "active" account is the one with the most recent
    /// `lastSelectedAt` — RootView's `@Query` sorts by this descending and
    /// shows `accounts.first`. Switching accounts is just "bump this
    /// timestamp and let `@Query` reactivity float the row to the top."
    ///
    /// Lightweight-migration-safe: new required property WITH a default
    /// (`.now`). Existing rows auto-populate with the default on first
    /// load after the update — they all get roughly the same timestamp,
    /// so `addedAt` becomes the effective tiebreaker for pre-existing
    /// accounts (most-recently-added stays active, matching prior behavior).
    public var lastSelectedAt: Date

    /// When true, the account's refresh token failed and the user must re-auth.
    public var needsReauth: Bool

    public init(
        userId: String,
        login: String,
        displayName: String,
        profileImageURL: String,
        tokenNamespace: String,
        addedAt: Date = .now,
        lastSelectedAt: Date = .now,
        needsReauth: Bool = false
    ) {
        self.userId = userId
        self.login = login
        self.displayName = displayName
        self.profileImageURL = profileImageURL
        self.tokenNamespace = tokenNamespace
        self.addedAt = addedAt
        self.lastSelectedAt = lastSelectedAt
        self.needsReauth = needsReauth
    }
}
