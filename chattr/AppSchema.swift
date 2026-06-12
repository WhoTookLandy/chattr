//
//  AppSchema.swift
//  chattr
//

import Accounts
import Channels
import Features
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
enum AppSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [Account.self, JoinedChannel.self, PersistedChatTab.self]
    }
}

/// Migration plan for the SwiftData store. V1 is the baseline, so there are no
/// stages yet — the first schema change adds the first stage.
enum AppMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [AppSchemaV1.self]
    }

    static var stages: [MigrationStage] {
        []
    }
}
