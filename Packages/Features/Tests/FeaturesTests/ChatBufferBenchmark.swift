import Testing
import Foundation
import ChatModel
@testable import Features

/// Micro-benchmark substantiating the model-layer hot-path win under a
/// synthetic raid: many messages/sec into a full 500-line buffer, with a
/// blocked user present (the case that used to pay a full `BlockFilter.apply`
/// rescan + allocation on every single message).
///
/// This is a relative comparison, not an Instruments trace — it reconstructs
/// the OLD approach (a plain array + per-message full filter + front
/// `removeFirst`) and races it against the new `ChatBuffer` over the same
/// event stream. The assertion margin is deliberately loose so the test isn't
/// flaky on a busy CI; the *printed ratio* is the interesting artifact.
@Suite("ChatBuffer raid benchmark")
struct ChatBufferBenchmark {

    private func line(_ i: Int) -> ChatLine {
        // Every 7th message is from the blocked author, so the filter actually
        // has work to do (mirrors a spammer being blocked mid-raid).
        let author = i % 7 == 0 ? "villain" : "user\(i % 50)"
        return ChatLine(id: "m\(i)", kind: .message, authorUserId: author,
                        authorDisplayName: author, runs: [.text("msg \(i)")])
    }

    /// The pre-refactor per-message work, reconstructed for comparison.
    private func oldApproach(messageCount: Int, cap: Int, blocked: Set<String>) -> Int {
        var all: [ChatLine] = []
        var visible: [ChatLine] = []
        for i in 0..<messageCount {
            all.append(line(i))
            if all.count > cap { all.removeFirst(all.count - cap) }
            // rebuildLines(): full re-filter + allocation, every message.
            visible = blocked.isEmpty ? all : all.filter { !blocked.contains($0.authorUserId) }
        }
        return visible.count
    }

    private func newApproach(messageCount: Int, cap: Int, blocked: Set<String>) -> Int {
        var buffer = ChatBuffer(cap: cap)
        buffer.blockedIds = blocked
        for i in 0..<messageCount { buffer.append(line(i)) }
        return buffer.lines.count
    }

    @Test("ChatBuffer is faster than the old full-rescan approach under a raid")
    func raidThroughput() {
        let messageCount = 20_000
        let cap = 500
        let blocked: Set<String> = ["villain"]
        let clock = ContinuousClock()

        // Warm + correctness: both produce the same visible count.
        let oldCount = oldApproach(messageCount: messageCount, cap: cap, blocked: blocked)
        let newCount = newApproach(messageCount: messageCount, cap: cap, blocked: blocked)
        #expect(oldCount == newCount)

        let oldTime = clock.measure { _ = oldApproach(messageCount: messageCount, cap: cap, blocked: blocked) }
        let newTime = clock.measure { _ = newApproach(messageCount: messageCount, cap: cap, blocked: blocked) }

        let oldMs = Double(oldTime.components.attoseconds) / 1e15
        let newMs = Double(newTime.components.attoseconds) / 1e15
        let speedup = oldMs / max(newMs, 0.0001)
        Comment.record("raid \(messageCount) msgs @ cap \(cap), 1 blocked author")
        Comment.record(String(format: "old (full rescan/msg): %.1f ms", oldMs))
        Comment.record(String(format: "new (ChatBuffer):       %.1f ms  (%.1fx faster)", newMs, speedup))

        // Loose guard: the incremental buffer must not be slower than the
        // per-message full rescan. (In practice it's many times faster.)
        #expect(newMs <= oldMs)
    }
}

private enum Comment {
    static func record(_ message: String) {
        // Surfaced via the test runner's stdout so the numbers show in CI logs.
        print("⏱  \(message)")
    }
}
