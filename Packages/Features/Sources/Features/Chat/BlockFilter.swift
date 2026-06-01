import ChatModel

/// Pure, kind-agnostic chat-line filter for blocked users.
///
/// Keys solely on `ChatLine.authorUserId`, which the Normalizer populates for
/// every line kind — so a blocked user's messages AND their sub/raid bubbles all
/// drop with one predicate, no per-kind special-casing. Static + pure so it's
/// unit-testable without a model or view.
enum BlockFilter {
    static func apply(lines: [ChatLine], blockedIds: Set<String>) -> [ChatLine] {
        guard !blockedIds.isEmpty else { return lines }
        return lines.filter { !blockedIds.contains($0.authorUserId) }
    }
}
