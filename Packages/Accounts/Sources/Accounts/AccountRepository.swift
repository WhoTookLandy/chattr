import Foundation
import SwiftData
import Core

/// SwiftData access for `Account` rows.
///
/// Every operation goes through the container's `mainContext`, never a
/// throwaway `ModelContext(modelContainer)`:
///   - An ephemeral context deallocates at end of scope, leaving the
///     `@Model` objects it returned with no live backing context — reading
///     any property afterwards is undefined behavior (stale reads /
///     EXC_BAD_ACCESS). `mainContext` lives for the app's lifetime.
///   - `mainContext` is the context RootView's `@Query` observes. Inserts
///     and deletes made through a separate context can fail to propagate
///     change events, leaving the UI on a stale account list.
///
/// `@MainActor` because `mainContext` is main-actor bound and `@Model`
/// instances aren't `Sendable` (see `AccountStore` for the full rationale).
@MainActor
final class AccountRepository {
    private let modelContainer: ModelContainer

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    private var context: ModelContext { modelContainer.mainContext }

    /// All accounts across every platform, newest-first.
    func all() throws -> [Account] {
        var descriptor = FetchDescriptor<Account>()
        descriptor.sortBy = [SortDescriptor(\.addedAt, order: .reverse)]
        return try context.fetch(descriptor)
    }

    /// Accounts for one platform, newest-first. The predicate filters on
    /// the stored `platformRaw` column — `#Predicate` can't see the
    /// computed `platform` accessor.
    func all(on platform: ChatPlatform) throws -> [Account] {
        let raw = platform.rawValue
        var descriptor = FetchDescriptor<Account>(predicate: #Predicate { $0.platformRaw == raw })
        descriptor.sortBy = [SortDescriptor(\.addedAt, order: .reverse)]
        return try context.fetch(descriptor)
    }

    /// The row for `userId`, or nil if none exists.
    func account(userId: String) throws -> Account? {
        var descriptor = FetchDescriptor<Account>(predicate: #Predicate { $0.userId == userId })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// Login for a stored account, or nil if no row exists for `userId`
    /// (or the fetch fails).
    func login(forUserId userId: String) -> String? {
        (try? account(userId: userId))?.login
    }

    /// Whether any account other than `userId` is still signed in (not
    /// flagged `needsReauth`). A failed fetch reads as "none".
    func hasHealthyAccount(excluding userId: String) -> Bool {
        (try? context.fetch(FetchDescriptor<Account>()))?
            .contains { $0.userId != userId && !$0.needsReauth } ?? false
    }

    /// Inserts `account` and saves. `userId` is `.unique`, so re-adding an
    /// existing account upserts its row.
    func insert(_ account: Account) throws {
        context.insert(account)
        try context.save()
    }

    /// Deletes `account` and saves.
    func delete(_ account: Account) throws {
        context.delete(account)
        try context.save()
    }

    /// Persists in-place edits to fetched rows (e.g. `needsReauth`).
    func save() throws {
        try context.save()
    }
}
