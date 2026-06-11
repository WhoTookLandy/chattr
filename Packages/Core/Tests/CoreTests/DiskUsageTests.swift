import Foundation
import Testing
@testable import Core

@Suite("DiskUsage")
struct DiskUsageTests {

    /// Fresh unique temp directory per test — never touches the real Caches dir.
    private func tempBase() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("diskusage-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("missing directory measures as zero")
    func missingDirectoryIsZero() async {
        let absent = FileManager.default.temporaryDirectory
            .appendingPathComponent("diskusage-absent-\(UUID().uuidString)", isDirectory: true)
        let size = await DiskUsage().size(of: absent)
        #expect(size == 0)
    }

    @Test("counts files recursively, including subdirectories")
    func countsRecursively() async throws {
        let base = try tempBase()
        let nested = base.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(count: 4096).write(to: base.appendingPathComponent("a.bin"))
        try Data(count: 4096).write(to: nested.appendingPathComponent("b.bin"))

        let size = await DiskUsage().size(of: base)
        // Allocated size is filesystem-block rounded, so assert a lower
        // bound (both files' bytes) rather than an exact figure.
        #expect(size >= 8192)
    }

    @Test("removeDirectory deletes the directory and contents")
    func removeDeletes() async throws {
        let base = try tempBase()
        try Data(count: 16).write(to: base.appendingPathComponent("a.bin"))

        await DiskUsage().removeDirectory(at: base)
        #expect(!FileManager.default.fileExists(atPath: base.path))
    }

    @Test("removeDirectory on a missing directory is a no-op")
    func removeMissingIsNoOp() async {
        let absent = FileManager.default.temporaryDirectory
            .appendingPathComponent("diskusage-absent-\(UUID().uuidString)", isDirectory: true)
        await DiskUsage().removeDirectory(at: absent)
        #expect(!FileManager.default.fileExists(atPath: absent.path))
    }
}
