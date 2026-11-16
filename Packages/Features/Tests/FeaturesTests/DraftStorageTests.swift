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
}
