import Testing
import Foundation
@testable import Features

@Suite("ChatAppearance legacy text-size migration")
struct ChatAppearanceMigrationTests {

    /// Isolated defaults so tests can't read/write the real app domain.
    private func makeDefaults() -> UserDefaults {
        let suite = "test.chatAppearance.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("Legacy steps map to their text style's point size", arguments: [
        ("small", 13.0), ("standard", 16.0), ("large", 17.0), ("extraLarge", 20.0),
    ])
    func mapsLegacyStep(raw: String, expected: Double) {
        let defaults = makeDefaults()
        defaults.set(raw, forKey: ChatAppearance.legacyTextSizeKey)
        ChatAppearance.migrateLegacyTextSizeIfNeeded(defaults: defaults)
        #expect(defaults.double(forKey: ChatAppearance.textSizePointsKey) == expected)
    }

    @Test("An existing slider value is never overwritten")
    func respectsExistingPoints() {
        let defaults = makeDefaults()
        defaults.set(21.0, forKey: ChatAppearance.textSizePointsKey)
        defaults.set("small", forKey: ChatAppearance.legacyTextSizeKey)
        ChatAppearance.migrateLegacyTextSizeIfNeeded(defaults: defaults)
        #expect(defaults.double(forKey: ChatAppearance.textSizePointsKey) == 21.0)
    }

    @Test("No legacy value means no write — the default stays live")
    func noLegacyNoWrite() {
        let defaults = makeDefaults()
        ChatAppearance.migrateLegacyTextSizeIfNeeded(defaults: defaults)
        #expect(defaults.object(forKey: ChatAppearance.textSizePointsKey) == nil)
    }
}

@Suite("ChatAppearance chat-history setting")
struct ChatHistorySettingTests {

    private func makeDefaults() -> UserDefaults {
        let suite = "test.chatHistory.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("Unset falls back to the default")
    func unsetDefaults() {
        #expect(ChatAppearance.chatHistoryLines(defaults: makeDefaults())
                == ChatAppearance.defaultChatHistoryLines)
    }

    @Test("A stored option is returned as-is")
    func storedOption() {
        let defaults = makeDefaults()
        defaults.set(2000, forKey: ChatAppearance.chatHistoryLinesKey)
        #expect(ChatAppearance.chatHistoryLines(defaults: defaults) == 2000)
    }

    @Test("Out-of-range values fall back to the default")
    func outOfRange() {
        let defaults = makeDefaults()
        defaults.set(123_456, forKey: ChatAppearance.chatHistoryLinesKey)
        #expect(ChatAppearance.chatHistoryLines(defaults: defaults)
                == ChatAppearance.defaultChatHistoryLines)
    }
}
