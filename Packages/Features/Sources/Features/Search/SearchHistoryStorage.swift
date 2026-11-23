import Foundation

/// What a saved recent-search entry represents.
enum RecentSearchKind: String, Codable, Equatable, Sendable {
    case channel
    case category
}

/// One entry in Search's per-account "Recent Searches" list.
///
/// Channel entries keep the resolved `channelId` and `profileImageURL` so
/// tapping a recent channel opens its chat tab immediately without another
/// Helix lookup. Category entries jump straight to the category's live follows.
struct RecentSearchItem: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let kind: RecentSearchKind
    let title: String
    let login: String?
    let channelId: String?
    let profileImageURL: String?
    let updatedAt: Date

    /// Build a recent channel entry. Returns nil when `login` is empty.
    static func channel(
        id channelId: String,
        login: String,
        displayName: String,
        profileImageURL: URL?,
        now: Date = Date()
    ) -> RecentSearchItem? {
        let normalizedLogin = login.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedLogin.isEmpty else { return nil }
        let trimmedTitle = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return RecentSearchItem(
            id: "channel:\(normalizedLogin)",
            kind: .channel,
            title: trimmedTitle.isEmpty ? normalizedLogin : trimmedTitle,
            login: normalizedLogin,
            channelId: channelId.isEmpty ? nil : channelId,
            profileImageURL: profileImageURL?.absoluteString,
            updatedAt: now
        )
    }

    /// Build a recent category entry. Returns nil when `name` is empty.
    static func category(_ name: String, now: Date = Date()) -> RecentSearchItem? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return RecentSearchItem(
            id: "category:\(trimmed.lowercased())",
            kind: .category,
            title: trimmed,
            login: nil,
            channelId: nil,
            profileImageURL: nil,
            updatedAt: now
        )
    }
}

/// Per-account recent-search persistence backed by `UserDefaults`.
///
/// Follows the same lightweight storage pattern as `DraftStorage`: small,
/// non-sensitive UI history scoped per account (`accountUserId`) and cleared
/// by `AccountLocalData.remove` when an account is removed.
enum SearchHistoryStorage {

    /// Maximum entries kept per account.
    static let maxItems = 8

    static func storageKey(forAccount accountUserId: String) -> String {
        "chattr.search.recents.\(accountUserId)"
    }

    static func load(
        forAccount accountUserId: String,
        defaults: UserDefaults = .standard
    ) -> [RecentSearchItem] {
        guard !accountUserId.isEmpty,
              let data = defaults.data(forKey: storageKey(forAccount: accountUserId)) else {
            return []
        }
        return (try? JSONDecoder().decode([RecentSearchItem].self, from: data)) ?? []
    }

    @discardableResult
    static func record(
        _ item: RecentSearchItem,
        forAccount accountUserId: String,
        defaults: UserDefaults = .standard
    ) -> [RecentSearchItem] {
        guard !accountUserId.isEmpty else { return [] }
        var items = load(forAccount: accountUserId, defaults: defaults)
        items.removeAll { $0.id == item.id }
        items.insert(item, at: 0)
        if items.count > maxItems {
            items = Array(items.prefix(maxItems))
        }
        save(items, forAccount: accountUserId, defaults: defaults)
        return items
    }

    @discardableResult
    static func remove(
        id: String,
        forAccount accountUserId: String,
        defaults: UserDefaults = .standard
    ) -> [RecentSearchItem] {
        guard !accountUserId.isEmpty else { return [] }
        var items = load(forAccount: accountUserId, defaults: defaults)
        items.removeAll { $0.id == id }
        if items.isEmpty {
            defaults.removeObject(forKey: storageKey(forAccount: accountUserId))
        } else {
            save(items, forAccount: accountUserId, defaults: defaults)
        }
        return items
    }

    static func clear(
        forAccount accountUserId: String,
        defaults: UserDefaults = .standard
    ) {
        guard !accountUserId.isEmpty else { return }
        defaults.removeObject(forKey: storageKey(forAccount: accountUserId))
    }

    private static func save(
        _ items: [RecentSearchItem],
        forAccount accountUserId: String,
        defaults: UserDefaults
    ) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: storageKey(forAccount: accountUserId))
    }
}
