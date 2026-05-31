import Foundation
import EmoteSources
import TwitchKit
import Core

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
/// top (what people actually want), then third-party globals by provider,
/// then Twitch global. Each section is name-sorted (case-insensitive) for
/// predictable browsing.
///
/// Future commits add the channel's Twitch subscriber emotes and the
/// user's subscribed-emote set (both need their own Helix fetches).
public enum EmoteCatalog {

    public static func buildSections(
        thirdParty: [String: Emote],
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
