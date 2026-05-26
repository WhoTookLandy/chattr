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

    /// When this account was added. Used for sorting in the account switcher.
    public var addedAt: Date

    /// When true, the account's refresh token failed and the user must re-auth.
    public var needsReauth: Bool

    public init(
        userId: String,
        login: String,
        displayName: String,
        profileImageURL: String,
        tokenNamespace: String,
        addedAt: Date = .now,
        needsReauth: Bool = false
    ) {
        self.userId = userId
        self.login = login
        self.displayName = displayName
        self.profileImageURL = profileImageURL
        self.tokenNamespace = tokenNamespace
        self.addedAt = addedAt
        self.needsReauth = needsReauth
    }
}
