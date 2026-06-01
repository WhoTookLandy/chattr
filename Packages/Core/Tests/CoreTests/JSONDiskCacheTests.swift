import Foundation
import Testing
@testable import Core

@Suite("JSONDiskCache")
struct JSONDiskCacheTests {

    struct Sample: Codable, Sendable, Equatable {
        let name: String
        let count: Int
    }

    /// Fresh unique temp directory per test — never touches the real Caches dir.
    private func tempBase() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("jsondiskcache-tests-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("save then load returns payload and is fresh")
    func saveLoadFresh() async throws {
        let cache = JSONDiskCache(subdirectory: "t", baseDirectory: tempBase())
        await cache.save(key: "k", value: Sample(name: "a", count: 1), version: 1)

        let hit = await cache.load(key: "k", as: Sample.self, version: 1, ttl: 60)
        #expect(hit?.payload == Sample(name: "a", count: 1))
        #expect(hit?.isFresh == true)
    }

    @Test("missing file is a miss")
    func missIsNil() async {
        let cache = JSONDiskCache(subdirectory: "t", baseDirectory: tempBase())
        let hit = await cache.load(key: "absent", as: Sample.self, version: 1, ttl: 60)
        #expect(hit == nil)
    }

    @Test("version mismatch is a miss")
    func versionMismatch() async {
        let base = tempBase()
        let cache = JSONDiskCache(subdirectory: "t", baseDirectory: base)
        await cache.save(key: "k", value: Sample(name: "a", count: 1), version: 1)

        let hit = await cache.load(key: "k", as: Sample.self, version: 2, ttl: 60)
        #expect(hit == nil)
    }

    @Test("corrupt bytes are a miss")
    func corruptIsNil() async throws {
        let base = tempBase()
        let cache = JSONDiskCache(subdirectory: "t", baseDirectory: base)
        let dir = base.appendingPathComponent("t", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("k.json"))

        let hit = await cache.load(key: "k", as: Sample.self, version: 1, ttl: 60)
        #expect(hit == nil)
    }

    @Test("file older than ttl loads but is not fresh")
    func staleNotFresh() async throws {
        let base = tempBase()
        let cache = JSONDiskCache(subdirectory: "t", baseDirectory: base)
        await cache.save(key: "k", value: Sample(name: "a", count: 1), version: 1)

        // Backdate the file's modification time to 2 hours ago.
        let url = base.appendingPathComponent("t", isDirectory: true)
            .appendingPathComponent("k.json")
        let old = Date().addingTimeInterval(-7200)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)

        let hit = await cache.load(key: "k", as: Sample.self, version: 1, ttl: 3600)
        #expect(hit?.payload == Sample(name: "a", count: 1))   // still returns data
        #expect(hit?.isFresh == false)                          // but flagged stale
    }

    @Test("sweep deletes files older than maxAge and keeps newer ones")
    func sweepDeletesOld() async throws {
        let base = tempBase()
        let cache = JSONDiskCache(subdirectory: "t", baseDirectory: base)
        await cache.save(key: "old", value: Sample(name: "o", count: 1), version: 1)
        await cache.save(key: "new", value: Sample(name: "n", count: 2), version: 1)

        let dir = base.appendingPathComponent("t", isDirectory: true)
        let oldDate = Date().addingTimeInterval(-10 * 24 * 3600)   // 10 days ago
        try FileManager.default.setAttributes(
            [.modificationDate: oldDate],
            ofItemAtPath: dir.appendingPathComponent("old.json").path)

        await cache.sweep(maxAge: 7 * 24 * 3600)                  // 7 days

        #expect(await cache.load(key: "old", as: Sample.self, version: 1, ttl: 60) == nil)
        #expect(await cache.load(key: "new", as: Sample.self, version: 1, ttl: 60) != nil)
    }
}
