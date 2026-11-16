import Testing
import SwiftData
import Foundation
import Core
@testable import Accounts

@Suite("AccountRepository (SwiftData rows)")
@MainActor
struct AccountRepositoryTests {

    private static func makeRepository() throws -> AccountRepository {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Account.self, configurations: config)
        return AccountRepository(modelContainer: container)
    }

    private static func account(_ userId: String, addedAt: Date = .now, needsReauth: Bool = false) -> Account {
        Account(
            userId: userId,
            login: "login\(userId)",
            displayName: "Name\(userId)",
            profileImageURL: "",
            tokenNamespace: "chattr.account.\(userId)",
            addedAt: addedAt,
            needsReauth: needsReauth
        )
    }

    @Test("all() is newest-first")
    func allNewestFirst() throws {
        let repository = try Self.makeRepository()
        try repository.insert(Self.account("old", addedAt: Date(timeIntervalSince1970: 1)))
        try repository.insert(Self.account("new", addedAt: Date(timeIntervalSince1970: 2)))

        #expect(try repository.all().map(\.userId) == ["new", "old"])
    }

    @Test("account(userId:) and login(forUserId:) find a row or return nil")
    func lookups() throws {
        let repository = try Self.makeRepository()
        try repository.insert(Self.account("1"))

        #expect(try repository.account(userId: "1")?.userId == "1")
        #expect(try repository.account(userId: "2") == nil)
        #expect(repository.login(forUserId: "1") == "login1")
        #expect(repository.login(forUserId: "2") == nil)
    }

    @Test("hasHealthyAccount ignores the excluded account and expired ones")
    func healthyFallback() throws {
        let repository = try Self.makeRepository()
        try repository.insert(Self.account("1"))
        try repository.insert(Self.account("2", needsReauth: true))

        #expect(repository.hasHealthyAccount(excluding: "1") == false)
        #expect(repository.hasHealthyAccount(excluding: "2") == true)
    }

    @Test("delete removes the row")
    func deleteRemoves() throws {
        let repository = try Self.makeRepository()
        let row = Self.account("1")
        try repository.insert(row)

        try repository.delete(row)

        #expect(try repository.all().isEmpty)
    }
}
