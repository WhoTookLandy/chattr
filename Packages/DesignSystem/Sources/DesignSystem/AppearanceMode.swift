import SwiftUI

/// User-selectable appearance mode for the app. Persisted via `@AppStorage`
/// using the `rawValue` String, then mapped to SwiftUI's optional
/// `ColorScheme` via `preferredColorScheme` (nil = follow system).
///
/// Why a public enum here (in DesignSystem) instead of a private one in
/// Features: SettingsScreen reads/writes the value via @AppStorage, but the
/// app root (chattrApp) also reads it to apply `.preferredColorScheme(_:)`
/// at the WindowGroup level. Both surfaces import DesignSystem.
public enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    /// User-facing name for pickers / settings rows.
    public var displayName: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    /// Maps to SwiftUI's `.preferredColorScheme(_:)` input.
    /// `system` returns nil → SwiftUI defers to UIScreen's trait collection.
    public var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    /// The `@AppStorage` key used app-wide for the persisted choice. Keeping
    /// the key in one place avoids drift between SettingsScreen (writer) and
    /// chattrApp (reader).
    public static let storageKey = "appearanceMode"
}

// MARK: - @AppStorage convenience binding

public extension AppStorage where Value == String {
    /// Convenience initializer that creates the canonical `@AppStorage` binding
    /// for the persisted appearance mode. Call sites read/write `String` raw
    /// values; convert with `AppearanceMode(rawValue:)` at the boundary.
    init(appearanceMode: Void) {
        self.init(wrappedValue: AppearanceMode.system.rawValue, AppearanceMode.storageKey)
    }
}
