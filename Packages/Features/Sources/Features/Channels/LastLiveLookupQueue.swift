import Foundation

/// The waiting line behind `ChannelStatusStore`'s last-live lookups.
///
/// Rows only ask ("look this channel up"); the store drains the line a few
/// lookups at a time. Three rules keep a fast scroll through a long roster
/// cheap:
///
///   - a channel is in the line (waiting or running) at most once;
///   - the newest request is served first — it is the row on screen;
///   - the line is bounded: when it overflows, the oldest waiting request is
///     dropped (its row asks again if it comes back on screen).
struct LastLiveLookupQueue {
    /// How many lookups may run at once.
    let concurrency: Int
    /// How many requests may wait.
    let capacity: Int

    /// Waiting channel ids, oldest request first.
    private(set) var waiting: [String] = []
    /// Channel ids whose lookup is running.
    private(set) var running: Set<String> = []
    private var waitingIds: Set<String> = []

    init(concurrency: Int = 3, capacity: Int = 30) {
        self.concurrency = concurrency
        self.capacity = capacity
    }

    /// Adds `channelId` to the line. Returns false (and changes nothing)
    /// when it is already waiting or running.
    @discardableResult
    mutating func enqueue(_ channelId: String) -> Bool {
        guard !running.contains(channelId), waitingIds.insert(channelId).inserted else { return false }
        waiting.append(channelId)
        if waiting.count > capacity {
            waitingIds.remove(waiting.removeFirst())
        }
        return true
    }

    /// Takes the next channel to look up and counts it as running. Nil when
    /// nothing waits or `concurrency` lookups already run.
    mutating func startNext() -> String? {
        guard running.count < concurrency, let channelId = waiting.popLast() else { return nil }
        waitingIds.remove(channelId)
        running.insert(channelId)
        return channelId
    }

    /// Marks `channelId`'s lookup finished, freeing its slot.
    mutating func finish(_ channelId: String) {
        running.remove(channelId)
    }
}
