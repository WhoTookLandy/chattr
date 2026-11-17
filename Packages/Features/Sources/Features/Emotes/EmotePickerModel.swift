import Foundation
import EmoteSources
import TwitchKit
import os

/// A single emote as the picker renders it — unifying Twitch native
/// emotes (`TwitchEmote`) and third-party emotes (`EmoteSources.Emote`)
/// behind one shape so the grid doesn't care where each came from.
public struct PickerEmote: Identifiable, Hashable, Sendable {
    /// Source-prefixed unique id (e.g. "7tv-01F…", "twitch-25") so ids
    /// don't collide across providers.
    public let id: String
    /// The token the user types in chat to use this emote — what we
    /// insert into the composer on tap.
    public let name: String
    /// 2x CDN URL for the grid thumbnail. The grid shows stills, so this is
    /// the emote's static variant when it has one (`EmoteImageSource`).
    public let imageURL: URL?
    /// Whether `imageURL` is an animated file, which the grid renders as
    /// its poster frame through the frame decoder rather than `LazyImage`.
    public let isAnimated: Bool

    /// Pre-lowercased `name`, computed once at build time. The picker's
    /// search filters on this with a plain `contains`, avoiding a
    /// `localizedCaseInsensitiveContains` call across the whole emote set
    /// on every keystroke (locale-aware matching is far more expensive,
    /// and big channels carry thousands of emotes).
    public let searchKey: String

    /// Build from a third-party (7TV/BTTV/FFZ) emote.
    init(_ emote: Emote) {
        let source = EmoteImageSource.thirdParty(emote, animate: false)
        self.id = "\(emote.source.rawValue)-\(emote.id)"
        self.name = emote.name
        self.imageURL = source.url
        self.isAnimated = source.isAnimated
        self.searchKey = emote.name.lowercased()
    }

    /// Build from a Twitch native emote.
    init(twitch emote: TwitchEmote) {
        let source = EmoteImageSource.twitch(id: emote.id, formats: emote.format, animate: false)
        self.id = "twitch-\(emote.id)"
        self.name = emote.name
        self.imageURL = source.url
        self.isAnimated = source.isAnimated
        self.searchKey = emote.name.lowercased()
    }
}

/// One titled group of emotes in the picker (e.g. "Channel Emotes",
/// "Twitch Global"). The grid renders these as pinned-header sections.
public struct EmoteSection: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let emotes: [PickerEmote]
    /// Set only on the stand-in `EmoteCatalog.buildSections(emoteIndex:twitchGlobal:)`
    /// returns while the real sections are still being sorted; names that
    /// build for `EmoteCatalog.resolve(_:)`.
    var pendingBuild: Int? = nil
}

/// Builds the picker's sectioned emote list from the data chattr already
/// holds in memory:
///   - `EmoteIndex.snapshot()` → 7TV/BTTV/FFZ (channel + global)
///   - `GlobalCatalog.globalEmotes` → Twitch native global emotes
///
/// Section order is relevance-first: this channel's custom emotes at the
/// top (what people actually want), then Twitch global, then third-party
/// globals by provider. Each section is name-sorted (case-insensitive) for
/// predictable browsing; the sorted result is memoized per emote table
/// (see `buildSections(emoteIndex:twitchGlobal:)`).
///
/// Future commits add the channel's Twitch subscriber emotes and the
/// user's subscribed-emote set (both need their own Helix fetches).
public enum EmoteCatalog {

    /// Preferred entry point, called on the main thread as the picker
    /// opens. It never sorts there: while the index's publish generation
    /// and the Twitch globals are unchanged it returns the memoized
    /// sections; otherwise it starts the build — thousands of
    /// `localizedCaseInsensitiveCompare`s on a big channel — on a
    /// background task and returns a one-section stand-in for it, which
    /// `EmotePickerView` exchanges for the result through `resolve(_:)`.
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
            // One picker is open at a time; one spare covers a second
            // compose bar asking before the first picker has resolved.
            if state.pending.count > 2 {
                state.pending.removeFirst(state.pending.count - 2)
            }
            return state.lastToken
        }
        return [EmoteSection(id: "pending", title: "", emotes: [], pendingBuild: token)]
    }

    /// The finished sections for a value `buildSections(emoteIndex:twitchGlobal:)`
    /// returned: the value itself, unless it is the stand-in for a build
    /// still running, in which case this waits for that build.
    static func resolve(_ sections: [EmoteSection]) async -> [EmoteSection] {
        guard let token = sections.first?.pendingBuild else { return sections }
        let task = state.withLock { (state: inout State) -> Task<[EmoteSection], Never>? in
            state.pending.first { $0.token == token }?.task
        }
        guard let task else { return [] }
        return await task.value
    }

    /// Dictionary-based entry point. Synchronous and complete: it sorts on
    /// the caller's thread unless the same tables are memoized.
    public static func buildSections(
        thirdParty: [String: Emote],
        twitchGlobal: [String: TwitchEmote]
    ) -> [EmoteSection] {
        memoizedSections(thirdParty: thirdParty, generation: nil, twitchGlobal: twitchGlobal)
            ?? sortedSections(thirdParty: thirdParty, generation: nil, twitchGlobal: twitchGlobal)
    }

    // MARK: - Memo

    private struct Memo: Sendable {
        /// `EmoteIndex.generation` the sections were built from; `nil` when
        /// built from a bare dictionary. Generations are process-wide
        /// unique, so equal generations mean the same table.
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
        /// Single-entry memo (one picker is open at a time).
        var memo: Memo?
        var pending: [PendingBuild] = []
        var lastToken = 0
    }

    /// Lock-protected so `buildSections` stays callable from any isolation
    /// and the background build can publish its result.
    private static let state = OSAllocatedUnfairLock(initialState: State())

    /// The memoized sections, if they were built from these tables. A
    /// known generation settles the third-party half without comparing
    /// thousands of emotes; only the bare-dictionary path compares content.
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

    // MARK: - Building

    /// Builds and memoizes the sections. Section order is: channel emotes,
    /// Twitch global, then third-party globals by provider.
    private static func sortedSections(
        thirdParty: [String: Emote],
        generation: Int?,
        twitchGlobal: [String: TwitchEmote]
    ) -> [EmoteSection] {
        var sections: [EmoteSection] = []
        let allThirdParty = Array(thirdParty.values)

        // 1. Channel emotes (third-party with an owner). The big draw —
        //    the channel's curated 7TV/BTTV/FFZ set.
        let channelEmotes = allThirdParty.filter { $0.ownerChannelId != nil }
        if !channelEmotes.isEmpty {
            sections.append(EmoteSection(
                id: "channel",
                title: "Channel Emotes",
                emotes: sortedPickerEmotes(channelEmotes)
            ))
        }

        // 2. Twitch global (Kappa, LUL, etc.).
        if !twitchGlobal.isEmpty {
            sections.append(EmoteSection(
                id: "twitch-global",
                title: "Twitch Global",
                emotes: twitchGlobal.values
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                    .map { PickerEmote(twitch: $0) }
            ))
        }

        // 3. Third-party globals, grouped by provider so the user can
        //    find a known 7TV/BTTV/FFZ emote by where it lives.
        let globalThirdParty = allThirdParty.filter { $0.ownerChannelId == nil }
        for source in Emote.Source.allCases {
            let group = globalThirdParty.filter { $0.source == source }
            guard !group.isEmpty else { continue }
            sections.append(EmoteSection(
                id: "global-\(source.rawValue)",
                title: "\(sourceLabel(source)) Global",
                emotes: sortedPickerEmotes(group)
            ))
        }

        let memo = Memo(
            generation: generation, thirdParty: thirdParty, twitchGlobal: twitchGlobal, sections: sections)
        state.withLock { $0.memo = memo }
        return sections
    }

    // MARK: - Helpers

    private static func sortedPickerEmotes(_ emotes: [Emote]) -> [PickerEmote] {
        emotes
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { PickerEmote($0) }
    }

    private static func sourceLabel(_ source: Emote.Source) -> String {
        switch source {
        case .sevenTV: return "7TV"
        case .bttv:    return "BTTV"
        case .ffz:     return "FFZ"
        }
    }
}
