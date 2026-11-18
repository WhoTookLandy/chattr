import Accounts
import Channels
import Core
import Foundation
import SwiftData

/// Baseline versioned schema for chattr's SwiftData store.
///
/// ## Why this exists
///
/// The container was previously built with the bare
/// `ModelContainer(for: Account.self, …)` initializer, which gives SwiftData
/// only *inferred* (lightweight) migration. Inferred migration silently
/// handles a narrow set of changes (adding an optional/defaulted property);
/// anything outside that — a new non-optional field, a rename without
/// `originalName:`, a type change — fails at container init. Combined with the
/// `fatalError` fallback in `chattrApp`, the first such change would crash
/// every existing user on launch with no recovery.
///
/// Declaring an explicit `VersionedSchema` + `SchemaMigrationPlan` now — while
/// the store is still V1-shaped — is free (the schema is structurally identical,
/// so no migration runs for existing installs) and makes every *future* schema
/// change expressible as a `MigrationStage` instead of a crash.
///
/// ## Adding a future version
///
/// 1. Snapshot the changed model set as `AppSchemaV2` (include ALL models,
///    even unchanged ones — a `VersionedSchema` is a full snapshot, not a diff).
/// 2. Append `AppSchemaV2.self` to `AppMigrationPlan.schemas`.
/// 3. Append a `MigrationStage.lightweight(...)` or `.custom(...)` to
///    `AppMigrationPlan.stages`.
/// 4. Point the container at the new latest schema.
///
/// Test the upgrade path on a *real device* with pre-existing data — the
/// simulator deletes the store on rebuild and never exercises migration.
///
/// ## Frozen snapshots
///
/// An older schema must describe the models *as they were*, so when a model
/// changes, its previous shape is copied into the old schema as a nested
/// `@Model` with the same class name (SwiftData keys entities by the
/// unqualified name). Pointing two versions at the same live class gives
/// them identical checksums, and SwiftData rejects the plan at launch.
/// `Account` and `JoinedChannel` haven't changed since V1, so every version
/// still references the live types; freeze them here the first time they
/// change.
public enum AppSchemaV1: VersionedSchema {
    public static let versionIdentifier = Schema.Version(1, 0, 0)

    public static var models: [any PersistentModel.Type] {
        // `PersistedChatTab` resolves to the frozen nested copy below.
        [Account.self, JoinedChannel.self, PersistedChatTab.self]
    }

    /// `Features.PersistedChatTab` as shipped in V1 (before tabs were
    /// account-scoped). Must stay byte-for-byte equivalent in stored
    /// properties and attributes to what V1 stores were created with, or
    /// SwiftData won't recognise existing stores as V1. Never edit it.
    @Model
    final class PersistedChatTab {
        @Attribute(.unique) var id: UUID
        var order: Int
        var channels: [ChannelDescriptor]
        var addedAt: Date

        init(id: UUID, order: Int, channels: [ChannelDescriptor], addedAt: Date) {
            self.id = id
            self.order = order
            self.channels = channels
            self.addedAt = addedAt
        }
    }
}

/// V2: chat tabs are per-account. Adds `PersistedChatTab.accountUserId`
/// (`String`, default `""`).
public enum AppSchemaV2: VersionedSchema {
    public static let versionIdentifier = Schema.Version(2, 0, 0)

    public static var models: [any PersistentModel.Type] {
        // The live `Features.PersistedChatTab`.
        [Account.self, JoinedChannel.self, PersistedChatTab.self]
    }
}

/// The schema the app's container is built with. Bump when adding a version.
public typealias AppSchemaLatest = AppSchemaV2

/// Migration plan for the SwiftData store.
public enum AppMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [AppSchemaV1.self, AppSchemaV2.self]
    }

    public static var stages: [MigrationStage] {
        [migrateV1toV2]
    }

    /// V1 → V2 adds `PersistedChatTab.accountUserId`. Lightweight is enough:
    /// it's a new attribute with a declared default, so existing rows get
    /// `""` ("legacy, not yet owned"). `TabPersistence.fetchAll()` then hands
    /// those rows to the first account that hydrates after the upgrade — the
    /// pre-upgrade strip belonged to whoever was signed in, which is almost
    /// always the account that launches first. Rows aren't stamped here
    /// because the store doesn't know which account is active.
    ///
    /// Computed, not a stored `static let`: `MigrationStage` isn't `Sendable`.
    static var migrateV1toV2: MigrationStage {
        .lightweight(fromVersion: AppSchemaV1.self, toVersion: AppSchemaV2.self)
    }
}
