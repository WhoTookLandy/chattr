import Testing
import Foundation
import TwitchKit
@testable import Features

@Suite("SearchHub (history & browse catalog)")
struct SearchHubTests {

    private func makeDefaults() -> UserDefaults {
        let suite = "chattr.tests.search.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeStream(
        userId: String,
        gameName: String,
        viewers: Int
    ) throws -> TwitchStream {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let json = """
        {
          "id": "stream-\(userId)",
          "userId": "\(userId)",
          "userLogin": "login-\(userId)",
          "userName": "Name-\(userId)",
          "gameId": "1",
          "gameName": "\(gameName)",
          "type": "live",
          "title": "Streaming \(gameName)",
          "tags": [],
          "viewerCount": \(viewers),
          "startedAt": "2026-06-12T14:02:11Z",
          "language": "en",
          "thumbnailUrl": "https://x/live_user_\(userId)-{width}x{height}.jpg",
          "isMature": false
        }
        """
        return try decoder.decode(TwitchStream.self, from: Data(json.utf8))
    }

    // MARK: - SearchHistoryStorage

    @Test("record deduplicates by id, promotes to front, and caps at maxItems")
    func recordDeduplicatesAndCaps() throws {
        let defaults = makeDefaults()
        let account = "acct-1"

        for idx in 1...(SearchHistoryStorage.maxItems + 2) {
            let item = try #require(RecentSearchItem.channel(
                id: "\(idx)",
                login: "Streamer\(idx)",
                displayName: "Streamer\(idx)",
                profileImageURL: nil
            ))
            SearchHistoryStorage.record(item, forAccount: account, defaults: defaults)
        }

        var loaded = SearchHistoryStorage.load(forAccount: account, defaults: defaults)
        #expect(loaded.count == SearchHistoryStorage.maxItems)
        #expect(loaded.first?.login == "streamer10")

        // Recording an existing channel with different casing promotes it to front without duplicating.
        let promoted = try #require(RecentSearchItem.channel(
            id: "5",
            login: "STREAMER5",
            displayName: "Streamer5",
            profileImageURL: URL(string: "https://example.com/5.png")
        ))
        loaded = SearchHistoryStorage.record(promoted, forAccount: account, defaults: defaults)
        #expect(loaded.count == SearchHistoryStorage.maxItems)
        #expect(loaded.first?.login == "streamer5")
        #expect(loaded.first?.profileImageURL == "https://example.com/5.png")
        #expect(loaded.filter { $0.login == "streamer5" }.count == 1)
    }

    @Test("history is scoped per account and remove / clear only touch that account")
    func historyIsAccountScoped() throws {
        let defaults = makeDefaults()
        let ch = try #require(RecentSearchItem.channel(id: "1", login: "caseoh_", displayName: "caseoh_", profileImageURL: nil))
        let cat = try #require(RecentSearchItem.category("Just Chatting"))

        SearchHistoryStorage.record(ch, forAccount: "a", defaults: defaults)
        SearchHistoryStorage.record(cat, forAccount: "a", defaults: defaults)
        SearchHistoryStorage.record(ch, forAccount: "b", defaults: defaults)

        let afterRemove = SearchHistoryStorage.remove(id: cat.id, forAccount: "a", defaults: defaults)
        #expect(afterRemove.map(\.id) == [ch.id])
        #expect(SearchHistoryStorage.load(forAccount: "b", defaults: defaults).map(\.id) == [ch.id])

        SearchHistoryStorage.clear(forAccount: "a", defaults: defaults)
        #expect(SearchHistoryStorage.load(forAccount: "a", defaults: defaults).isEmpty)
        #expect(SearchHistoryStorage.load(forAccount: "b", defaults: defaults).count == 1)
    }

    @Test("empty inputs and blank account ids are ignored safely")
    func ignoresBlankInputs() {
        let defaults = makeDefaults()
        #expect(RecentSearchItem.channel(id: "1", login: "   ", displayName: "x", profileImageURL: nil) == nil)
        #expect(RecentSearchItem.category("  \n ") == nil)

        if let cat = RecentSearchItem.category("Marvel Rivals") {
            let result = SearchHistoryStorage.record(cat, forAccount: "", defaults: defaults)
            #expect(result.isEmpty)
        }
        #expect(SearchHistoryStorage.load(forAccount: "", defaults: defaults).isEmpty)
    }

    // MARK: - SearchBrowseCatalog

    @Test("categories aggregate viewer totals and follow counts sorted by viewers desc")
    func categoriesAggregateAndSort() throws {
        let streams = [
            try makeStream(userId: "1", gameName: "Grand Theft Auto VI", viewers: 85_000),
            try makeStream(userId: "2", gameName: "Just Chatting", viewers: 6_700),
            try makeStream(userId: "3", gameName: "Grand Theft Auto VI", viewers: 10_000),
            try makeStream(userId: "4", gameName: "Marvel Rivals", viewers: 6_700),
            try makeStream(userId: "5", gameName: "Marvel Rivals", viewers: 0),
            try makeStream(userId: "6", gameName: "   ", viewers: 500),
        ]

        let categories = SearchBrowseCatalog.categories(from: streams)
        #expect(categories == [
            SearchCategorySummary(name: "Grand Theft Auto VI", viewerCount: 95_000, liveFollowCount: 2),
            // Tie on 6,700 viewers breaks by liveFollowCount descending (2 > 1).
            SearchCategorySummary(name: "Marvel Rivals", viewerCount: 6_700, liveFollowCount: 2),
            SearchCategorySummary(name: "Just Chatting", viewerCount: 6_700, liveFollowCount: 1),
        ])
    }

    @Test("streams(in:from:) returns all streams for nil and matching game otherwise")
    func streamsFiltering() throws {
        let streams = [
            try makeStream(userId: "1", gameName: "Grand Theft Auto VI", viewers: 85_000),
            try makeStream(userId: "2", gameName: "Just Chatting", viewers: 6_700),
        ]

        #expect(SearchBrowseCatalog.streams(in: nil, from: streams).map(\.userId) == ["1", "2"])
        #expect(SearchBrowseCatalog.streams(in: "Just Chatting", from: streams).map(\.userId) == ["2"])
        #expect(SearchBrowseCatalog.streams(in: "Unknown", from: streams).isEmpty)
    }
}
