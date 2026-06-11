import Foundation

/// Off-main directory measurement + removal for the Storage settings UI.
///
/// `actor` for the same reason as `JSONDiskCache`: all file I/O runs off the
/// main actor — `@MainActor` callers simply `await` into it. Both operations
/// are best-effort: a missing directory measures as 0 bytes and removes as a
/// no-op, so callers never need to pre-check existence.
public actor DiskUsage {

    public init() {}

    /// Total allocated size in bytes of all regular files under `directory`,
    /// recursively. Allocated size (not logical file size) so the number
    /// matches what Files/Settings would attribute to the app on disk.
    public func size(of directory: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }

    /// Deletes `directory` and everything under it. Cache writers
    /// (`JSONDiskCache.save`, Nuke's `DataCache`) recreate their directory
    /// on the next write, so removal is always safe.
    public func removeDirectory(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
