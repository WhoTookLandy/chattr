import SwiftUI

/// User-configurable chat rendering preferences, backed by UserDefaults.
///
/// Same storage rationale as `HighlightSettings`: small, non-sensitive,
/// per-device preferences — a few plist reads, no schema migration.
///
/// ## Reactivity
///
/// Unlike highlight keywords (read once at chat attach), appearance must
/// apply *live* — the settings screen shows a real chat preview and the
/// user expects open chats to update instantly. So the values flow
/// through the SwiftUI environment: `RootView` reads the keys via
/// `@AppStorage` (KVO-reactive), assembles a `ChatAppearance`, and
/// injects it with `.environment(\.chatAppearance, ...)`. `ChatRow`
/// reads it via `@Environment` — environment changes re-render rows
/// even though `ChatRow` is `Equatable` (same mechanism the rows
/// already rely on for `colorScheme`).
public struct ChatAppearance: Equatable, Sendable {

    /// How to annotate a chatter's username with their login. A Twitch
    /// display name differs from the login only by capitalization OR as a
    /// fully localized non-Latin name — so "differs ignoring case" is a
    /// precise proxy for "this is a localized name worth annotating".
    public enum LoginNameDisplay: String, CaseIterable, Sendable {
        case off          // デレク
        case displayFirst // デレク (derek)   — default
        case loginFirst   // derek (デレク)
    }

    /// Default chat text size in points — matches `.callout` (16pt at the
    /// standard Dynamic Type setting), the pre-settings rendering.
    public static let defaultTextSizePoints: Double = 16

    /// Slider bounds for the settings screen. 12pt is the floor of
    /// comfortable legibility for dense chat; 24pt is title-ish.
    public static let textSizePointsRange: ClosedRange<Double> = 12...24

    /// Chat text size in points, BEFORE Dynamic Type scaling. The
    /// injection site (`RootView`, and the settings preview) multiplies
    /// this by a `@ScaledMetric` factor so the user's systemwide Dynamic
    /// Type setting still scales chat text — the slider picks the base,
    /// Dynamic Type scales the result. Replaced the old four-step
    /// Small/Default/Large/XL enum (see `migrateLegacyTextSizeIfNeeded`).
    public var textSizePoints: Double = ChatAppearance.defaultTextSizePoints

    /// Font for message body text, usernames, and timestamps.
    public var font: Font { .system(size: textSizePoints) }

    /// Multiplier for fixed-size inline images (emotes, badges) so they
    /// track the text size instead of towering over small text or
    /// vanishing next to large text. 1.0 at the default size.
    public var imageScale: CGFloat { textSizePoints / Self.defaultTextSizePoints }
    /// Leading HH:mm timestamp on each message row.
    public var showTimestamps: Bool = false
    /// Chat badges (mod / sub / VIP …) before the username.
    public var showBadges: Bool = true
    /// When false, animated 7TV/BTTV/FFZ emotes render their static
    /// first frame — battery saver + Reduce Motion-friendly.
    public var animatedEmotes: Bool = true
    /// When true, the transcript runs all the way to the physical top of
    /// the screen and scrolls underneath the floating toolbar pills,
    /// instead of stopping at the safe-area edge below them.
    public var edgeToEdge: Bool = false
    /// Annotate localized usernames with the login (see `loginAnnotation`).
    public var loginNameDisplay: LoginNameDisplay = .displayFirst

    public init(
        textSizePoints: Double = ChatAppearance.defaultTextSizePoints,
        showTimestamps: Bool = false,
        showBadges: Bool = true,
        animatedEmotes: Bool = true,
        edgeToEdge: Bool = false,
        loginNameDisplay: LoginNameDisplay = .displayFirst
    ) {
        self.textSizePoints = textSizePoints
        self.showTimestamps = showTimestamps
        self.showBadges = showBadges
        self.animatedEmotes = animatedEmotes
        self.edgeToEdge = edgeToEdge
        self.loginNameDisplay = loginNameDisplay
    }

    // MARK: - Storage keys
    //
    // Shared by RootView's @AppStorage (environment injection) and
    // ChatAppearanceScreen's @AppStorage (the editing controls). Both
    // observe the same UserDefaults keys, so edits propagate to every
    // open chat row without any explicit notification plumbing.

    public static let textSizePointsKey = "chattr.chatAppearance.textSizePoints"
    /// Pre-slider key holding the discrete Small/Default/Large/XL raw value.
    /// Read only by `migrateLegacyTextSizeIfNeeded`.
    public static let legacyTextSizeKey = "chattr.chatAppearance.textSize"
    public static let showTimestampsKey = "chattr.chatAppearance.showTimestamps"
    public static let showBadgesKey = "chattr.chatAppearance.showBadges"
    public static let animatedEmotesKey = "chattr.chatAppearance.animatedEmotes"
    public static let edgeToEdgeKey = "chattr.chatAppearance.edgeToEdge"
    public static let loginNameDisplayKey = "chattr.chatAppearance.loginNameDisplay"

    // MARK: - Chat history

    /// How many messages each chat retains, stored separately from the
    /// appearance struct because its consumers are the data layer
    /// (`ChannelSession`'s ring, `TabChatModel`'s buffer), not row
    /// rendering. Lives here anyway so all chat-preference keys share one
    /// namespace and one settings screen.
    public static let chatHistoryLinesKey = "chattr.chatAppearance.chatHistoryLines"
    public static let defaultChatHistoryLines = 500
    /// Offered steps. The floor keeps scrollback useful; the ceiling keeps
    /// per-channel memory and tab-switch priming cost bounded (every line
    /// re-normalizes on tab remount — see the settings footer).
    public static let chatHistoryOptions = [200, 500, 1000, 2000]

    /// The active history setting, defaulting when unset or out of range.
    public static func chatHistoryLines(defaults: UserDefaults = .standard) -> Int {
        let stored = defaults.integer(forKey: chatHistoryLinesKey)
        return chatHistoryOptions.contains(stored) ? stored : defaultChatHistoryLines
    }

    /// One-time carry-over from the discrete text-size enum to the points
    /// slider. Maps each old step to the point size of the text style it
    /// used (footnote 13 / callout 16 / body 17 / title3 20). No-ops when
    /// the points key is already set (user has touched the slider) or no
    /// legacy value exists. Idempotent and cheap — safe to call on every
    /// launch from `RootView.init`.
    public static func migrateLegacyTextSizeIfNeeded(defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: textSizePointsKey) == nil,
              let raw = defaults.string(forKey: legacyTextSizeKey) else { return }
        let points: Double
        switch raw {
        case "small":      points = 13
        case "large":      points = 17
        case "extraLarge": points = 20
        default:           points = defaultTextSizePoints
        }
        defaults.set(points, forKey: textSizePointsKey)
    }
}

// MARK: - Environment

private struct ChatAppearanceKey: EnvironmentKey {
    static let defaultValue = ChatAppearance()
}

extension EnvironmentValues {
    /// The active chat appearance. Defaults match the pre-settings
    /// rendering exactly, so views that render chat rows outside the
    /// injected scope (previews, tests) look unchanged.
    public var chatAppearance: ChatAppearance {
        get { self[ChatAppearanceKey.self] }
        set { self[ChatAppearanceKey.self] = newValue }
    }
}

// MARK: - Login annotation rule

extension ChatAppearance {
    /// The (primary, secondary) name pair to render for a username, or
    /// `nil` when no login annotation should be shown. `secondary` is the
    /// name shown in dimmed parentheses. The single source of truth for
    /// both the trigger rule and the name ordering.
    public static func loginAnnotation(
        displayName: String,
        login: String,
        style: LoginNameDisplay
    ) -> (primary: String, secondary: String)? {
        guard style != .off,
              !login.isEmpty,
              !displayName.isEmpty,
              displayName.lowercased() != login.lowercased() else {
            return nil
        }
        switch style {
        case .off:          return nil   // unreachable — guarded above
        case .displayFirst: return (displayName, login)
        case .loginFirst:   return (login, displayName)
        }
    }
}
