import Foundation
import os
// `OSLog` (capital-L module) is separate from `os` despite the obvious
// confusion. `Logger` lives in `os`; `OSLogStore`/`OSLogEntryLog` live in
// `OSLog`. Both are required for the OSLogStore fallback reader.
import OSLog

/// Privacy policy for interpolated values in `AppLogMessage`, matching
/// `OSLogPrivacy` call-site syntax (`\(value, privacy: .public)` / `.private`).
public enum AppLogPrivacy: Sendable {
    case `public`
    case `private`
    case auto
    case sensitive
}

/// Interpolated log message that redacts `.private` / `.sensitive` values
/// *before* reaching either `os.Logger` or `DiagnosticLogStore`.
public struct AppLogMessage: ExpressibleByStringLiteral, ExpressibleByStringInterpolation, Sendable {
    public let text: String

    public init(stringLiteral value: String) {
        self.text = value
    }

    public init(stringInterpolation: StringInterpolation) {
        self.text = stringInterpolation.storage
    }

    public struct StringInterpolation: StringInterpolationProtocol {
        var storage: String

        public init(literalCapacity: Int, interpolationCount: Int) {
            storage = ""
            storage.reserveCapacity(literalCapacity + interpolationCount * 12)
        }

        public mutating func appendLiteral(_ literal: String) {
            storage.append(literal)
        }

        public mutating func appendInterpolation(_ value: Bool) {
            storage.append(String(value))
        }

        public mutating func appendInterpolation(_ value: Bool, privacy: AppLogPrivacy) {
            switch privacy {
            case .private, .sensitive:
                storage.append("<private>")
            case .public, .auto:
                storage.append(String(value))
            }
        }

        public mutating func appendInterpolation<T: FixedWidthInteger>(_ value: T) {
            storage.append(String(value))
        }

        public mutating func appendInterpolation<T: FixedWidthInteger>(_ value: T, privacy: AppLogPrivacy) {
            switch privacy {
            case .private, .sensitive:
                storage.append("<private>")
            case .public, .auto:
                storage.append(String(value))
            }
        }

        public mutating func appendInterpolation<T: BinaryFloatingPoint>(_ value: T) {
            storage.append(String(describing: value))
        }

        public mutating func appendInterpolation<T: BinaryFloatingPoint>(_ value: T, privacy: AppLogPrivacy) {
            switch privacy {
            case .private, .sensitive:
                storage.append("<private>")
            case .public, .auto:
                storage.append(String(describing: value))
            }
        }

        /// Mirrors Apple's `OSLogInterpolation` default privacy: dynamic strings
        /// and arbitrary objects are redacted unless explicitly marked `.public`,
        /// preventing accidental credential leaks in memory or disk logs.
        public mutating func appendInterpolation<T>(_ value: T) {
            storage.append("<private>")
        }

        public mutating func appendInterpolation<T>(_ value: T, privacy: AppLogPrivacy) {
            switch privacy {
            case .public:
                storage.append(String(describing: value))
            case .private, .sensitive, .auto:
                storage.append("<private>")
            }
        }
    }
}

/// Dual-sink logger returned by `AppLogger.make(_:)`: forwards every message
/// to Apple's unified logging (`os.Logger`) AND records it into
/// `DiagnosticLogStore` so TestFlight builds retain `.debug` / `.info` logs
/// and can export them cleanly without Xcode attached.
public struct AppLog: Sendable {
    public let category: String
    private let osLogger: Logger
    private let store: DiagnosticLogStore

    init(
        subsystem: String,
        category: String,
        store: DiagnosticLogStore = .shared
    ) {
        self.category = category
        self.osLogger = Logger(subsystem: subsystem, category: category)
        self.store = store
    }

    public func debug(_ message: AppLogMessage) {
        let text = message.text
        osLogger.debug("\(text, privacy: .public)")
        store.record(level: .debug, category: category, message: text)
    }

    public func info(_ message: AppLogMessage) {
        let text = message.text
        osLogger.info("\(text, privacy: .public)")
        store.record(level: .info, category: category, message: text)
    }

    public func notice(_ message: AppLogMessage) {
        let text = message.text
        osLogger.notice("\(text, privacy: .public)")
        store.record(level: .notice, category: category, message: text)
    }

    public func warning(_ message: AppLogMessage) {
        let text = message.text
        osLogger.warning("\(text, privacy: .public)")
        store.record(level: .warning, category: category, message: text)
    }

    public func error(_ message: AppLogMessage) {
        let text = message.text
        osLogger.error("\(text, privacy: .public)")
        store.record(level: .error, category: category, message: text)
    }

    public func fault(_ message: AppLogMessage) {
        let text = message.text
        osLogger.fault("\(text, privacy: .public)")
        store.record(level: .fault, category: category, message: text)
    }
}

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
/// Always annotate sensitive values (tokens, refresh tokens, Keychain data)
/// with `privacy: .private` — `AppLogMessage` redacts them to `<private>`
/// before writing to either `os.Logger` or `DiagnosticLogStore`.
public enum AppLogger {
    /// Bundle-identifier-style subsystem name used by every chattr logger.
    public static let subsystem = "com.andrewbeshay.chattr"

    /// Convenience builder: `AppLogger.make("Accounts")` → dual-sink `AppLog`
    /// writing to both `os.Logger` and `DiagnosticLogStore.shared`.
    public static func make(_ category: String) -> AppLog {
        AppLog(subsystem: subsystem, category: category)
    }

    /// Companion to `make(_:)` for signpost-based timing instrumentation.
    /// Returns an `OSSignposter` sharing chattr's subsystem so signposts
    /// show up alongside text logs under the same identifier.
    public static func signposter(_ category: String) -> OSSignposter {
        OSSignposter(subsystem: subsystem, category: category)
    }

    // MARK: - Recent entries (DevLogView / debug menu)

    /// One log entry, ready for display in `DevLogView` and diagnostic exports.
    public struct Entry: Sendable, Identifiable, Equatable, Hashable {
        public let id: Int
        public let date: Date
        public let level: Level
        public let category: String
        public let composedMessage: String

        public init(
            id: Int,
            date: Date,
            level: Level,
            category: String,
            composedMessage: String
        ) {
            self.id = id
            self.date = date
            self.level = level
            self.category = category
            self.composedMessage = composedMessage
        }

        /// Mirrors the relevant cases of `OSLogEntryLog.Level`, plus a fallback
        /// for unknowns.
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

    /// Fetch recent log entries, newest-first.
    ///
    /// Reads from `DiagnosticLogStore.shared` first (which preserves `.debug`
    /// and `.info` reliably in TestFlight / Release builds without Xcode
    /// attached), falling back to `OSLogStore` if the in-app buffer is empty.
    public static func recentEntries(
        limit: Int = 500,
        minLevel: Entry.Level = .info
    ) -> [Entry] {
        guard limit > 0 else { return [] }
        let buffered = DiagnosticLogStore.shared.entries(limit: limit, minLevel: minLevel)
        if !buffered.isEmpty || DiagnosticLogStore.shared.hasCleared {
            return buffered
        }
        return recentOSLogEntries(limit: limit, minLevel: minLevel)
    }

    /// Reads the rotated previous-session log file, if one exists on disk.
    public static func previousSessionLog(maxBytes: Int = 64 * 1024) -> String? {
        DiagnosticLogStore.shared.previousSessionLog(maxBytes: maxBytes)
    }

    /// Clears the in-app log buffer and on-disk rotating log files.
    public static func clearRecentEntries() {
        DiagnosticLogStore.shared.clear()
    }

    private static func recentOSLogEntries(
        limit: Int,
        minLevel: Entry.Level
    ) -> [Entry] {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let position = store.position(date: Date(timeIntervalSinceNow: -3600))
            let predicate = NSPredicate(format: "subsystem == %@", subsystem)
            let raw = try store.getEntries(at: position, matching: predicate)

            var ring: [Entry] = []
            ring.reserveCapacity(limit)
            var writeIndex = 0

            for entry in raw {
                guard let log = entry as? OSLogEntryLog else { continue }
                let level = Self.mapLevel(log.level)
                guard level.severity >= minLevel.severity else { continue }
                var hasher = Hasher()
                hasher.combine(log.date)
                hasher.combine(log.category)
                hasher.combine(log.composedMessage)
                let item = Entry(
                    id: hasher.finalize(),
                    date: log.date,
                    level: level,
                    category: log.category,
                    composedMessage: log.composedMessage
                )
                if ring.count < limit {
                    ring.append(item)
                } else {
                    ring[writeIndex] = item
                    writeIndex = (writeIndex + 1) % limit
                }
            }

            guard !ring.isEmpty else { return [] }
            var result: [Entry] = []
            result.reserveCapacity(ring.count)
            if ring.count < limit {
                for item in ring.reversed() { result.append(item) }
            } else {
                for offset in 1...ring.count {
                    let idx = (writeIndex - offset + limit) % limit
                    result.append(ring[idx])
                }
            }
            return result
        } catch {
            return []
        }
    }

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
