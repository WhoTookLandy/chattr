import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Shared developer / TestFlight diagnostic preferences and helpers.
///
/// Developer tools (Recent Logs, Chat Debug HUD, Copy Diagnostic Report) are
/// available automatically in DEBUG and TestFlight builds, and unlockable in
/// App Store builds via 7 taps on the Version row in Settings → About.
public enum DeveloperSettings {
    /// Persisted toggle for Release (App Store) builds, flipped by 7 taps on
    /// the Version row in `AboutSettingsScreen`.
    public static let devToolsUnlockedKey = "chattr.devToolsUnlocked"

    /// Shows a compact, non-interactive live state HUD over chat (`ChatDebugOverlay`)
    /// for diagnosing layout / connection / collection-view issues in TestFlight.
    public static let chatDebugHUDKey = "chattr.dev.chatDebugHUD"

    /// True when running an iOS TestFlight build (sandbox receipt beside the
    /// `.app` bundle). Evaluated once per process; avoids the deprecated
    /// `Bundle.main.appStoreReceiptURL` API.
    public static let isTestFlightBuild: Bool = {
        #if os(iOS) && !targetEnvironment(simulator) && !DEBUG
        let receiptURL = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .appending(path: "StoreKit/sandboxReceipt")
        return FileManager.default.fileExists(atPath: receiptURL.path())
        #else
        return false
        #endif
    }()

    /// True when developer tools should be visible without requiring the 7-tap
    /// unlock (DEBUG builds and TestFlight installs).
    public static var isAutomaticallyUnlocked: Bool {
        #if DEBUG
        return true
        #else
        return isTestFlightBuild
        #endif
    }

    /// True when developer tools are currently unlocked for this install.
    public static var isUnlocked: Bool {
        isAutomaticallyUnlocked || UserDefaults.standard.bool(forKey: devToolsUnlockedKey)
    }

    /// Human-readable build channel tag ("Debug", "TestFlight", or "Release").
    public static var buildChannel: String {
        #if DEBUG
        return "Debug"
        #else
        return isTestFlightBuild ? "TestFlight" : "Release"
        #endif
    }

    /// "1.2 (34)" from `Bundle.main`.
    public static var versionString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
    }

    /// Copies plain text to the system clipboard.
    @MainActor
    public static func copyToClipboard(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        #endif
    }
}
