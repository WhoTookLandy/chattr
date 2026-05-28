import Foundation
import os
// `OSLog` (capital-L module) is separate from `os` despite the obvious
// confusion. `Logger` lives in `os`; `OSLogStore`/`OSLogEntryLog` live in
// `OSLog`. Both are required for the recent-entries reader.
import OSLog

/// Centralized logger subsystem identifier for all chattr packages.
///
/// ## Log level conventions
///
/// Pick the lowest level that still captures the intent. The `DevLogView`
/// filter defaults to `.info` — anything `.debug` or below is hidden by
/// default. Use that mental model: "would I want to see this line by
/// default when investigating?" If yes, `.info` or above; if no, `.debug`.
///
/// | Level     | Use for                                                                 |
/// |-----------|-------------------------------------------------------------------------|
/// | `.debug`  | Verbose per-operation state changes (per-message, per-event).           |
/// |           | Example: "append message \(messageId)", "refcount → 3"                  |
/// | `.info`   | Milestones — operation completed, async work finished.                  |
/// |           | Example: "EmoteIndex loaded for @login: 47 emotes"                      |
/// | `.notice` | Boundary crossings — user action, account change, channel open/close.   |
/// |           | Example: "Sign-in completed", "Active account → \(userId)"              |
/// | `.warning`| Recoverable anomalies — fell back to a cache, double-release ignored.   |
/// |           | Example: "TwitchKit store empty; recovering via chattr-side cache"      |
/// | `.error`  | Operation failed — couldn't complete the work, surface to user/caller.  |
/// |           | Example: "Bridge refresh failed (HTTP 503)"                             |
/// | `.fault`  | Programming bug — invariant violated, assertion-level.                  |
/// |           | Example: "ForEach ID collision detected"                                |
///
/// ## Privacy
///
/// `os.Logger` redacts string interpolations by default on device (the
/// console shows `<private>`). Explicit annotations override:
///
///   - `logger.info("for @\(login, privacy: .public)")`  — visible on device
///   - `logger.debug("token \(token, privacy: .private)")` — redacted always
///   - `logger.info("count = \(count)")` — numeric, never redacted
///
/// Annotation policy for chattr:
///   - User logins, channel IDs, message IDs, error codes → `.public`
///     (they're not secrets; visibility helps debugging in production)
///   - Tokens, refresh tokens, anything from Keychain → `.private`
///   - Numeric counts, durations, status codes → no annotation (never redacted)
///
/// ## Examples
///
/// ```swift
/// private let logger = AppLogger.make("Accounts.AccountStore")
///
/// logger.debug("Append cached refresh token entry: bytes=\(data.count)")
/// logger.info("Refreshed tokens for @\(login, privacy: .public)")
/// logger.notice("Active account → \(userId, privacy: .public)")
/// logger.warning("Falling back to chattr-side refresh cache for @\(login, privacy: .public)")
/// logger.error("Bridge refresh failed for @\(login, privacy: .public) (HTTP \(status))")
/// ```
public enum AppLogger {
    /// Bundle-identifier-style subsystem name used by every chattr logger.
    public static let subsystem = "com.andrewbeshay.chattr"

    /// Convenience builder: `AppLogger.make("Accounts")` → `Logger(subsystem: ..., category: "Accounts")`.
    public static func make(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }

    /// Companion to `make(_:)` for signpost-based timing instrumentation.
    /// Returns an `OSSignposter` sharing chattr's subsystem so signposts
    /// show up alongside text logs under the same identifier.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// private let signposter = AppLogger.signposter("ChatScreen")
    ///
    /// let id = signposter.makeSignpostID()
    /// let state = signposter.beginInterval("emote-load", id: id, "channel=\(login)")
    /// await emoteIndex.load(...)
    /// signposter.endInterval("emote-load", state, "count=\(emoteIndex.snapshot().count)")
    /// ```
    ///
    /// ## Where to see them
    ///
    /// Instruments → File → New Trace → Logging template → "Points of
    /// Interest" lane. Each `beginInterval`/`endInterval` pair shows as
    /// a graphical bar — overlapping operations are visible as overlapping
    /// bars, cancelled operations show as truncated bars.
    ///
    /// Free-form signposts (`emitEvent`) also work and appear as
    /// instantaneous markers — useful for "a thing happened" annotations
    /// without a duration.
    public static func signposter(_ category: String) -> OSSignposter {
        OSSignposter(subsystem: subsystem, category: category)
    }

    // MARK: - Recent entries (DevLogView / debug menu)

    /// One log entry, ready for display in a dev-only log viewer.
    ///
    /// ## Why a separate type from `OSLogEntryLog`
    ///
    /// `OSLogEntryLog` is the underlying Apple type. It's NOT `Sendable`
    /// and carries internal references to the OSLogStore — bad for SwiftUI
    /// `@State` arrays (would require unsafe pointer juggling) and bad
    /// for crossing actor boundaries.
    ///
    /// `Entry` is a snapshot: it pulls out just the fields we want, has a
    /// value-type identity, conforms to `Sendable`, and is safe to hold
    /// in @State or pass across `await` boundaries.
    public struct Entry: Sendable, Identifiable, Equatable, Hashable {
        public let id: UUID
        public let date: Date
        public let level: Level
        public let category: String
        public let composedMessage: String

        /// Mirrors the relevant cases of `OSLogEntryLog.Level`, plus a fallback
        /// for unknowns. We surface our own enum so consumers (e.g., a SwiftUI
        /// view) don't have to import `os` just to switch on severity.
        public enum Level: String, Sendable, CaseIterable {
            case debug, info, notice, warning, error, fault, undefined

            /// Comparable ordering for "show entries at level X or above."
            /// Higher index = more severe.
            public var severity: Int {
                switch self {
                case .debug:     return 0
                case .info:      return 1
                case .notice:    return 2
                case .warning:   return 3
                case .error:     return 4
                case .fault:     return 5
                case .undefined: return -1
                }
            }
        }
    }

    /// Fetch recent log entries from this process's `OSLogStore`, filtered to
    /// chattr's subsystem.
    ///
    /// ## How this works
    ///
    /// `OSLogStore.local()` reads from the unified system log Apple maintains
    /// for every process. Since iOS 15, your app can read its own entries
    /// without any entitlement (cross-process reads still require special
    /// privileges).
    ///
    /// We filter via an `NSPredicate` matching our subsystem at the store
    /// layer (much faster than iterating + filtering in Swift), then map
    /// each `OSLogEntryLog` into our `Entry` value type.
    ///
    /// ## Performance
    ///
    /// Synchronous OSLogStore reads are fast — ~10-50ms for a few hundred
    /// entries on a modern device. Still bad on the main thread; call from
    /// a background Task in views.
    ///
    /// ## What entries does this return
    ///
    /// Everything `logger.*` (and TwitchKit's logger, and Apple's own
    /// framework logs at chattr's subsystem) emitted in the current process
    /// since launch, subject to OS retention (typically minutes-to-hours
    /// of recent activity). It does NOT return entries from a previous
    /// run — process boundaries reset the local view.
    ///
    /// - Parameters:
    ///   - limit: Maximum number of entries to return (newest first).
    ///   - minLevel: Lowest severity to include.
    /// - Returns: Entries newest-first.
    public static func recentEntries(
        limit: Int = 200,
        minLevel: Entry.Level = .info
    ) -> [Entry] {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            // Start from a generous lookback. OSLogStore positions are
            // wall-clock-based; 1 hour comfortably covers a debugging
            // session without scanning the whole log.
            let position = store.position(date: Date(timeIntervalSinceNow: -3600))
            let predicate = NSPredicate(format: "subsystem == %@", subsystem)
            let raw = try store.getEntries(at: position, matching: predicate)

            var collected: [Entry] = []
            // OSLogStore returns oldest-first; we collect everything matching
            // and reverse at the end so callers see newest-first.
            for entry in raw {
                guard let log = entry as? OSLogEntryLog else { continue }
                let level = Self.mapLevel(log.level)
                guard level.severity >= minLevel.severity else { continue }
                collected.append(Entry(
                    id: UUID(),
                    date: log.date,
                    level: level,
                    category: log.category,
                    composedMessage: log.composedMessage
                ))
            }

            // Newest-first + truncate to limit. We collect everything first
            // (rather than streaming + early-exit) because OSLogStore doesn't
            // expose a reverse iterator.
            let reversed = collected.reversed()
            return Array(reversed.prefix(limit))
        } catch {
            // Store unavailable, predicate malformed, etc. Return empty
            // rather than throwing — the dev view shows an empty state.
            return []
        }
    }

    /// Map `OSLogEntryLog.Level` (Apple) → `Entry.Level` (ours). The case
    /// names mostly line up; `notice` and `undefined` are the only quirks.
    /// `warning` is our own intermediate level that maps to `.error` at the
    /// OS layer (Apple's enum doesn't have a `.warning` case; calls to
    /// `logger.warning(...)` are stored as `.error` severity in OSLogStore).
    private static func mapLevel(_ os: OSLogEntryLog.Level) -> Entry.Level {
        switch os {
        case .debug:     return .debug
        case .info:      return .info
        case .notice:    return .notice
        case .error:     return .error
        case .fault:     return .fault
        case .undefined: return .undefined
        @unknown default: return .undefined
        }
    }
}
