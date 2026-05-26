import Foundation
import os

/// Centralized logger subsystem identifier for all chattr packages.
public enum AppLogger {
    /// Bundle-identifier-style subsystem name used by every chattr logger.
    public static let subsystem = "com.andrewbeshay.chattr"

    /// Convenience builder: `AppLogger.make("Accounts")` → `Logger(subsystem: ..., category: "Accounts")`.
    public static func make(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }
}
