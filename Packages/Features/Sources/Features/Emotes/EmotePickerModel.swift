import Foundation
import EmoteSources
import TwitchKit
import Core
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
    /// 2x CDN URL for the grid thumbnail.
    public let imageURL: URL?
    /// Whether the emote has an animated variant. Used later for
    /// animated rendering; today the grid renders the static frame.
    public let isAnimated: Bool

    /// Pre-lowercased `name`, computed once at build time. The picker's
    /// search filters on this with a plain `contains`, avoiding a
    /// `localizedCaseInsensitiveContains` call across the whole emote set
    /// on every keystroke (locale-aware matching is far more expensive,
    /// and big channels carry thousands of emotes).
    public let searchKey: String

    /// Build from a third-party (7TV/BTTV/FFZ) emote.
    init(_ emote: Emote) {
        self.id = "\(emote.source.rawValue)-\(emote.id)"
        self.name = emote.name
        // Prefer 2x (chat-row scale); fall back across available sizes.
        self.imageURL = emote.urls[.x2] ?? emote.urls[.x1] ?? emote.urls[.x4]
        self.isAnimated = emote.isAnimated
        self.searchKey = emote.name.lowercased()
    }

    /// Build from a Twitch native emote.
    init(twitch emote: TwitchEmote) {
        self.id = "twitch-\(emote.id)"
        self.name = emote.name
        let animated = emote.format.contains("animated")
        self.imageURL = Endpoints.TwitchCDN.emote(
            id: emote.id,
            format: animated ? "animated" : "static"
        )
        self.isAnimated = animated
        self.searchKey = emote.name.lowercased()
    }
}

/// One titled group of emotes in the picker (e.g. "Channel Emotes",
/// "Twitch Global"). The grid renders these as pinned-header sections.
public struct EmoteSection: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let emotes: [PickerEmote]
}

/// Builds the picker's sectioned emote list from the data chattr already
/// holds in memory:
///   - `EmoteIndex.snapshot()` → 7TV/BTTV/FFZ (channel + global)
///   - `GlobalCatalog.globalEmotes` → Twitch native global emotes
///
/// Section order is relevance-first: this channel's custom emotes at the
/// top (what people actually want), then Twitch global, then third-party
/// globals by provider. Each section is name-sorted (case-insensitive) for
/// predictable browsing; the third-party sorts are memoized per emote
/// table (see `buildSections(emoteIndex:twitchGlobal:)`).
///
/// Future commits add the channel's Twitch subscriber emotes and the
/// user's subscribed-emote set (both need their own Helix fetches).
public enum EmoteCatalog {

    /// Preferred entry point. Reads the index's snapshot and publish
    /// generation atomically and reuses the sorted third-party sections
    /// while the generation is unchanged — so re-opening the picker on a
    /// channel with thousands of emotes doesn't re-run thousands of
    /// `localizedCaseInsensitiveCompare` sorts on the main thread.
    public static func buildSections(
        emoteIndex: EmoteIndex?,
        twitchGlobal: [String: TwitchEmote]
    ) -> [EmoteSection] {
        let versioned = emoteIndex?.snapshotWithGeneration()
        return assemble(
            thirdPartySections(versioned?.emotes ?? [:], generation: versioned?.generation),
            twitchGlobal: twitchGlobal)
    }

    /// Dictionary-based entry point. Also memoized: an unchanged snapshot
    /// (the same table handed back by `EmoteIndex.snapshot()`) compares
    /// equal to the cached one, so it skips the sort too.
    public static func buildSections(
        thirdParty: [String: Emote],
        twitchGlobal: [String: TwitchEmote]
    ) -> [EmoteSection] {
        assemble(thirdPartySections(thirdParty, generation: nil), twitchGlobal: twitchGlobal)
    }

    // MARK: - Memo

    /// The expensive, third-party half of the picker (channel set + the
    /// per-provider globals — thousands of emotes on big channels).
    private struct ThirdPartySections: Sendable {
        let channel: EmoteSection?
        let globals: [EmoteSection]
    }

    private struct Memo: Sendable {
        /// `EmoteIndex.generation` the sections were built from; `nil` when
        /// built from a bare dictionary. Generations are process-wide
        /// unique, so equal generations mean the same table.
        let generation: Int?
        let thirdParty: [String: Emote]
        let sections: ThirdPartySections
    }

    /// Single-entry memo (one picker is open at a time). Lock-protected so
    /// `buildSections` stays callable from any isolation.
    private static let memo = OSAllocatedUnfairLock<Memo?>(initialState: nil)

    private static func thirdPartySections(
        _ thirdParty: [String: Emote],
        generation: Int?
    ) -> ThirdPartySections {
        if let cached = memo.withLock({ $0 }) {
            if let generation, cached.generation == generation {
                return cached.sections
            }
            // Different/unknown generation: fall back to content equality
            // (cheap when it's the same dictionary storage).
            if cached.thirdParty == thirdParty {
                return cached.sections
            }
        }
        let built = buildThirdPartySections(thirdParty)
        let entry = Memo(generation: generation, thirdParty: thirdParty, sections: built)
        memo.withLock { $0 = entry }
        return built
    }

    // MARK: - Building

    /// Section order is: channel emotes, Twitch global, then third-party
    /// globals by provider.
    private static func assemble(
        _ thirdParty: ThirdPartySections,
        twitchGlobal: [String: TwitchEmote]
    ) -> [EmoteSection] {
        var sections: [EmoteSection] = []

        // 1. Channel emotes (third-party with an owner). The big draw —
        //    the channel's curated 7TV/BTTV/FFZ set.
        if let channel = thirdParty.channel {
            sections.append(channel)
        }

        // 2. Twitch global (Kappa, LUL, etc.). A few hundred entries —
        //    cheap enough to sort per open.
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
        sections.append(contentsOf: thirdParty.globals)

        return sections
    }

    private static func buildThirdPartySections(_ thirdParty: [String: Emote]) -> ThirdPartySections {
        let allThirdParty = Array(thirdParty.values)

        let channelEmotes = allThirdParty.filter { $0.ownerChannelId != nil }
        let channel: EmoteSection? = channelEmotes.isEmpty ? nil : EmoteSection(
            id: "channel",
            title: "Channel Emotes",
            emotes: sortedPickerEmotes(channelEmotes)
        )

        var globals: [EmoteSection] = []
        let globalThirdParty = allThirdParty.filter { $0.ownerChannelId == nil }
        for source in Emote.Source.allCases {
            let group = globalThirdParty.filter { $0.source == source }
            guard !group.isEmpty else { continue }
            globals.append(EmoteSection(
                id: "global-\(source.rawValue)",
                title: "\(sourceLabel(source)) Global",
                emotes: sortedPickerEmotes(group)
            ))
        }

        return ThirdPartySections(channel: channel, globals: globals)
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
