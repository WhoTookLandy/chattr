import Testing
import Foundation
import SwiftData
import Accounts
import Channels
import Core
@testable import Features

/// The store bootstrap (`AppModelContainer`) and the versioned schema it
/// opens (`AppSchema.swift`), run against store files in a temporary
/// directory.
///
/// Each test leaves its directory for the system to clear: deleting a store
/// that a live container still has open is something SQLite objects to.
@Suite("AppModelContainer / AppSchema")
@MainActor
struct AppModelContainerTests {

    // MARK: - Fixtures

    private func makeStoreDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chattr-store-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeChannel(_ name: String) -> ChannelDescriptor {
        ChannelDescriptor(
            channelId: "\(name)-id", channelLoginName: name,
            channelDisplayName: name, profileImageURL: nil
        )
    }

    private func backupFolders(in directory: URL) throws -> [URL] {
        let backups = directory.appendingPathComponent("StoreBackups", isDirectory: true)
        guard FileManager.default.fileExists(atPath: backups.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)
    }

    private func identifiers(_ types: [any PersistentModel.Type]) -> [ObjectIdentifier] {
        types.map { ObjectIdentifier($0) }
    }

    private func propertyNames(of entityName: String, in schema: Schema) throws -> Set<String> {
        let entity = try #require(schema.entitiesByName[entityName])
        return Set(entity.storedProperties.map { $0.name })
    }

    /// A store as a V1 build left it: created from the frozen V1 schema,
    /// holding one tab row per channel. The container is gone when this
    /// returns.
    private func writeV1Store(at storeURL: URL, tabs: [(id: UUID, channel: ChannelDescriptor)]) throws {
        let container = try ModelContainer(
            for: Schema(versionedSchema: AppSchemaV1.self),
            configurations: ModelConfiguration(url: storeURL)
        )
        for (order, tab) in tabs.enumerated() {
            container.mainContext.insert(AppSchemaV1.PersistedChatTab(
                id: tab.id,
                order: order,
                channels: [tab.channel],
                addedAt: Date(timeIntervalSince1970: 1_000)
            ))
        }
        try container.mainContext.save()
    }

    // MARK: - Bootstrap

    @Test("A fresh store opens on disk and keeps what is saved to it")
    func freshStoreOpens() throws {
        let directory = try makeStoreDirectory()
        let storeURL = directory.appendingPathComponent("app.store")

        let (container, openedExisting) = AppModelContainer.open(storeURL: storeURL)

        #expect(openedExisting)
        #expect(FileManager.default.fileExists(atPath: storeURL.path))
        #expect(try backupFolders(in: directory).isEmpty)
        let tabs = TabPersistence(modelContainer: container, accountUserId: "account-a")
        try tabs.save(tabs: [ChatTab(channel: makeChannel("one"))])
        #expect(try tabs.fetchAll().map { $0.channels.first?.channelLoginName } == ["one"])
    }

    @Test("A store file that won't open is moved aside intact and a fresh store takes its place")
    func corruptStoreIsMovedAside() throws {
        let directory = try makeStoreDirectory()
        let storeURL = directory.appendingPathComponent("app.store")
        // Not a SQLite database (and not empty, which SQLite would accept).
        let garbage = Data(repeating: 0x5A, count: 16 * 1024)
        try garbage.write(to: storeURL)

        let (container, openedExisting) = AppModelContainer.open(storeURL: storeURL)

        #expect(!openedExisting)
        let folders = try backupFolders(in: directory)
        #expect(folders.count == 1)
        let backedUp = try #require(folders.first).appendingPathComponent("app.store")
        #expect(try Data(contentsOf: backedUp) == garbage)
        // On disk again, not the in-memory fallback.
        #expect(FileManager.default.fileExists(atPath: storeURL.path))
        #expect(try Data(contentsOf: storeURL) != garbage)
        let tabs = TabPersistence(modelContainer: container, accountUserId: "account-a")
        try tabs.save(tabs: [ChatTab(channel: makeChannel("one"))])
        #expect(try tabs.fetchAll().count == 1)
    }

    @Test("Moving a store aside takes its WAL and SHM with it; missing files are fine")
    func moveAsideTakesSidecars() throws {
        let directory = try makeStoreDirectory()
        let storeURL = directory.appendingPathComponent("app.store")
        for suffix in ["", "-shm", "-wal"] {
            try Data("store\(suffix)".utf8).write(to: URL(fileURLWithPath: storeURL.path + suffix))
        }

        #expect(AppModelContainer.moveStoreFilesAside(at: storeURL))

        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["StoreBackups"])
        let folder = try #require(try backupFolders(in: directory).first)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
            == ["app.store", "app.store-shm", "app.store-wal"])
        #expect(try Data(contentsOf: folder.appendingPathComponent("app.store-wal")) == Data("store-wal".utf8))

        // Nothing left to move.
        #expect(AppModelContainer.moveStoreFilesAside(at: storeURL))
    }

    // MARK: - Schema

    @Test("The current schema is V2: Account, JoinedChannel and the live PersistedChatTab")
    func currentSchemaModels() throws {
        #expect(AppSchemaLatest.versionIdentifier == Schema.Version(2, 0, 0))
        #expect(identifiers(AppSchemaLatest.models)
            == identifiers([Account.self, JoinedChannel.self, PersistedChatTab.self]))
        let schema = Schema(versionedSchema: AppSchemaLatest.self)
        #expect(schema.entities.map { $0.name }.sorted() == ["Account", "JoinedChannel", "PersistedChatTab"])
        #expect(try propertyNames(of: "PersistedChatTab", in: schema)
            == ["accountUserId", "addedAt", "channels", "id", "order"])
    }

    @Test("V1 keeps the tab model as it shipped, under the same entity name")
    func frozenV1Model() throws {
        #expect(AppSchemaV1.versionIdentifier == Schema.Version(1, 0, 0))
        #expect(identifiers(AppSchemaV1.models)
            == identifiers([Account.self, JoinedChannel.self, AppSchemaV1.PersistedChatTab.self]))
        let schema = Schema(versionedSchema: AppSchemaV1.self)
        #expect(schema.entities.map { $0.name }.sorted() == ["Account", "JoinedChannel", "PersistedChatTab"])
        #expect(try propertyNames(of: "PersistedChatTab", in: schema) == ["addedAt", "channels", "id", "order"])
    }

    @Test("The migration plan runs V1 to V2 in one stage")
    func migrationPlanShape() {
        #expect(AppMigrationPlan.schemas.map { ObjectIdentifier($0) }
            == [ObjectIdentifier(AppSchemaV1.self), ObjectIdentifier(AppSchemaV2.self)])
        #expect(AppMigrationPlan.stages.count == 1)
    }

    // MARK: - Migration

    /// The V1 store here is written by SwiftData from the frozen
    /// `AppSchemaV1`, so this covers the plan and the bootstrap, not whether
    /// the frozen snapshot matches what shipped V1 builds wrote: that needs
    /// a store file from such a build.
    @Test("A store written by the V1 schema opens in place, its tab rows kept and unowned")
    func migratesV1Store() throws {
        let directory = try makeStoreDirectory()
        let storeURL = directory.appendingPathComponent("app.store")
        let first = (id: UUID(), channel: makeChannel("one"))
        let second = (id: UUID(), channel: makeChannel("two"))
        try writeV1Store(at: storeURL, tabs: [first, second])

        let (container, openedExisting) = AppModelContainer.open(storeURL: storeURL)

        #expect(openedExisting)
        #expect(try backupFolders(in: directory).isEmpty)
        let rows = try container.mainContext.fetch(FetchDescriptor<PersistedChatTab>(
            sortBy: [SortDescriptor(\.order, order: .forward)]
        ))
        #expect(rows.map(\.id) == [first.id, second.id])
        #expect(rows.map { $0.channels.first?.channelLoginName } == ["one", "two"])
        #expect(rows.map(\.accountUserId) == ["", ""])

        // The first account to hydrate adopts them.
        let tabs = TabPersistence(modelContainer: container, accountUserId: "account-a")
        #expect(try tabs.fetchAll().map(\.accountUserId) == ["account-a", "account-a"])
    }
}
