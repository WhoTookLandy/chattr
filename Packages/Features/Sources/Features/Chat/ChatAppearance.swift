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

    /// Chat text size as a *discrete step over Dynamic Type text styles*,
    /// not a raw point size. Each step maps to a system text style, so
    /// the user's systemwide Dynamic Type setting still scales chat text
    /// — this is "chat density relative to your preferred size," which
    /// is the HIG-compliant way to offer an app-local size control.
    public enum TextSize: String, CaseIterable, Identifiable, Sendable {
        case small
        case standard
        case large
        case extraLarge

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .small: return "Small"
            case .standard: return "Default"
            case .large: return "Large"
            case .extraLarge: return "XL"
            }
        }

        /// Font for message body text and usernames. `.callout` is the
        /// pre-settings default — `.standard` preserves it exactly.
        public var font: Font {
            switch self {
            case .small: return .footnote
            case .standard: return .callout
            case .large: return .body
            case .extraLarge: return .title3
            }
        }

        /// Multiplier for fixed-size inline images (emotes, badges) so
        /// they track the text size instead of towering over small text
        /// or vanishing next to XL text.
        public var imageScale: CGFloat {
            switch self {
            case .small: return 0.85
            case .standard: return 1.0
            case .large: return 1.15
            case .extraLarge: return 1.35
            }
        }
    }

    public var textSize: TextSize = .standard
    /// Leading HH:mm timestamp on each message row.
    public var showTimestamps: Bool = false
    /// Chat badges (mod / sub / VIP …) before the username.
    public var showBadges: Bool = true
    /// When false, animated 7TV/BTTV/FFZ emotes render their static
    /// first frame — battery saver + Reduce Motion-friendly.
    public var animatedEmotes: Bool = true

    public init(
        textSize: TextSize = .standard,
        showTimestamps: Bool = false,
        showBadges: Bool = true,
        animatedEmotes: Bool = true
    ) {
        self.textSize = textSize
        self.showTimestamps = showTimestamps
        self.showBadges = showBadges
        self.animatedEmotes = animatedEmotes
    }

    // MARK: - Storage keys
    //
    // Shared by RootView's @AppStorage (environment injection) and
    // ChatAppearanceScreen's @AppStorage (the editing controls). Both
    // observe the same UserDefaults keys, so edits propagate to every
    // open chat row without any explicit notification plumbing.

    public static let textSizeKey = "chattr.chatAppearance.textSize"
    public static let showTimestampsKey = "chattr.chatAppearance.showTimestamps"
    public static let showBadgesKey = "chattr.chatAppearance.showBadges"
    public static let animatedEmotesKey = "chattr.chatAppearance.animatedEmotes"
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
