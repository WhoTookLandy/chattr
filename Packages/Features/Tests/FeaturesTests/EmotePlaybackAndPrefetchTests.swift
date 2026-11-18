import Testing
import Foundation
import Channels
@testable import Features

@Suite("Emote playback under power and heat")
struct EmotePlaybackStoreTests {

    @Test("Emotes animate in normal conditions")
    func animatesNormally() {
        #expect(!EmotePlaybackStore.shouldSuspend(lowPowerMode: false, thermalState: .nominal))
        #expect(!EmotePlaybackStore.shouldSuspend(lowPowerMode: false, thermalState: .fair))
    }

    @Test("Low Power Mode holds emotes on their poster frame")
    func lowPowerSuspends() {
        #expect(EmotePlaybackStore.shouldSuspend(lowPowerMode: true, thermalState: .nominal))
    }

    @Test("A serious or critical thermal state does too")
    func heatSuspends() {
        #expect(EmotePlaybackStore.shouldSuspend(lowPowerMode: false, thermalState: .serious))
        #expect(EmotePlaybackStore.shouldSuspend(lowPowerMode: false, thermalState: .critical))
    }
}

@Suite("Chat image prefetch rules")
struct ChatImagePrefetchRuleTests {

    private func badges(_ keys: [(set: String, id: String)]) -> [ChatBadgeKey: ChatBadgeEntry] {
        var entries: [ChatBadgeKey: ChatBadgeEntry] = [:]
        for key in keys {
            entries[ChatBadgeKey(setId: key.set, id: key.id)] = ChatBadgeEntry(
                url: URL(string: "https://badges.test/\(key.set)/\(key.id)")!, title: nil)
        }
        return entries
    }

    @Test("Only the listed badge sets are picked, in list order, versions in numeric order")
    func commonBadgesOnly() {
        let entries = badges([
            (set: "subscriber", id: "12"), (set: "subscriber", id: "0"), (set: "subscriber", id: "3"),
            (set: "moderator", id: "1"),
            (set: "bits", id: "100"), (set: "some-event-2019", id: "1"),
        ])

        let urls = ChatImagePrefetcher.commonBadgeURLs(in: entries, sets: ["moderator", "subscriber"], limit: 10)

        #expect(urls.map(\.absoluteString) == [
            "https://badges.test/moderator/1",
            "https://badges.test/subscriber/0",
            "https://badges.test/subscriber/3",
            "https://badges.test/subscriber/12",
        ])
    }

    @Test("The count is capped, earlier sets first")
    func commonBadgesAreCapped() {
        let entries = badges([
            (set: "subscriber", id: "0"), (set: "subscriber", id: "3"), (set: "subscriber", id: "6"),
            (set: "moderator", id: "1"),
        ])

        let urls = ChatImagePrefetcher.commonBadgeURLs(in: entries, sets: ["moderator", "subscriber"], limit: 2)

        #expect(urls.map(\.absoluteString) == [
            "https://badges.test/moderator/1",
            "https://badges.test/subscriber/0",
        ])
    }

    @Test("The shipped list is short and bounded")
    func shippedListIsBounded() {
        #expect(ChatImagePrefetcher.commonGlobalBadgeSets.contains("moderator"))
        #expect(ChatImagePrefetcher.commonGlobalBadgeSets.contains("subscriber"))
        #expect(ChatImagePrefetcher.commonGlobalBadgeSets.count <= 16)
        #expect(ChatImagePrefetcher.maxMemoryPrefetchedBadges <= 64)
    }

    @Test("Prefetch requests refuse expensive, constrained and cellular networks")
    func prefetchRequestsStayOffMeteredNetworks() throws {
        let url = try #require(URL(string: "https://static-cdn.jtvnw.net/emoticons/v2/25/static/dark/2.0"))
        let request = ChatImagePrefetcher.prefetchURLRequest(for: url)
        #expect(request.url == url)
        #expect(request.allowsExpensiveNetworkAccess == false)
        #expect(request.allowsConstrainedNetworkAccess == false)
        // Also what keeps a prefetch's download from being shared with an
        // on-screen request for the same URL.
        #expect(request.allowsCellularAccess == false)
    }

    @Test("The subscribed-emote walk runs at most once a day per account")
    func walkIsDueOnceADay() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(ChatImagePrefetcher.isWalkDue(lastWalk: nil, now: now))
        #expect(!ChatImagePrefetcher.isWalkDue(lastWalk: now.addingTimeInterval(-60 * 60), now: now))
        #expect(!ChatImagePrefetcher.isWalkDue(lastWalk: now.addingTimeInterval(-23 * 60 * 60), now: now))
        #expect(ChatImagePrefetcher.isWalkDue(lastWalk: now.addingTimeInterval(-25 * 60 * 60), now: now))
        // A stamp from the future (clock set back) doesn't block it.
        #expect(ChatImagePrefetcher.isWalkDue(lastWalk: now.addingTimeInterval(60 * 60), now: now))
    }
}
