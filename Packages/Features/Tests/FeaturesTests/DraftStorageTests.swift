import Testing
import Foundation
import Core
@testable import Features

/// `DraftStorage` debouncing and pruning. Uses `UserDefaults.standard` (what
/// the type is hard-wired to), so every test uses fresh channel ids and
/// removes what it wrote.
@MainActor
@Suite("DraftStorage")
struct DraftStorageTests {
    private func channel() -> ChannelDescriptor {
        let id = "drafttest-\(UUID().uuidString)"
        return ChannelDescriptor(
            channelId: id, channelLoginName: id,
            channelDisplayName: id, profileImageURL: nil
        )
    }

    @Test("scheduleSave defers the write until a flush")
    func scheduleSaveDefers() {
        let id = channel().id
        defer { DraftStorage.remove(forChannels: [id]) }

        DraftStorage.scheduleSave(forChannel: id, text: "hello")
        #expect(DraftStorage.load(forChannel: id) == "")

        DraftStorage.flushPendingSaves()
        #expect(DraftStorage.load(forChannel: id) == "hello")
    }

    @Test("Only the latest scheduled text is written")
    func latestTextWins() {
        let id = channel().id
        defer { DraftStorage.remove(forChannels: [id]) }

        DraftStorage.scheduleSave(forChannel: id, text: "h")
        DraftStorage.scheduleSave(forChannel: id, text: "he")
        DraftStorage.scheduleSave(forChannel: id, text: "hey")
        DraftStorage.flushPendingSaves()
        #expect(DraftStorage.load(forChannel: id) == "hey")

        // Whitespace-only still means "no draft".
        DraftStorage.scheduleSave(forChannel: id, text: "  ")
        DraftStorage.flushPendingSaves()
        #expect(DraftStorage.load(forChannel: id) == "")
    }

    @Test("The debounce timer writes once typing pauses")
    func timerFlushes() async throws {
        let id = channel().id
        defer { DraftStorage.remove(forChannels: [id]) }

        DraftStorage.scheduleSave(forChannel: id, text: "later")
        // Generous upper bound over the 400ms window to stay CI-tolerant.
        for _ in 0..<30 where DraftStorage.load(forChannel: id).isEmpty {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(DraftStorage.load(forChannel: id) == "later")
    }

    @Test("clear drops a pending save so it can't resurrect the draft")
    func clearDropsPending() {
        let id = channel().id
        defer { DraftStorage.remove(forChannels: [id]) }

        DraftStorage.save(forChannel: id, text: "sent")
        DraftStorage.scheduleSave(forChannel: id, text: "sent")
        DraftStorage.clear(forChannel: id)
        DraftStorage.flushPendingSaves()
        #expect(DraftStorage.load(forChannel: id) == "")
    }

    @Test("remove prunes stored and pending drafts")
    func removePrunes() {
        let stored = channel().id
        let pending = channel().id
        DraftStorage.save(forChannel: stored, text: "a")
        DraftStorage.scheduleSave(forChannel: pending, text: "b")

        DraftStorage.remove(forChannels: [stored, pending])
        DraftStorage.flushPendingSaves()
        #expect(DraftStorage.load(forChannel: stored) == "")
        #expect(DraftStorage.load(forChannel: pending) == "")
    }

    // MARK: - Account scoping
    //
    // These switch the process-wide active account, so each one is fully
    // synchronous (no suspension point for another @MainActor test to run
    // in) and resets the scope to nil before returning. They use
    // `setActiveAccount`, never `activate`, so they don't migrate the
    // legacy dictionary other tests are writing to.

    private func account() -> String {
        "drafttest-account-\(UUID().uuidString)"
    }

    @Test("Drafts are scoped to the active account")
    func scopedByAccount() {
        let id = channel().id
        let a = account()
        let b = account()
        defer {
            DraftStorage.setActiveAccount(nil)
            DraftStorage.removeAll(forAccount: a)
            DraftStorage.removeAll(forAccount: b)
        }

        DraftStorage.setActiveAccount(a)
        DraftStorage.save(forChannel: id, text: "from A")

        DraftStorage.setActiveAccount(b)
        #expect(DraftStorage.load(forChannel: id) == "")
        DraftStorage.save(forChannel: id, text: "from B")

        DraftStorage.setActiveAccount(a)
        #expect(DraftStorage.load(forChannel: id) == "from A")

        DraftStorage.setActiveAccount(nil)
        #expect(DraftStorage.load(forChannel: id) == "")
    }

    @Test("A pending save lands in the account it was typed under")
    func pendingKeepsItsAccount() {
        let id = channel().id
        let a = account()
        let b = account()
        defer {
            DraftStorage.setActiveAccount(nil)
            DraftStorage.removeAll(forAccount: a)
            DraftStorage.removeAll(forAccount: b)
        }

        DraftStorage.setActiveAccount(a)
        DraftStorage.scheduleSave(forChannel: id, text: "typed under A")
        DraftStorage.setActiveAccount(b)
        DraftStorage.flushPendingSaves()

        #expect(DraftStorage.load(forChannel: id) == "")
        DraftStorage.setActiveAccount(a)
        #expect(DraftStorage.load(forChannel: id) == "typed under A")
    }

    @Test("removeAll(forAccount:) drops stored and pending drafts")
    func removeAllForAccount() {
        let stored = channel().id
        let pending = channel().id
        let a = account()
        defer { DraftStorage.setActiveAccount(nil) }

        DraftStorage.setActiveAccount(a)
        DraftStorage.save(forChannel: stored, text: "a")
        DraftStorage.scheduleSave(forChannel: pending, text: "b")

        DraftStorage.removeAll(forAccount: a)
        DraftStorage.flushPendingSaves()

        #expect(DraftStorage.load(forChannel: stored) == "")
        #expect(DraftStorage.load(forChannel: pending) == "")
        #expect(UserDefaults.standard.object(forKey: DraftStorage.storageKey(forAccount: a)) == nil)
    }

    @Test("Legacy drafts migrate into the first account, keeping its own on conflict")
    func legacyMigration() throws {
        let suite = "chattr.tests.drafts.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = DraftStorage.storageKey(forAccount: "first")
        defaults.set(["twitch/1": "legacy", "twitch/2": "old"], forKey: DraftStorage.legacyStorageKey)
        defaults.set(["twitch/2": "newer"], forKey: first)

        DraftStorage.migrateLegacyDrafts(toAccount: "first", defaults: defaults)

        #expect(defaults.dictionary(forKey: first) as? [String: String] == ["twitch/1": "legacy", "twitch/2": "newer"])
        #expect(defaults.object(forKey: DraftStorage.legacyStorageKey) == nil)

        // Nothing left for a later account to adopt.
        DraftStorage.migrateLegacyDrafts(toAccount: "second", defaults: defaults)
        #expect(defaults.object(forKey: DraftStorage.storageKey(forAccount: "second")) == nil)
    }
}
