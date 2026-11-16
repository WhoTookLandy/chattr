import Testing
import Foundation
@testable import Channels

/// The CR MEDIUM 4 guard in isolation: a start-time Helix snapshot may seed
/// the cache, but never overwrite a live update.
@Suite("ChatRestrictionsCache")
struct ChatRestrictionsCacheTests {

    @Test("Starts empty and not live")
    func startsEmpty() {
        let cache = ChatRestrictionsCache()
        #expect(cache.value == nil)
        #expect(!cache.isLive)
    }

    @Test("An initial snapshot seeds an empty cache")
    func initialSeeds() {
        var cache = ChatRestrictionsCache()
        let committed = cache.applyInitial(ChatRestrictions(slowModeSeconds: 30))
        #expect(committed)
        #expect(cache.value == ChatRestrictions(slowModeSeconds: 30))
        #expect(!cache.isLive)
    }

    @Test("A later initial snapshot replaces an earlier one while not live")
    func initialReplacesInitial() {
        var cache = ChatRestrictionsCache()
        _ = cache.applyInitial(ChatRestrictions(slowModeSeconds: 30))
        let committed = cache.applyInitial(ChatRestrictions(emoteOnly: true))
        #expect(committed)
        #expect(cache.value == ChatRestrictions(emoteOnly: true))
    }

    @Test("Once live, an initial snapshot is refused and the live value kept")
    func liveWinsOverInitial() {
        var cache = ChatRestrictionsCache()
        cache.applyLive(ChatRestrictions(followersOnly: true))
        let committed = cache.applyInitial(ChatRestrictions(slowModeSeconds: 5))
        #expect(!committed)
        #expect(cache.value == ChatRestrictions(followersOnly: true))
        #expect(cache.isLive)
    }

    @Test("Live updates always replace the value")
    func liveReplacesLive() {
        var cache = ChatRestrictionsCache()
        cache.applyLive(ChatRestrictions(followersOnly: true))
        cache.applyLive(ChatRestrictions(subscribersOnly: true))
        #expect(cache.value == ChatRestrictions(subscribersOnly: true))
    }
}
