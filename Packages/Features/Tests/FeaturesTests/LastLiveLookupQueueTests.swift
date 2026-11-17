import Testing
import Foundation
@testable import Features

/// The waiting line behind `ChannelStatusStore`'s last-live lookups.
@Suite("LastLiveLookupQueue")
struct LastLiveLookupQueueTests {

    /// Starts lookups until the queue hands out no more.
    private func drainStarts(_ queue: inout LastLiveLookupQueue) -> [String] {
        var started: [String] = []
        while let id = queue.startNext() { started.append(id) }
        return started
    }

    @Test("Runs at most `concurrency` lookups at once")
    func boundedConcurrency() {
        var queue = LastLiveLookupQueue(concurrency: 3, capacity: 30)
        for id in ["a", "b", "c", "d", "e"] { queue.enqueue(id) }

        let firstWave = drainStarts(&queue)
        #expect(firstWave.count == 3)
        #expect(queue.running == Set(firstWave))
        #expect(queue.waiting.count == 2)

        // Finishing one frees exactly one slot.
        queue.finish(firstWave[0])
        let secondWave = drainStarts(&queue)
        #expect(secondWave.count == 1)
        #expect(queue.running.count == 3)
    }

    @Test("The newest request is served first")
    func newestFirst() {
        var queue = LastLiveLookupQueue(concurrency: 1, capacity: 30)
        for id in ["a", "b", "c"] { queue.enqueue(id) }

        var order: [String] = []
        while let id = queue.startNext() {
            order.append(id)
            queue.finish(id)
        }
        #expect(order == ["c", "b", "a"])
    }

    @Test("A channel is waiting or running at most once")
    func deduplicates() {
        var queue = LastLiveLookupQueue(concurrency: 1, capacity: 30)
        let first = queue.enqueue("a")
        let repeated = queue.enqueue("a")
        #expect(first)
        #expect(!repeated)
        #expect(queue.waiting == ["a"])

        // Still running: asking again doesn't queue a second lookup.
        let started = drainStarts(&queue)
        let whileRunning = queue.enqueue("a")
        #expect(started == ["a"])
        #expect(!whileRunning)
        #expect(queue.waiting.isEmpty)

        // Once finished it can be asked for again.
        queue.finish("a")
        let afterFinish = queue.enqueue("a")
        #expect(afterFinish)
    }

    @Test("Overflow drops the oldest waiting request, which may ask again")
    func bounded() {
        var queue = LastLiveLookupQueue(concurrency: 1, capacity: 2)
        for id in ["a", "b", "c"] { queue.enqueue(id) }
        #expect(queue.waiting == ["b", "c"])

        let readded = queue.enqueue("a")
        #expect(readded)
        #expect(queue.waiting == ["c", "a"])
    }
}
