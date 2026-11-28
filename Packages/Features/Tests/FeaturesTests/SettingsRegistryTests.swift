import Testing
@testable import Features

/// The static settings index behind the Settings root's category rows and
/// search.
@Suite("SettingsRegistry")
struct SettingsRegistryTests {

    @Test("Entry ids are unique")
    func uniqueIds() {
        let ids = SettingsRegistry.entries.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("Every category has at least one entry")
    func everyCategoryPopulated() {
        for category in SettingsCategory.allCases {
            #expect(SettingsRegistry.entries.contains { $0.category == category }, "\(category) has no entries")
        }
    }

    @Test("Blank query returns nothing")
    func blankQuery() {
        #expect(SettingsRegistry.search("").isEmpty)
        #expect(SettingsRegistry.search("   ").isEmpty)
    }

    @Test("Matches titles case-insensitively")
    func matchesTitle() {
        let ids = SettingsRegistry.search("TIMESTAMPS").map(\.id)
        #expect(ids.contains("timestamps"))
    }

    @Test("Matches keywords, not just titles")
    func matchesKeyword() {
        #expect(SettingsRegistry.search("7tv").map(\.id).contains("emoteSources"))
        #expect(SettingsRegistry.search("pip").map(\.id).contains("nativePlayer"))
        #expect(SettingsRegistry.search("dark mode").map(\.id).contains("theme"))
    }

    @Test("Playback and device settings are findable by their synonyms")
    func playbackDeviceKeywords() {
        #expect(SettingsRegistry.search("sleep").map(\.id).contains("keepScreenAwake"))
        #expect(SettingsRegistry.search("lock").map(\.id).contains("keepScreenAwake"))
        #expect(SettingsRegistry.search("pip").map(\.id).contains("pictureInPicture"))
        #expect(SettingsRegistry.search("autoplay").map(\.id).contains("videoOnOpen"))
        #expect(SettingsRegistry.search("home preview").map(\.id).contains("homeLivePreviews"))
        #expect(SettingsRegistry.search("low latency").map(\.id).contains("lowLatency"))
        #expect(SettingsRegistry.search("delay").map(\.id).contains("lowLatency"))
        #expect(SettingsRegistry.search("mixer").map(\.id).contains("backgroundAudioIndicator"))
        #expect(SettingsRegistry.search("wifi").map(\.id).contains("videoOnOpen"))
        #expect(SettingsRegistry.search("vibration").map(\.id).contains("haptics"))
    }

    @Test("Live-event banner toggles are findable and point at Filters")
    func liveEventBanners() {
        #expect(SettingsRegistry.search("vote").map(\.id).contains("livePolls"))
        #expect(SettingsRegistry.search("bet").map(\.id).contains("livePredictions"))
        #expect(SettingsRegistry.search("hype train").map(\.id).contains("liveHypeTrain"))
        let banners = Set(SettingsRegistry.search("banner").map(\.id))
        #expect(banners.isSuperset(of: ["livePolls", "livePredictions", "liveHypeTrain"]))
        let byId = Dictionary(uniqueKeysWithValues: SettingsRegistry.entries.map { ($0.id, $0) })
        #expect(byId["livePolls"]?.breadcrumb == "Chat › Filters")
    }

    @Test("Every term must match")
    func allTermsMustMatch() {
        let ids = SettingsRegistry.search("hide bots").map(\.id)
        #expect(ids.contains("hideBots"))
        #expect(!ids.contains("hideCommands"))
    }

    @Test("Diacritics are ignored")
    func diacriticInsensitive() {
        #expect(SettingsRegistry.search("thème").map(\.id).contains("theme"))
    }

    @Test("Breadcrumb names the deeper screen only when it adds information")
    func breadcrumbs() {
        let byId = Dictionary(uniqueKeysWithValues: SettingsRegistry.entries.map { ($0.id, $0) })
        #expect(byId["hideBots"]?.breadcrumb == "Chat › Filters")
        #expect(byId["filters"]?.breadcrumb == "Chat")
        #expect(byId["theme"]?.breadcrumb == "Appearance")
        #expect(byId["landscapeLayout"]?.breadcrumb == "Video & Device")
        #expect(byId["landscapeChatSide"]?.breadcrumb == "Video & Device › Landscape Layout")
    }

    @Test("Landscape settings are found from Video & Device")
    func landscapeEntries() {
        let ids = SettingsRegistry.search("landscape").map(\.id)
        #expect(ids.contains("landscapeLayout"))
        #expect(ids.contains("landscapeChatSide"))
        #expect(ids.contains("landscapeChatOpacity"))
        #expect(ids.contains("landscapeResetWidth"))
        #expect(SettingsRegistry.search("opacity").map(\.id).contains("landscapeChatOpacity"))
    }
}
