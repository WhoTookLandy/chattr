import Foundation

/// The emotes you last inserted in a channel, newest first. Feeds the
/// compose bar's quick-emote row (shown while the field is focused).
///
/// Per channel, because a channel's 7TV/BTTV/FFZ emotes only render in
/// that channel; a global list would offer emotes that arrive as plain
/// text elsewhere. Recorded when an emote is inserted from the picker or
/// the row itself, not by scanning sent text.
///
/// UserDefaults, like `DraftStorage`: a dozen small entries per channel.
public enum RecentEmotes {
    /// Entries kept per channel. The row shows as many as fit.
    static let limit = 12

    static func storageKey(forChannel channelLogin: String) -> String {
        "chattr.recentEmotes.\(channelLogin.lowercased())"
    }

    /// Newest first. Empty for a channel you haven't used an emote in yet.
    static func load(channel channelLogin: String, defaults: UserDefaults = .standard) -> [PickerEmote] {
        guard let data = defaults.data(forKey: storageKey(forChannel: channelLogin)),
              let decoded = try? JSONDecoder().decode([PickerEmote].self, from: data)
        else { return [] }
        return decoded
    }

    /// Move `emote` to the front, dropping its older copy and anything past
    /// `limit`. Returns the new list so the caller needn't reload it.
    @discardableResult
    static func record(
        _ emote: PickerEmote,
        channel channelLogin: String,
        defaults: UserDefaults = .standard
    ) -> [PickerEmote] {
        let updated = inserting(emote, into: load(channel: channelLogin, defaults: defaults))
        if let data = try? JSONEncoder().encode(updated) {
            defaults.set(data, forKey: storageKey(forChannel: channelLogin))
        }
        return updated
    }

    /// Pure ordering rule behind `record`.
    static func inserting(_ emote: PickerEmote, into list: [PickerEmote]) -> [PickerEmote] {
        Array(([emote] + list.filter { $0.id != emote.id }).prefix(limit))
    }
}

extension PickerEmote {
    /// Direct construction, for tests and previews.
    init(id: String, name: String, imageURL: URL? = nil, isAnimated: Bool = false) {
        self.id = id
        self.name = name
        self.imageURL = imageURL
        self.isAnimated = isAnimated
        self.searchKey = name.lowercased()
    }
}

/// Slow-mode cooldown after your own send. Twitch drops a message sent
/// before the wait is up, so the compose bar shows a countdown ring and
/// ignores Return until it ends. Moderators and the broadcaster are exempt.
struct SlowModeCooldown: Equatable {
    let startedAt: Date
    let seconds: Int

    var endsAt: Date { startedAt.addingTimeInterval(TimeInterval(seconds)) }

    func isActive(at now: Date) -> Bool { now < endsAt }

    /// Whole seconds left, rounded up so the ring never reads 0 while active.
    func remaining(at now: Date) -> Int {
        max(0, Int(endsAt.timeIntervalSince(now).rounded(.up)))
    }

    /// Fraction of the wait still to go, 1 → 0.
    func fractionRemaining(at now: Date) -> Double {
        guard seconds > 0 else { return 0 }
        return min(1, max(0, endsAt.timeIntervalSince(now) / Double(seconds)))
    }
}
