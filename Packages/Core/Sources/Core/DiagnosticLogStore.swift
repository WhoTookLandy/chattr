import Foundation
import os

/// Thread-safe, in-app rolling log store backing `AppLogger` and `DevLogView`.
///
/// ## Why this exists alongside `os.Logger`
///
/// `OSLogStore(scope: .currentProcessIdentifier)` is unreliable in TestFlight
/// (Release) builds without Xcode attached: iOS drops `.debug` entries before
/// they ever reach the store, evicts `.info` entries aggressively, and wipes
/// the store completely across process boundaries (crashes / force-quits).
///
/// `DiagnosticLogStore` mirrors every `AppLogger` call into:
///   1. A bounded in-memory ring buffer (`capacity` entries, O(1) append) so
///      `DevLogView` and diagnostic report exports always have the full recent
///      timeline — including `.debug` and `.info` — on TestFlight devices.
///   2. A tiny rotating text log under `Caches/diagnostic-logs/` (`current.log`,
///      rotated to `previous.log` on launch and whenever it exceeds
///      `maxFileBytes`), written asynchronously on a low-priority serial queue
///      so logging never blocks the main actor and the pre-crash run survives
///      relaunch.
///
/// Privacy: callers pass already-redacted messages from `AppLogMessage`, where
/// `.private` and `.sensitive` interpolations are replaced with `<private>`
/// before reaching this store.
public final class DiagnosticLogStore: Sendable {

    /// Process-wide store used by `AppLogger`.
    public static let shared = DiagnosticLogStore()

    private static let currentLogFilename = "current.log"
    private static let previousLogFilename = "previous.log"

    private struct MemoryState: Sendable {
        var ring: [AppLogger.Entry] = []
        var writeIndex: Int = 0
        var nextId: Int = 1
        var clearedAt: Date? = nil
    }

    private struct DiskState: Sendable {
        var prepared = false
        var currentFileBytes = 0
    }

    private let capacity: Int
    private let directory: URL?
    private let maxFileBytes: Int
    private let memory: OSAllocatedUnfairLock<MemoryState>
    private let disk: OSAllocatedUnfairLock<DiskState>
    private let ioQueue: DispatchQueue

    /// - Parameters:
    ///   - capacity: Maximum entries retained in memory.
    ///   - directory: Directory for `current.log` / `previous.log`, or `nil`
    ///     for memory-only storage (useful in unit tests).
    ///   - maxFileBytes: Soft byte ceiling for `current.log` before rotating
    ///     to `previous.log`.
    public init(
        capacity: Int = 1_500,
        directory: URL? = DiagnosticLogStore.defaultDirectory(),
        maxFileBytes: Int = 256 * 1024
    ) {
        self.capacity = max(1, capacity)
        self.directory = directory
        self.maxFileBytes = max(1_024, maxFileBytes)
        self.memory = OSAllocatedUnfairLock(initialState: MemoryState())
        self.disk = OSAllocatedUnfairLock(initialState: DiskState())
        self.ioQueue = DispatchQueue(
            label: "com.andrewbeshay.chattr.diagnostic-log",
            qos: .utility
        )
    }

    public static func defaultDirectory() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent(CacheSubdirectory.diagnosticLogs, isDirectory: true)
    }

    // MARK: - Recording

    /// Appends one entry to the in-memory ring buffer and enqueues it for
    /// best-effort persistence to `current.log`.
    public func record(
        level: AppLogger.Entry.Level,
        category: String,
        message: String,
        date: Date = Date()
    ) {
        let cap = capacity
        memory.withLock { state in
            let id = state.nextId
            state.nextId &+= 1
            let entry = AppLogger.Entry(
                id: id,
                date: date,
                level: level,
                category: category,
                composedMessage: message
            )
            if state.ring.count < cap {
                state.ring.append(entry)
            } else {
                state.ring[state.writeIndex] = entry
                state.writeIndex = (state.writeIndex + 1) % cap
            }
        }

        guard let directory else { return }
        let line = Self.formatLine(date: date, level: level, category: category, message: message) + "\n"
        ioQueue.async { [weak self] in
            self?.appendToDisk(line, in: directory)
        }
    }

    // MARK: - Reading

    /// Recent entries from memory, newest-first (matching `AppLogger.recentEntries`).
    public func entries(
        limit: Int = 500,
        minLevel: AppLogger.Entry.Level = .debug
    ) -> [AppLogger.Entry] {
        guard limit > 0 else { return [] }
        return memory.withLock { state in
            guard !state.ring.isEmpty else { return [] }
            let count = state.ring.count
            let cap = capacity
            var result: [AppLogger.Entry] = []
            result.reserveCapacity(min(limit, count))

            if count < cap {
                for entry in state.ring.reversed() {
                    guard entry.level.severity >= minLevel.severity else { continue }
                    result.append(entry)
                    if result.count == limit { break }
                }
            } else {
                for offset in 1...count {
                    let idx = (state.writeIndex - offset + cap) % cap
                    let entry = state.ring[idx]
                    guard entry.level.severity >= minLevel.severity else { continue }
                    result.append(entry)
                    if result.count == limit { break }
                }
            }
            return result
        }
    }

    /// Reads the rotated `previous.log` (the prior launch before a crash or
    /// restart, or the prior segment after a mid-session rotation), truncated
    /// to the trailing `maxBytes` so diagnostic exports stay compact.
    ///
    /// Performs file I/O; call from a background task.
    public func previousSessionLog(maxBytes: Int = 64 * 1024) -> String? {
        guard let directory else { return nil }
        // Ensure launch-time rotation has occurred before reading `previous.log`.
        ioQueue.sync {
            prepareDiskIfNeeded(in: directory)
        }
        let url = directory.appendingPathComponent(Self.previousLogFilename)
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        let slice: Data
        if data.count > maxBytes {
            slice = data.suffix(maxBytes)
        } else {
            slice = data
        }
        let text = String(decoding: slice, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// True once `clear()` has been invoked in this process, so callers avoid
    /// falling back to pre-clear `OSLogStore` entries when the buffer is empty.
    public var hasCleared: Bool {
        memory.withLock { $0.clearedAt != nil }
    }

    /// Clears the in-memory ring buffer and deletes persisted log files.
    public func clear() {
        memory.withLock { state in
            state.ring.removeAll(keepingCapacity: true)
            state.writeIndex = 0
            state.clearedAt = Date()
        }
        guard let directory else { return }
        ioQueue.sync {
            let fm = FileManager.default
            try? fm.removeItem(at: directory.appendingPathComponent(Self.currentLogFilename))
            try? fm.removeItem(at: directory.appendingPathComponent(Self.previousLogFilename))
            disk.withLock { state in
                state.prepared = true
                state.currentFileBytes = 0
            }
        }
    }

    /// Waits for all queued disk writes to complete (primarily for unit tests).
    public func flush() {
        ioQueue.sync {}
    }

    // MARK: - Formatting

    private static let isoStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// Formats one entry as a single line (newlines inside `message` collapsed
    /// so every log entry stays greppable and easy to read in exports).
    public static func formatLine(
        date: Date,
        level: AppLogger.Entry.Level,
        category: String,
        message: String
    ) -> String {
        let timestamp = date.formatted(isoStyle)
        let singleLine = message
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        return "\(timestamp) [\(level.rawValue.uppercased())] [\(category)] \(singleLine)"
    }

    /// Formats newest-first `entries` into chronological (oldest-first) text
    /// suitable for sharing or pasting into a bug report.
    public static func formatChronological(_ entries: [AppLogger.Entry]) -> String {
        entries.reversed().map { entry in
            formatLine(
                date: entry.date,
                level: entry.level,
                category: entry.category,
                message: entry.composedMessage
            )
        }.joined(separator: "\n")
    }

    // MARK: - Disk internals (ioQueue only)

    private func prepareDiskIfNeeded(in directory: URL) {
        let alreadyPrepared = disk.withLock { $0.prepared }
        guard !alreadyPrepared else { return }

        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let currentURL = directory.appendingPathComponent(Self.currentLogFilename)
        let previousURL = directory.appendingPathComponent(Self.previousLogFilename)

        if let attrs = try? fm.attributesOfItem(atPath: currentURL.path),
           let size = attrs[.size] as? NSNumber,
           size.intValue > 0 {
            try? fm.removeItem(at: previousURL)
            try? fm.moveItem(at: currentURL, to: previousURL)
        }

        disk.withLock { state in
            state.prepared = true
            state.currentFileBytes = 0
        }
    }

    private func appendToDisk(_ line: String, in directory: URL) {
        prepareDiskIfNeeded(in: directory)
        guard let data = line.data(using: .utf8) else { return }

        let fm = FileManager.default
        let currentURL = directory.appendingPathComponent(Self.currentLogFilename)
        let previousURL = directory.appendingPathComponent(Self.previousLogFilename)

        let currentBytes = disk.withLock { $0.currentFileBytes }
        if currentBytes + data.count > maxFileBytes, fm.fileExists(atPath: currentURL.path) {
            try? fm.removeItem(at: previousURL)
            try? fm.moveItem(at: currentURL, to: previousURL)
            disk.withLock { $0.currentFileBytes = 0 }
        }

        if !fm.fileExists(atPath: currentURL.path) {
            fm.createFile(atPath: currentURL.path, contents: nil)
        }

        if let handle = try? FileHandle(forWritingTo: currentURL) {
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                disk.withLock { $0.currentFileBytes += data.count }
            } catch {
                // Best-effort diagnostics: never fail the app for a log write.
            }
        }
    }
}
