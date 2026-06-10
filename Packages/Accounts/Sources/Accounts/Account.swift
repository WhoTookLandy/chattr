import Foundation
import SwiftData
import Core

/// A locally persisted chat-platform account.
///
/// One row per signed-in identity. Tokens are *not* stored here —
/// they live in TwitchKit's `KeychainTokenStore` keyed by `tokenNamespace`.
/// This row stores the public-ish identity bits the UI needs.
@Model
public final class Account {
    /// Platform user_id — the canonical stable identifier (Twitch user_id
    /// today; Kick/YouTube IDs later, disambiguated by `platformRaw`).
    @Attribute(.unique)
    public var userId: String

    /// Which platform this identity belongs to, stored as the raw string
    /// so SwiftData's lightweight migration can backfill existing rows
    /// with the literal default — every pre-multi-platform row IS a
    /// Twitch account. (An enum-typed property would also work, but the
    /// raw string keeps the stored schema independent of the enum's
    /// Codable encoding and survives a future case rename via mapping
    /// in the computed accessor.)
    public var platformRaw: String = ChatPlatform.twitch.rawValue

    /// Typed accessor over `platformRaw`. Unknown raw values (a future
    /// build's platform opened in an old build) fall back to `.twitch`
    /// rather than trapping.
    public var platform: ChatPlatform {
        get { ChatPlatform(rawValue: platformRaw) ?? .twitch }
        set { platformRaw = newValue.rawValue }
    }

    /// Twitch login (lowercase username, e.g. "xqc").
    public var login: String

    /// Twitch display name (preserved capitalization, e.g. "xQc").
    public var displayName: String

    /// URL string to the user's profile image (Twitch hosts these).
    public var profileImageURL: String

    /// The `tokenNamespace` value passed to `TwitchClient` for this account.
    /// Constructed once at sign-in and never changes.
    public var tokenNamespace: String

    /// When this account was added. Used as the default sort + the
    /// fallback "active account" pick (most-recently-added) when no
    /// active-account selection is stored.
    ///
    /// NOTE: the "active account" is intentionally NOT a field here.
    /// It's per-device UI state (you might be on account A on iPhone, B
    /// on iPad), so it lives in UserDefaults under
    /// `AccountStore.activeAccountUserIdKey`. Putting it in SwiftData
    /// would (a) wrongly sync across devices if CloudKit is ever added
    /// and (b) require a custom migration — a runtime `.now` default
    /// can't backfill an existing store's mandatory column.
    public var addedAt: Date

    /// When true, the account's refresh token failed and the user must re-auth.
    public var needsReauth: Bool

    public init(
        userId: String,
        platform: ChatPlatform = .twitch,
        login: String,
        displayName: String,
        profileImageURL: String,
        tokenNamespace: String,
        addedAt: Date = .now,
        needsReauth: Bool = false
    ) {
        self.userId = userId
        self.platformRaw = platform.rawValue
        self.login = login
        self.displayName = displayName
        self.profileImageURL = profileImageURL
        self.tokenNamespace = tokenNamespace
        self.addedAt = addedAt
        self.needsReauth = needsReauth
    }
}
