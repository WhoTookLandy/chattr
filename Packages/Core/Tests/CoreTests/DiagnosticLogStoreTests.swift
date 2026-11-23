import Foundation
import Testing
@testable import Core

@Suite("DiagnosticLogStore")
struct DiagnosticLogStoreTests {

    @Test("AppLogMessage redacts .private and .sensitive, preserves .public and unannotated")
    func messagePrivacyRedaction() {
        let user = "xqc"
        let token = "secret-oauth-token"
        let count = 42
        let msg: AppLogMessage = "user=\(user, privacy: .public) token=\(token, privacy: .private) pin=\("1234", privacy: .sensitive) count=\(count)"
        #expect(msg.text == "user=xqc token=<private> pin=<private> count=42")
    }

    @Test("in-memory ring buffer returns newest-first and evicts oldest past capacity")
    func ringBufferWrapAndOrder() {
        let store = DiagnosticLogStore(capacity: 3, directory: nil)
        store.record(level: .info, category: "Cat", message: "one")
        store.record(level: .info, category: "Cat", message: "two")
        store.record(level: .info, category: "Cat", message: "three")
        store.record(level: .info, category: "Cat", message: "four")

        let entries = store.entries(limit: 10, minLevel: .debug)
        #expect(entries.map(\.composedMessage) == ["four", "three", "two"])
        // Distinct monotonic IDs even for entries logged in the same instant.
        #expect(Set(entries.map(\.id)).count == 3)
    }

    @Test("minLevel filters entries by severity")
    func severityFiltering() {
        let store = DiagnosticLogStore(capacity: 10, directory: nil)
        store.record(level: .debug, category: "A", message: "d")
        store.record(level: .info, category: "A", message: "i")
        store.record(level: .notice, category: "A", message: "n")
        store.record(level: .warning, category: "A", message: "w")
        store.record(level: .error, category: "A", message: "e")

        #expect(store.entries(limit: 10, minLevel: .warning).map(\.composedMessage) == ["e", "w"])
        #expect(store.entries(limit: 10, minLevel: .info).map(\.composedMessage) == ["e", "w", "n", "i"])
        #expect(store.entries(limit: 2, minLevel: .debug).map(\.composedMessage) == ["e", "w"])
    }

    @Test("formatChronological outputs oldest-first lines and collapses newlines")
    func chronologicalFormatting() {
        let store = DiagnosticLogStore(capacity: 10, directory: nil)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let t1 = Date(timeIntervalSince1970: 1_700_000_001)
        store.record(level: .info, category: "Chat", message: "first\nline", date: t0)
        store.record(level: .error, category: "Net", message: "second", date: t1)

        let text = DiagnosticLogStore.formatChronological(store.entries(limit: 10, minLevel: .debug))
        let lines = text.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].contains("[INFO] [Chat] first line"))
        #expect(lines[1].contains("[ERROR] [Net] second"))
    }

    @Test("disk persistence rotates prior run into previous.log on next session")
    func diskRotationAcrossLaunches() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chattr-diag-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let run1 = DiagnosticLogStore(capacity: 10, directory: tempDir, maxFileBytes: 64 * 1024)
        run1.record(level: .notice, category: "App", message: "run-1-hello")
        run1.flush()

        let run2 = DiagnosticLogStore(capacity: 10, directory: tempDir, maxFileBytes: 64 * 1024)
        let previous = run2.previousSessionLog()
        #expect(previous?.contains("run-1-hello") == true)

        run2.clear()
        #expect(run2.entries().isEmpty)
        #expect(run2.previousSessionLog() == nil)
    }

    @Test("disk persistence rotates mid-session when maxFileBytes is exceeded")
    func midSessionDiskRotation() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chattr-diag-rotate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = DiagnosticLogStore(capacity: 100, directory: tempDir, maxFileBytes: 1_024)
        let payload = String(repeating: "x", count: 300)
        for i in 0..<6 {
            store.record(level: .info, category: "Burst", message: "msg-\(i)-\(payload)")
        }
        store.flush()

        let previous = store.previousSessionLog()
        #expect(previous != nil)
        #expect(previous?.contains("msg-0-") == true)
    }
}
