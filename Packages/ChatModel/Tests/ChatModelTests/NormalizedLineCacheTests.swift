import Testing
import Foundation
@testable import ChatModel

@MainActor
@Suite("NormalizedLineCache")
struct NormalizedLineCacheTests {

    private func line(_ id: String, body: String = "hello") -> ChatLine {
        // Fixed timestamp: the helper is called twice per assertion (store
        // + expected), and ChatLine equality includes the timestamp.
        ChatLine(
            id: id,
            authorDisplayName: "tester",
            runs: [.text(body)],
            timestamp: Date(timeIntervalSinceReferenceDate: 0)
        )
    }

    private func context(
        emoteVersion: Int = 0,
        login: String = "me",
        keywords: [String] = []
    ) -> NormalizedLineCache.Context {
        NormalizedLineCache.Context(
            emoteVersion: emoteVersion,
            currentUserLogin: login,
            highlightKeywords: keywords
        )
    }

    @Test("Stored lines come back under the same context")
    func roundTrip() {
        let cache = NormalizedLineCache(capacity: 10)
        let ctx = context()
        cache.store(line("m1"), context: ctx)
        #expect(cache.line(id: "m1", context: ctx) == line("m1"))
        #expect(cache.line(id: "absent", context: ctx) == nil)
    }

    @Test("A context change (emote index loaded) invalidates everything")
    func contextChangeWipes() {
        let cache = NormalizedLineCache(capacity: 10)
        cache.store(line("m1"), context: context(emoteVersion: 0))
        let loaded = context(emoteVersion: 3000)
        #expect(cache.line(id: "m1", context: loaded) == nil)
        // Storing under the new context resets the cache to it.
        cache.store(line("m1", body: "with emotes"), context: loaded)
        #expect(cache.line(id: "m1", context: loaded) == line("m1", body: "with emotes"))
        // The old context no longer hits either.
        #expect(cache.line(id: "m1", context: context(emoteVersion: 0)) == nil)
    }

    @Test("Changed highlight keywords invalidate cached highlighting")
    func keywordChangeWipes() {
        let cache = NormalizedLineCache(capacity: 10)
        cache.store(line("m1"), context: context(keywords: []))
        #expect(cache.line(id: "m1", context: context(keywords: ["pog"])) == nil)
    }

    @Test("Capacity evicts oldest-first")
    func fifoEviction() {
        let cache = NormalizedLineCache(capacity: 3)
        let ctx = context()
        for i in 1...4 { cache.store(line("m\(i)"), context: ctx) }
        #expect(cache.line(id: "m1", context: ctx) == nil)        // evicted
        #expect(cache.line(id: "m2", context: ctx) != nil)
        #expect(cache.line(id: "m4", context: ctx) != nil)
    }

    @Test("Re-storing an existing id updates in place without double-counting")
    func updateInPlace() {
        let cache = NormalizedLineCache(capacity: 2)
        let ctx = context()
        cache.store(line("m1"), context: ctx)
        cache.store(line("m1", body: "upgraded"), context: ctx)   // echo upgrade shape
        cache.store(line("m2"), context: ctx)
        // m1 was stored twice but occupies one slot — both ids still fit.
        #expect(cache.line(id: "m1", context: ctx) == line("m1", body: "upgraded"))
        #expect(cache.line(id: "m2", context: ctx) != nil)
    }
}
