import Foundation
import EmoteSources
import TwitchKit
import os

/// A single emote as the picker renders it — unifying Twitch native emotes
/// (`TwitchEmote`, `UserTwitchEmote`) and third-party emotes
/// (`EmoteSources.Emote`) behind one shape so the grid doesn't care where each
/// came from.
public struct PickerEmote: Identifiable, Hashable, Sendable, Codable {
    /// Source-prefixed unique id (e.g. "sevenTV-7tv:01F…", "twitch-25") so ids
    /// don't collide across providers.
    public let id: String
    /// The token the user types in chat to use this emote — what we insert
    /// into the composer on tap.
    public let name: String
    /// 2x CDN URL for the grid thumbnail. The grid shows stills, so this is
    /// the emote's static variant when it has one (`EmoteImageSource`).
    public let imageURL: URL?
    /// Whether `imageURL` is an animated file, which the grid renders as its
    /// poster frame through the frame decoder rather than plain Nuke image
    /// loading. With 7TV `static_name` and Twitch `static` URLs populated,
    /// almost every picker cell has `isAnimated == false`.
    public let isAnimated: Bool

    /// Pre-lowercased `name`, computed once at build time. Used for both fast
    /// O(n) search filtering and fast alphabetical sorting (avoiding slow ICU
    /// `localizedCaseInsensitiveCompare` across thousands of emotes).
    public let searchKey: String

    /// Native width ÷ height when known (7TV / FFZ), `nil` for square/unknown.
    /// Optional so `RecentEmotes` JSON persisted by earlier builds still decodes.
    public let aspectRatio: Double?

    /// Full animated CDN URL when this emote has an animated variant — used by
    /// the picker's long-press inspector so users can preview the live motion.
    public let animatedURL: URL?

    /// Short origin label shown in the long-press preview (e.g. "7TV",
    /// "Twitch", or the subscribed broadcaster's display name).
    public let sourceLabel: String?

    /// Build from a third-party (7TV/BTTV/FFZ) emote.
    init(_ emote: Emote, sourceLabel: String? = nil) {
        let still = EmoteImageSource.thirdParty(emote, animate: false)
        let moving = emote.isAnimated ? EmoteImageSource.thirdParty(emote, animate: true) : nil
        self.id = "\(emote.source.rawValue)-\(emote.id)"
        self.name = emote.name
        self.imageURL = still.url
        self.isAnimated = still.isAnimated
        self.searchKey = emote.name.lowercased()
        self.aspectRatio = emote.aspectRatio
        self.animatedURL = moving?.url
        self.sourceLabel = sourceLabel ?? EmoteCatalog.sourceLabel(emote.source)
    }

    /// Build from a Twitch native emote (`GlobalCatalog` or channel emotes).
    init(twitch emote: TwitchEmote, sourceLabel: String? = nil) {
        let still = EmoteImageSource.twitch(id: emote.id, formats: emote.format, animate: false)
        let hasAnimated = emote.format.contains("animated")
        let moving = hasAnimated ? EmoteImageSource.twitch(id: emote.id, formats: emote.format, animate: true) : nil
        self.id = "twitch-\(emote.id)"
        self.name = emote.name
        self.imageURL = still.url
        self.isAnimated = still.isAnimated
        self.searchKey = emote.name.lowercased()
        self.aspectRatio = 1.0
        self.animatedURL = moving?.url
        self.sourceLabel = sourceLabel ?? "Twitch"
    }

    /// Build from a user-accessible Twitch emote (`GET /chat/emotes/user`).
    init(userTwitch emote: UserTwitchEmote, sourceLabel: String? = nil) {
        let still = EmoteImageSource.twitch(id: emote.id, formats: emote.format, animate: false)
        let hasAnimated = emote.format.contains("animated")
        let moving = hasAnimated ? EmoteImageSource.twitch(id: emote.id, formats: emote.format, animate: true) : nil
        self.id = "twitch-\(emote.id)"
        self.name = emote.name
        self.imageURL = still.url
        self.isAnimated = still.isAnimated
        self.searchKey = emote.name.lowercased()
        self.aspectRatio = 1.0
        self.animatedURL = moving?.url
        self.sourceLabel = sourceLabel ?? "Twitch"
    }
}

/// One titled group of emotes in the picker (e.g. "Recently Used",
/// current channel's Twitch/7TV/BTTV/FFZ sets, each subscribed channel,
/// "Twitch Global", third-party globals).
public struct EmoteSection: Identifiable, Hashable, Sendable {

    /// Semantic category driving the section header icon/tag and the quick-jump
    /// category rail at the top of the picker.
    public enum Kind: Hashable, Sendable {
        case recent
        case currentChannelTwitch
        case channelThirdParty(Emote.Source)
        case subscribedChannel(ownerId: String)
        case twitchUnlocked
        case twitchGlobal
        case globalThirdParty(Emote.Source)
    }

    /// High-level group used to draw subtle dividers in the quick-jump rail.
    public enum RailGroup: Hashable, Sendable {
        case recent
        case currentChannel
        case subscriptions
        case global
    }

    public let id: String
    public let title: String
    /// Short badge pill next to the section title (e.g. "Sub", "7TV", "Twitch").
    public let badge: String?
    /// Broadcaster profile image for channel / subscribed-channel sections.
    public let avatarURL: URL?
    public let kind: Kind
    public let emotes: [PickerEmote]
    /// Set only on the stand-in `EmoteCatalog.buildSections(emoteIndex:twitchGlobal:)`
    /// returns while the real sections are still being sorted; names that
    /// build for `EmoteCatalog.resolve(_:)`.
    var pendingBuild: Int? = nil

    public var railGroup: RailGroup {
        switch kind {
        case .recent: .recent
        case .currentChannelTwitch, .channelThirdParty: .currentChannel
        case .subscribedChannel: .subscriptions
        case .twitchUnlocked, .twitchGlobal, .globalThirdParty: .global
        }
    }

    public init(
        id: String,
        title: String,
        badge: String? = nil,
        avatarURL: URL? = nil,
        kind: Kind = .twitchGlobal,
        emotes: [PickerEmote],
        pendingBuild: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.badge = badge
        self.avatarURL = avatarURL
        self.kind = kind
        self.emotes = emotes
        self.pendingBuild = pendingBuild
    }
}

/// Builds and caches the picker's sectioned emote list from every source chattr
/// holds:
///   - `RecentEmotes` → this channel's recently inserted emotes
///   - `UserEmoteStore` → the signed-in user's subscribed channels' emotes,
///     bits-tier emotes, and unlocked Twitch specials (Prime, Turbo, Hype Train…)
///   - `ChannelTwitchEmotesStore` → current channel's follower emotes (when
///     following or broadcasting)
///   - `EmoteIndex` → 7TV / BTTV / FFZ channel + global emotes
///   - `GlobalCatalog` → Twitch native global emotes
///
/// ## Performance
///
/// - Sorting compares pre-lowercased `searchKey` (`$0.searchKey < $1.searchKey`)
///   rather than ICU `localizedCaseInsensitiveCompare` (~50× faster on 3,000+
///   emotes, <1 ms total).
/// - Multi-entry LRU cache keyed by integer version stamps (`thirdPartyGeneration`,
///   `twitchGlobalVersion`, `userEmotesVersion`, `channelTwitchVersion`,
///   `channelId`, `recentIds`) — O(1) lookup with zero dictionary equality
///   scans on the main thread, and switching between open channels keeps both
///   channels' sections hot.
public enum EmoteCatalog {

    /// Input snapshot for a full picker build. Value type (`Sendable`) so
    /// building can run off the main thread whenever the cache misses.
    public struct BuildInput: Sendable {
        public let channelId: String
        public let channelDisplayName: String
        public let channelAvatarURL: URL?
        public let recentEmotes: [PickerEmote]
        public let thirdParty: [String: Emote]
        public let thirdPartyGeneration: Int?
        public let twitchGlobal: [String: TwitchEmote]
        public let twitchGlobalVersion: Int?
        public let userEmotes: [UserTwitchEmote]
        public let userEmoteOwners: [String: EmoteChannelInfo]
        public let userEmotesVersion: Int?
        public let channelTwitchEmotes: [TwitchEmote]
        public let channelTwitchVersion: Int?
        public let isFollowingChannel: Bool
        public let isBroadcaster: Bool

        public init(
            channelId: String,
            channelDisplayName: String,
            channelAvatarURL: URL? = nil,
            recentEmotes: [PickerEmote] = [],
            thirdParty: [String: Emote],
            thirdPartyGeneration: Int? = nil,
            twitchGlobal: [String: TwitchEmote],
            twitchGlobalVersion: Int? = nil,
            userEmotes: [UserTwitchEmote] = [],
            userEmoteOwners: [String: EmoteChannelInfo] = [:],
            userEmotesVersion: Int? = nil,
            channelTwitchEmotes: [TwitchEmote] = [],
            channelTwitchVersion: Int? = nil,
            isFollowingChannel: Bool = false,
            isBroadcaster: Bool = false
        ) {
            self.channelId = channelId
            self.channelDisplayName = channelDisplayName
            self.channelAvatarURL = channelAvatarURL
            self.recentEmotes = recentEmotes
            self.thirdParty = thirdParty
            self.thirdPartyGeneration = thirdPartyGeneration
            self.twitchGlobal = twitchGlobal
            self.twitchGlobalVersion = twitchGlobalVersion
            self.userEmotes = userEmotes
            self.userEmoteOwners = userEmoteOwners
            self.userEmotesVersion = userEmotesVersion
            self.channelTwitchEmotes = channelTwitchEmotes
            self.channelTwitchVersion = channelTwitchVersion
            self.isFollowingChannel = isFollowingChannel
            self.isBroadcaster = isBroadcaster
        }
    }

    // MARK: - Full sectioned build (new picker path)

    /// Returns cached sections immediately on an O(1) version-key hit, or `nil`
    /// when a fresh build should run off the main thread.
    public static func cachedSections(for input: BuildInput) -> [EmoteSection]? {
        guard let key = FastCacheKey(input) else { return nil }
        return fastCache.withLock { $0.lookup(key) }
    }

    /// Builds the full sectioned catalog (Recents → This Channel Twitch →
    /// This Channel 7TV/BTTV/FFZ → Subscribed Channels → Unlocked Specials →
    /// Twitch Global → Third-Party Globals) and caches the result under its
    /// version key when available.
    public static func buildSections(from input: BuildInput) -> [EmoteSection] {
        if let cached = cachedSections(for: input) {
            return cached
        }

        var sections: [EmoteSection] = []

        // 1. Recently Used (this channel's recent emotes, newest first).
        if !input.recentEmotes.isEmpty {
            sections.append(EmoteSection(
                id: "recent",
                title: "Recently Used",
                badge: nil,
                avatarURL: nil,
                kind: .recent,
                emotes: deduplicatedById(input.recentEmotes)
            ))
        }

        // Partition user-accessible Twitch emotes by owner & type.
        let globalTwitchIds = Set(input.twitchGlobal.keys)
        var fallbackGlobals: [PickerEmote] = []
        var fallbackGlobalSeenIds: Set<String> = []
        var currentChannelTwitch: [PickerEmote] = []
        var currentChannelSeenIds: Set<String> = []
        var otherChannelsByOwner: [String: [UserTwitchEmote]] = [:]
        var unlockedSpecial: [PickerEmote] = []
        var unlockedSeenIds: Set<String> = []

        let currentOwnerLabel = input.channelDisplayName.isEmpty ? "Channel" : input.channelDisplayName
        for emote in input.userEmotes {
            if emote.isTwitchOwned {
                if emote.emoteType == "globals" {
                    // Prefer GlobalCatalog when present; keep user-emote
                    // globals as an ID-deduplicated fallback if GlobalCatalog
                    // hasn't loaded or is missing an entry.
                    if !globalTwitchIds.contains(emote.id),
                       fallbackGlobalSeenIds.insert(emote.id).inserted {
                        fallbackGlobals.append(PickerEmote(userTwitch: emote, sourceLabel: "Twitch Global"))
                    }
                    continue
                }
                guard !globalTwitchIds.contains(emote.id) else { continue }
                if unlockedSeenIds.insert(emote.id).inserted {
                    unlockedSpecial.append(PickerEmote(
                        userTwitch: emote,
                        sourceLabel: specialEmoteLabel(emote.emoteType)
                    ))
                }
            } else if !input.channelId.isEmpty, emote.ownerId == input.channelId {
                if currentChannelSeenIds.insert(emote.id).inserted {
                    currentChannelTwitch.append(PickerEmote(
                        userTwitch: emote,
                        sourceLabel: currentOwnerLabel
                    ))
                }
            } else {
                // Twitch follower emotes from OTHER channels cannot be used
                // outside their home channel.
                guard emote.emoteType != "follower" else { continue }
                otherChannelsByOwner[emote.ownerId, default: []].append(emote)
            }
        }

        // Merge the current channel's follower emotes when the user follows
        // this channel (or is the broadcaster) — `/chat/emotes/user` without
        // `broadcaster_id` omits follower emotes for non-subscribed channels.
        if input.isFollowingChannel || input.isBroadcaster {
            for emote in input.channelTwitchEmotes where emote.emoteType == "follower" {
                if currentChannelSeenIds.insert(emote.id).inserted {
                    currentChannelTwitch.append(PickerEmote(
                        twitch: emote,
                        sourceLabel: currentOwnerLabel
                    ))
                }
            }
        }

        // 2. Current Channel — Twitch (sub / bits / follower emotes usable here).
        if !currentChannelTwitch.isEmpty {
            let avatar = input.channelAvatarURL ?? input.userEmoteOwners[input.channelId]?.profileImageURL
            sections.append(EmoteSection(
                id: "channel-twitch-\(input.channelId)",
                title: currentOwnerLabel,
                badge: "Twitch",
                avatarURL: avatar,
                kind: .currentChannelTwitch,
                emotes: sortedBySearchKey(currentChannelTwitch)
            ))
        }

        // 3. Current Channel — Third-party emotes grouped cleanly by provider
        //    (7TV → BTTV → FFZ) so each set is scannable and jumpable.
        let allThirdParty = Array(input.thirdParty.values)
        var channelBySource: [Emote.Source: [Emote]] = [:]
        var globalBySource: [Emote.Source: [Emote]] = [:]
        for emote in allThirdParty {
            if emote.ownerChannelId != nil {
                channelBySource[emote.source, default: []].append(emote)
            } else {
                globalBySource[emote.source, default: []].append(emote)
            }
        }

        for source in Emote.Source.allCases {
            guard let group = channelBySource[source], !group.isEmpty else { continue }
            let label = sourceLabel(source)
            sections.append(EmoteSection(
                id: "channel-\(source.rawValue)",
                title: "\(label) Channel",
                badge: label,
                avatarURL: nil,
                kind: .channelThirdParty(source),
                emotes: sortedPickerEmotes(group)
            ))
        }

        // 4. Other Subscribed Channels (grouped by broadcaster, sorted by name).
        let sortedOwners: [(ownerId: String, title: String, avatar: URL?, emotes: [UserTwitchEmote])] =
            otherChannelsByOwner.map { ownerId, emotes in
                let info = input.userEmoteOwners[ownerId]
                let title = info?.displayName.isEmpty == false ? info!.displayName : "Channel \(ownerId)"
                return (ownerId, title, info?.profileImageURL, emotes)
            }
            .sorted { $0.title.lowercased() < $1.title.lowercased() }

        for entry in sortedOwners {
            let pickerEmotes = deduplicatedById(
                entry.emotes.map { PickerEmote(userTwitch: $0, sourceLabel: entry.title) }
            )
            guard !pickerEmotes.isEmpty else { continue }
            sections.append(EmoteSection(
                id: "sub-\(entry.ownerId)",
                title: entry.title,
                badge: "Sub",
                avatarURL: entry.avatar,
                kind: .subscribedChannel(ownerId: entry.ownerId),
                emotes: sortedBySearchKey(pickerEmotes)
            ))
        }

        // 5. Unlocked & Special Twitch emotes (Prime, Turbo, Hype Train, Bits…).
        if !unlockedSpecial.isEmpty {
            sections.append(EmoteSection(
                id: "twitch-unlocked",
                title: "Unlocked",
                badge: "Twitch",
                avatarURL: nil,
                kind: .twitchUnlocked,
                emotes: sortedBySearchKey(unlockedSpecial)
            ))
        }

        // 6. Twitch Global (Kappa, LUL, PogChamp…), merging any user-emote
        //    globals missing from GlobalCatalog as a fallback.
        if !input.twitchGlobal.isEmpty || !fallbackGlobals.isEmpty {
            let pickerGlobals = input.twitchGlobal.values.map { PickerEmote(twitch: $0, sourceLabel: "Twitch Global") }
                + fallbackGlobals
            sections.append(EmoteSection(
                id: "twitch-global",
                title: "Twitch Global",
                badge: "Global",
                avatarURL: nil,
                kind: .twitchGlobal,
                emotes: sortedBySearchKey(pickerGlobals)
            ))
        }

        // 7. Third-party globals (7TV, BTTV, FFZ).
        for source in Emote.Source.allCases {
            guard let group = globalBySource[source], !group.isEmpty else { continue }
            let label = sourceLabel(source)
            sections.append(EmoteSection(
                id: "global-\(source.rawValue)",
                title: "\(label) Global",
                badge: label,
                avatarURL: nil,
                kind: .globalThirdParty(source),
                emotes: sortedPickerEmotes(group)
            ))
        }

        let built = sections
        if let key = FastCacheKey(input) {
            fastCache.withLock { $0.store(built, for: key) }
        }
        return built
    }

    // MARK: - Search filtering

    /// Filters `sections` against a trimmed, lowercased `needle`. Prefix
    /// matches come before mid-word matches so typing `"pepe"` surfaces
    /// `PepeLaugh` ahead of `WidePepe`. Drops empty sections and suppresses a
    /// match in "Recently Used" only when the same emote ID already appears in
    /// another matching section (preserving persisted recents whose provider
    /// hasn't loaded yet).
    public static func filter(_ sections: [EmoteSection], needle: String) -> [EmoteSection] {
        guard !needle.isEmpty else { return sections }

        var nonRecentMatchedIds: Set<String> = []
        var nonRecentResults: [EmoteSection] = []
        var recentSection: EmoteSection?

        for section in sections {
            if section.kind == .recent {
                recentSection = section
                continue
            }
            let combined = matchingEmotes(in: section.emotes, needle: needle)
            guard !combined.isEmpty else { continue }
            for emote in combined { nonRecentMatchedIds.insert(emote.id) }
            nonRecentResults.append(EmoteSection(
                id: section.id,
                title: section.title,
                badge: section.badge,
                avatarURL: section.avatarURL,
                kind: section.kind,
                emotes: combined
            ))
        }

        if let recentSection {
            let uniqueRecents = matchingEmotes(in: recentSection.emotes, needle: needle)
                .filter { !nonRecentMatchedIds.contains($0.id) }
            if !uniqueRecents.isEmpty {
                let filteredRecent = EmoteSection(
                    id: recentSection.id,
                    title: recentSection.title,
                    badge: recentSection.badge,
                    avatarURL: recentSection.avatarURL,
                    kind: recentSection.kind,
                    emotes: uniqueRecents
                )
                return [filteredRecent] + nonRecentResults
            }
        }
        return nonRecentResults
    }

    private static func matchingEmotes(in emotes: [PickerEmote], needle: String) -> [PickerEmote] {
        var prefixMatches: [PickerEmote] = []
        var containsMatches: [PickerEmote] = []
        for emote in emotes {
            if emote.searchKey.hasPrefix(needle) {
                prefixMatches.append(emote)
            } else if emote.searchKey.contains(needle) {
                containsMatches.append(emote)
            }
        }
        return prefixMatches + containsMatches
    }

    // MARK: - Legacy entry points (kept for tests & bare-table callers)

    public static func buildSections(
        emoteIndex: EmoteIndex?,
        twitchGlobal: [String: TwitchEmote]
    ) -> [EmoteSection] {
        let versioned = emoteIndex?.snapshotWithGeneration()
        let thirdParty = versioned?.emotes ?? [:]
        let generation = versioned?.generation
        if let ready = memoizedSections(thirdParty: thirdParty, generation: generation, twitchGlobal: twitchGlobal) {
            return ready
        }
        let task = Task.detached(priority: .userInitiated) {
            EmoteCatalog.sortedSections(thirdParty: thirdParty, generation: generation, twitchGlobal: twitchGlobal)
        }
        let token = state.withLock { (state: inout State) -> Int in
            state.lastToken += 1
            state.pending.append(PendingBuild(token: state.lastToken, task: task))
            if state.pending.count > 2 {
                state.pending.removeFirst(state.pending.count - 2)
            }
            return state.lastToken
        }
        return [EmoteSection(id: "pending", title: "", emotes: [], pendingBuild: token)]
    }

    static func resolve(_ sections: [EmoteSection]) async -> [EmoteSection] {
        guard let token = sections.first?.pendingBuild else { return sections }
        let task = state.withLock { (state: inout State) -> Task<[EmoteSection], Never>? in
            state.pending.first { $0.token == token }?.task
        }
        guard let task else { return [] }
        return await task.value
    }

    public static func buildSections(
        thirdParty: [String: Emote],
        twitchGlobal: [String: TwitchEmote]
    ) -> [EmoteSection] {
        memoizedSections(thirdParty: thirdParty, generation: nil, twitchGlobal: twitchGlobal)
            ?? sortedSections(thirdParty: thirdParty, generation: nil, twitchGlobal: twitchGlobal)
    }

    // MARK: - O(1) multi-entry fast cache

    private struct FastCacheKey: Hashable, Sendable {
        let channelId: String
        let channelDisplayName: String
        let channelAvatarURL: URL?
        let recentEmotes: [PickerEmote]
        let thirdPartyGeneration: Int
        let twitchGlobalVersion: Int
        let userEmotesVersion: Int
        let channelTwitchVersion: Int
        let isFollowingChannel: Bool
        let isBroadcaster: Bool

        init?(_ input: BuildInput) {
            guard let tpGen = input.thirdPartyGeneration,
                  let tgVer = input.twitchGlobalVersion,
                  let ueVer = input.userEmotesVersion,
                  let ctVer = input.channelTwitchVersion
            else { return nil }
            self.channelId = input.channelId
            self.channelDisplayName = input.channelDisplayName
            self.channelAvatarURL = input.channelAvatarURL
            self.recentEmotes = input.recentEmotes
            self.thirdPartyGeneration = tpGen
            self.twitchGlobalVersion = tgVer
            self.userEmotesVersion = ueVer
            self.channelTwitchVersion = ctVer
            self.isFollowingChannel = input.isFollowingChannel
            self.isBroadcaster = input.isBroadcaster
        }
    }

    private struct FastCache: Sendable {
        private var entries: [(key: FastCacheKey, sections: [EmoteSection])] = []
        private let capacity = 8

        mutating func lookup(_ key: FastCacheKey) -> [EmoteSection]? {
            guard let index = entries.firstIndex(where: { $0.key == key }) else { return nil }
            let hit = entries.remove(at: index)
            entries.append(hit)
            return hit.sections
        }

        mutating func store(_ sections: [EmoteSection], for key: FastCacheKey) {
            entries.removeAll { $0.key == key }
            entries.append((key, sections))
            if entries.count > capacity {
                entries.removeFirst(entries.count - capacity)
            }
        }
    }

    private static let fastCache = OSAllocatedUnfairLock(initialState: FastCache())

    // MARK: - Legacy memo

    private struct Memo: Sendable {
        let generation: Int?
        let thirdParty: [String: Emote]
        let twitchGlobal: [String: TwitchEmote]
        let sections: [EmoteSection]
    }

    private struct PendingBuild: Sendable {
        let token: Int
        let task: Task<[EmoteSection], Never>
    }

    private struct State: Sendable {
        var memo: Memo?
        var pending: [PendingBuild] = []
        var lastToken = 0
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    private static func memoizedSections(
        thirdParty: [String: Emote],
        generation: Int?,
        twitchGlobal: [String: TwitchEmote]
    ) -> [EmoteSection]? {
        guard let memo = state.withLock({ $0.memo }) else { return nil }
        if let generation {
            guard memo.generation == generation else { return nil }
        } else {
            guard memo.thirdParty == thirdParty else { return nil }
        }
        return memo.twitchGlobal == twitchGlobal ? memo.sections : nil
    }

    private static func sortedSections(
        thirdParty: [String: Emote],
        generation: Int?,
        twitchGlobal: [String: TwitchEmote]
    ) -> [EmoteSection] {
        let sections = buildSections(from: BuildInput(
            channelId: "",
            channelDisplayName: "",
            thirdParty: thirdParty,
            twitchGlobal: twitchGlobal
        ))
        let memo = Memo(
            generation: generation, thirdParty: thirdParty, twitchGlobal: twitchGlobal, sections: sections)
        state.withLock { $0.memo = memo }
        return sections
    }

    // MARK: - Helpers

    private static func sortedPickerEmotes(_ emotes: [Emote]) -> [PickerEmote] {
        sortedBySearchKey(emotes.map { PickerEmote($0) })
    }

    /// Fast alphabetical sort using pre-lowercased `searchKey` with case-sensitive
    /// tiebreak for deterministic order. Orders of magnitude faster than ICU
    /// `localizedCaseInsensitiveCompare` on multi-thousand-emote catalogs.
    private static func sortedBySearchKey(_ emotes: [PickerEmote]) -> [PickerEmote] {
        emotes.sorted { lhs, rhs in
            if lhs.searchKey != rhs.searchKey {
                return lhs.searchKey < rhs.searchKey
            }
            return lhs.name < rhs.name
        }
    }

    private static func deduplicatedById(_ emotes: [PickerEmote]) -> [PickerEmote] {
        var seen: Set<String> = []
        var out: [PickerEmote] = []
        out.reserveCapacity(emotes.count)
        for emote in emotes where seen.insert(emote.id).inserted {
            out.append(emote)
        }
        return out
    }

    static func sourceLabel(_ source: Emote.Source) -> String {
        switch source {
        case .sevenTV: return "7TV"
        case .bttv:    return "BTTV"
        case .ffz:     return "FFZ"
        }
    }

    private static func specialEmoteLabel(_ emoteType: String) -> String {
        switch emoteType {
        case "prime": return "Prime"
        case "turbo": return "Turbo"
        case "hypetrain": return "Hype Train"
        case "bitstier": return "Bits"
        case "rewards", "channelpoints": return "Rewards"
        case "limitedtime": return "Limited"
        case "smilies": return "Twitch"
        case "twofactor": return "2FA"
        default: return "Twitch"
        }
    }
}
