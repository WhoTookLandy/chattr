import Foundation
import os

private let logger = AppLogger.make("Core.JSONDiskCache")

/// Well-known cache subdirectories (under `Caches/`). Centralised so writers
/// and the launch-time sweep agree on the same path strings.
public enum CacheSubdirectory {
    /// Global Twitch badge + emote metadata (single file).
    public static let emoteGlobals = "emote-cache"
    /// Per-channel third-party emote metadata (one file per broadcasterId).
    public static let emoteChannels = "emote-cache/channels"
}

/// Versioned wrapper written to disk. A version bump invalidates older files.
struct CacheEnvelope<Payload: Codable>: Codable {
    let version: Int
    let payload: Payload
}

/// Result of a cache read: the decoded payload plus whether it is within TTL.
/// `isFresh == false` means "render this now, but revalidate from network".
public struct CacheHit<T> {
    public let payload: T
    public let isFresh: Bool
}

extension CacheHit: Sendable where T: Sendable {}

/// Generic on-disk JSON cache, one instance per subdirectory under `Caches/`.
///
/// `actor` so all file I/O runs off the main actor — `@MainActor` and other
/// `actor` callers simply `await` into it. Reads never throw: any failure
/// (absent, corrupt, version mismatch) is reported as a miss (`nil`) so the
/// caller falls back to the network. Writes are best-effort and atomic.
public actor JSONDiskCache {
    private let directory: URL
    private let fileManager: FileManager

    /// - Parameters:
    ///   - subdirectory: path appended to the base (e.g. `CacheSubdirectory.emoteGlobals`).
    ///   - baseDirectory: defaults to the user's Caches directory; inject a temp dir in tests.
    public init(subdirectory: String, baseDirectory: URL? = nil) {
        let base = baseDirectory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.directory = base.appendingPathComponent(subdirectory, isDirectory: true)
        self.fileManager = .default
    }

    private func fileURL(for key: String) -> URL {
        directory.appendingPathComponent(key).appendingPathExtension("json")
    }

    /// Returns a hit (payload + freshness) or `nil` on any miss.
    public func load<T: Codable & Sendable>(
        key: String, as type: T.Type, version: Int, ttl: TimeInterval
    ) -> CacheHit<T>? {
        let url = fileURL(for: key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let envelope = try? JSONDecoder().decode(CacheEnvelope<T>.self, from: data),
              envelope.version == version else {
            return nil
        }
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        let age = values?.contentModificationDate
            .map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        return CacheHit(payload: envelope.payload, isFresh: age < ttl)
    }

    /// Best-effort atomic write. Failures are logged and swallowed.
    public func save<T: Codable & Sendable>(key: String, value: T, version: Int) {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(CacheEnvelope(version: version, payload: value))
            try data.write(to: fileURL(for: key), options: .atomic)
        } catch {
            logger.debug("JSONDiskCache save failed for \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Deletes files in this subdirectory whose modification date is older than `maxAge`.
    public func sweep(maxAge: TimeInterval) {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let now = Date()
        for url in urls {
            guard let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate else { continue }
            if now.timeIntervalSince(mtime) > maxAge {
                try? fileManager.removeItem(at: url)
            }
        }
    }
}
