import Foundation
import TwitchKit

/// Summary of one category currently represented by the user's live follows.
struct SearchCategorySummary: Identifiable, Equatable, Sendable {
    let name: String
    let viewerCount: Int
    let liveFollowCount: Int

    var id: String { name }
}

/// Pure helpers that aggregate live followed streams into browse categories
/// and filter them by category for the Search tab's zero-state hub and
/// category drill-down screen.
enum SearchBrowseCatalog {

    /// Categories your live follows are currently streaming, ordered by total
    /// viewers descending (ties break by live-follow count, then name).
    static func categories(from streams: [TwitchStream]) -> [SearchCategorySummary] {
        var totals: [String: (viewers: Int, follows: Int)] = [:]
        for stream in streams {
            let name = stream.gameName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            var current = totals[name] ?? (0, 0)
            current.viewers += max(0, stream.viewerCount)
            current.follows += 1
            totals[name] = current
        }

        return totals
            .map { SearchCategorySummary(name: $0.key, viewerCount: $0.value.viewers, liveFollowCount: $0.value.follows) }
            .sorted { lhs, rhs in
                if lhs.viewerCount != rhs.viewerCount {
                    return lhs.viewerCount > rhs.viewerCount
                }
                if lhs.liveFollowCount != rhs.liveFollowCount {
                    return lhs.liveFollowCount > rhs.liveFollowCount
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    /// Filter `streams` to a selected category (`nil` = all streams).
    static func streams(in category: String?, from streams: [TwitchStream]) -> [TwitchStream] {
        guard let category else { return streams }
        let target = category.trimmingCharacters(in: .whitespacesAndNewlines)
        return streams.filter { $0.gameName.trimmingCharacters(in: .whitespacesAndNewlines) == target }
    }
}
