import Testing
import Foundation
import EmoteSources
import TwitchKit
@testable import Features

@Suite("Emote image source")
struct EmoteImageSourceTests {

    private func thirdParty(
        animated: Bool,
        urls: [Emote.Size: String] = [.x1: "https://cdn.test/a/1x", .x2: "https://cdn.test/a/2x", .x4: "https://cdn.test/a/4x"],
        staticURLs: [Emote.Size: String]? = nil
    ) -> Emote {
        Emote(
            id: "ffz:1", name: "Dance",
            urls: urls.compactMapValues { URL(string: $0) },
            isAnimated: animated, isZeroWidth: false, source: .ffz,
            staticURLs: staticURLs?.compactMapValues { URL(string: $0) })
    }

    private func twitchEmote(id: String, formats: [String]) throws -> TwitchEmote {
        let json: [String: Any] = [
            "id": id, "name": "Emote\(id)", "format": formats, "scale": ["1.0", "2.0", "3.0"], "themeMode": ["dark", "light"],
        ]
        return try JSONDecoder().decode(TwitchEmote.self, from: JSONSerialization.data(withJSONObject: json))
    }

    // MARK: - Twitch

    @Test("An animated Twitch emote loads the animated file through the frame decoder")
    func twitchAnimated() {
        let source = EmoteImageSource.twitch(id: "42", formats: ["static", "animated"])
        #expect(source.url?.absoluteString == "https://static-cdn.jtvnw.net/emoticons/v2/42/animated/dark/2.0")
        #expect(source.isAnimated)
    }

    @Test("With animation off, an animated Twitch emote loads its static variant as a plain image")
    func twitchAnimatedButStill() {
        let source = EmoteImageSource.twitch(id: "42", formats: ["static", "animated"], animate: false)
        #expect(source.url?.absoluteString == "https://static-cdn.jtvnw.net/emoticons/v2/42/static/dark/2.0")
        #expect(!source.isAnimated)
    }

    @Test("A static-only Twitch emote is the same either way")
    func twitchStatic() {
        let animating = EmoteImageSource.twitch(id: "25", formats: ["static"])
        #expect(animating.url?.absoluteString == "https://static-cdn.jtvnw.net/emoticons/v2/25/static/dark/2.0")
        #expect(!animating.isAnimated)
        #expect(animating == EmoteImageSource.twitch(id: "25", formats: ["static"], animate: false))
    }

    // MARK: - Third-party

    @Test("Third-party emotes prefer the 2x file, then 1x, then 4x")
    func thirdPartySizePreference() {
        #expect(EmoteImageSource.thirdParty(thirdParty(animated: false)).url?.absoluteString == "https://cdn.test/a/2x")
        #expect(EmoteImageSource.thirdParty(thirdParty(
            animated: false, urls: [.x1: "https://cdn.test/a/1x", .x4: "https://cdn.test/a/4x"]
        )).url?.absoluteString == "https://cdn.test/a/1x")
        #expect(EmoteImageSource.thirdParty(thirdParty(
            animated: false, urls: [.x4: "https://cdn.test/a/4x"]
        )).url?.absoluteString == "https://cdn.test/a/4x")
        #expect(EmoteImageSource.thirdParty(thirdParty(animated: false, urls: [:])).url == nil)
    }

    @Test("With animation off, a provider's static file replaces the animated one")
    func thirdPartyStaticVariant() {
        let emote = thirdParty(animated: true, staticURLs: [.x2: "https://cdn.test/a/static/2x"])

        let still = EmoteImageSource.thirdParty(emote, animate: false)
        #expect(still.url?.absoluteString == "https://cdn.test/a/static/2x")
        #expect(!still.isAnimated)

        let moving = EmoteImageSource.thirdParty(emote, animate: true)
        #expect(moving.url?.absoluteString == "https://cdn.test/a/2x")
        #expect(moving.isAnimated)
    }

    @Test("Without a static file, animation off keeps the animated file for its poster frame")
    func thirdPartyNoStaticVariant() {
        let source = EmoteImageSource.thirdParty(thirdParty(animated: true), animate: false)
        #expect(source.url?.absoluteString == "https://cdn.test/a/2x")
        #expect(source.isAnimated)
    }

    // MARK: - One rule for every surface

    @Test("The picker shows the same still a row shows with animation off")
    func pickerMatchesStillRows() throws {
        let twitch = try twitchEmote(id: "42", formats: ["static", "animated"])
        let pickerTwitch = PickerEmote(twitch: twitch)
        let rowTwitch = EmoteImageSource.twitch(id: twitch.id, formats: twitch.format, animate: false)
        #expect(pickerTwitch.imageURL == rowTwitch.url)
        #expect(pickerTwitch.isAnimated == rowTwitch.isAnimated)

        let emote = thirdParty(animated: true, staticURLs: [.x2: "https://cdn.test/a/static/2x"])
        let pickerEmote = PickerEmote(emote)
        let rowEmote = EmoteImageSource.thirdParty(emote, animate: false)
        #expect(pickerEmote.imageURL == rowEmote.url)
        #expect(pickerEmote.isAnimated == rowEmote.isAnimated)
    }
}

/// `EmoteCatalog` keeps one memo for the whole process, so everything that
/// builds sections lives in this one serialized suite.
@Suite("Emote picker sections", .serialized)
struct EmotePickerSectionTests {

    private func twitchGlobals(_ names: [String]) throws -> [String: TwitchEmote] {
        var globals: [String: TwitchEmote] = [:]
        for (index, name) in names.enumerated() {
            let json: [String: Any] = [
                "id": "\(index)", "name": name, "format": ["static"], "scale": ["1.0"], "themeMode": ["dark"],
            ]
            globals["\(index)"] = try JSONDecoder().decode(
                TwitchEmote.self, from: JSONSerialization.data(withJSONObject: json))
        }
        return globals
    }

    @Test("The first build for a table is handed over as a stand-in and resolves to sorted sections")
    func firstBuildResolvesOffMain() async throws {
        let globals = try twitchGlobals(["zeta-\(UUID().uuidString)", "Alpha", "beta"])

        let first = EmoteCatalog.buildSections(emoteIndex: nil, twitchGlobal: globals)
        #expect(first.first?.pendingBuild != nil, "nothing is sorted on the calling thread")

        let resolved = await EmoteCatalog.resolve(first)
        #expect(resolved.map(\.id) == ["twitch-global"])
        #expect(resolved.first?.emotes.map(\.name).prefix(2) == ["Alpha", "beta"])

        // Same tables again: served from the memo, complete.
        let second = EmoteCatalog.buildSections(emoteIndex: nil, twitchGlobal: globals)
        #expect(second == resolved)
    }

    @Test("Sections that are already complete resolve to themselves")
    func completeSectionsResolveToThemselves() async throws {
        let globals = try twitchGlobals(["Solo-\(UUID().uuidString)"])
        let complete = EmoteCatalog.buildSections(thirdParty: [:], twitchGlobal: globals)
        #expect(complete.first?.pendingBuild == nil)
        #expect(await EmoteCatalog.resolve(complete) == complete)
    }

    @Test("Full catalog orders recents, current channel Twitch + 3P by provider, sub channels, unlocked, and globals")
    func fullCatalogSectionOrderingAndGrouping() throws {
        let globalKappa = try JSONDecoder().decode(
            TwitchEmote.self,
            from: JSONSerialization.data(withJSONObject: [
                "id": "25", "name": "Kappa", "format": ["static"], "scale": ["1.0"], "themeMode": ["dark"],
            ])
        )
        let followerEmote = try JSONDecoder().decode(
            TwitchEmote.self,
            from: JSONSerialization.data(withJSONObject: [
                "id": "f1", "name": "curFollow", "format": ["static"], "scale": ["1.0"], "themeMode": ["dark"],
                "emoteType": "follower", "emoteSetId": "set-f",
            ])
        )
        let sevenTVChan = Emote(
            id: "7tv:c1", name: "catJAM",
            urls: [.x2: URL(string: "https://cdn.7tv.app/emote/c1/2x.webp")!],
            isAnimated: true, isZeroWidth: false, source: .sevenTV, ownerChannelId: "100",
            staticURLs: [.x2: URL(string: "https://cdn.7tv.app/emote/c1/2x_static.webp")!]
        )
        let bttvChan = Emote(
            id: "bttv:c2", name: "POGGERS",
            urls: [.x2: URL(string: "https://cdn.betterttv.net/emote/c2/2x")!],
            isAnimated: false, isZeroWidth: false, source: .bttv, ownerChannelId: "100"
        )
        let sevenTVGlobal = Emote(
            id: "7tv:g1", name: "Clap",
            urls: [.x2: URL(string: "https://cdn.7tv.app/emote/g1/2x.webp")!],
            isAnimated: false, isZeroWidth: false, source: .sevenTV, ownerChannelId: nil
        )

        let userEmotes: [UserTwitchEmote] = [
            UserTwitchEmote(id: "sub-cur", name: "curSub", emoteType: "subscriptions", ownerId: "100", format: ["static", "animated"]),
            UserTwitchEmote(id: "sub-b", name: "betaSub", emoteType: "subscriptions", ownerId: "300"),
            UserTwitchEmote(id: "sub-a", name: "alphaSub", emoteType: "subscriptions", ownerId: "200"),
            // Follower emote from ANOTHER channel should be filtered out.
            UserTwitchEmote(id: "other-follow", name: "otherFollow", emoteType: "follower", ownerId: "200"),
            // Prime unlocked emote (ownerId "0") goes in Unlocked, not duplicated in Globals.
            UserTwitchEmote(id: "prime-1", name: "PrimeMe", emoteType: "prime", ownerId: "0"),
            // Duplicate of global Kappa should not appear in Unlocked.
            UserTwitchEmote(id: "25", name: "Kappa", emoteType: "globals", ownerId: "0"),
        ]

        let owners: [String: EmoteChannelInfo] = [
            "200": EmoteChannelInfo(id: "200", login: "alpha", displayName: "AlphaTV", profileImageURL: URL(string: "https://img/a.png")),
            "300": EmoteChannelInfo(id: "300", login: "zeta", displayName: "ZetaStream", profileImageURL: URL(string: "https://img/z.png")),
        ]

        let input = EmoteCatalog.BuildInput(
            channelId: "100",
            channelDisplayName: "CurrentChan",
            channelAvatarURL: URL(string: "https://img/cur.png"),
            recentEmotes: [PickerEmote(id: "r1", name: "RecentOne")],
            thirdParty: [
                "catJAM": sevenTVChan,
                "POGGERS": bttvChan,
                "Clap": sevenTVGlobal,
            ],
            thirdPartyGeneration: 10,
            twitchGlobal: ["25": globalKappa],
            twitchGlobalVersion: 1,
            userEmotes: userEmotes,
            userEmoteOwners: owners,
            userEmotesVersion: 1,
            channelTwitchEmotes: [followerEmote],
            channelTwitchVersion: 1,
            isFollowingChannel: true,
            isBroadcaster: false
        )

        let sections = EmoteCatalog.buildSections(from: input)

        #expect(sections.map(\.id) == [
            "recent",
            "channel-twitch-100",
            "channel-sevenTV",
            "channel-bttv",
            "sub-200",
            "sub-300",
            "twitch-unlocked",
            "twitch-global",
            "global-sevenTV",
        ])

        // Current channel Twitch includes both sub emote and unlocked follower emote.
        #expect(sections[1].emotes.map(\.name) == ["curFollow", "curSub"])
        #expect(sections[1].avatarURL?.absoluteString == "https://img/cur.png")

        // Subscribed channels sorted alphabetically, excluding other-channel follower emotes.
        #expect(sections[4].title == "AlphaTV")
        #expect(sections[4].emotes.map(\.name) == ["alphaSub"])
        #expect(sections[5].title == "ZetaStream")
        #expect(sections[5].emotes.map(\.name) == ["betaSub"])

        // Unlocked holds PrimeMe and does not duplicate global Kappa.
        #expect(sections[6].emotes.map(\.name) == ["PrimeMe"])

        // Fast O(1) cache hit returns the exact built sections.
        #expect(EmoteCatalog.cachedSections(for: input) == sections)
    }

    @Test("Search ranks prefix matches first and omits the duplicate Recently Used section")
    func searchRankingAndRecentOmission() {
        let sections = [
            EmoteSection(id: "recent", title: "Recently Used", kind: .recent, emotes: [
                PickerEmote(id: "1", name: "PepeLaugh"),
            ]),
            EmoteSection(id: "channel-sevenTV", title: "7TV Channel", kind: .channelThirdParty(.sevenTV), emotes: [
                PickerEmote(id: "2", name: "WidePepeHappy"),
                PickerEmote(id: "1", name: "PepeLaugh"),
                PickerEmote(id: "3", name: "KEKW"),
            ]),
        ]

        let filtered = EmoteCatalog.filter(sections, needle: "pepe")
        #expect(filtered.map(\.id) == ["channel-sevenTV"])
        #expect(filtered.first?.emotes.map(\.name) == ["PepeLaugh", "WidePepeHappy"])
    }

    @Test("UserEmoteStore decodes Helix /chat/emotes/user JSON including owner_id and cursor")
    func userEmotePageDecoding() throws {
        let json = """
        {
          "data": [
            {
              "id": "emotesv2_123",
              "name": "lirikH",
              "emote_type": "subscriptions",
              "emote_set_id": "42",
              "owner_id": "23161357",
              "format": ["static", "animated"],
              "scale": ["1.0", "2.0", "3.0"],
              "theme_mode": ["dark", "light"]
            },
            {
              "id": "25",
              "name": "Kappa"
            }
          ],
          "pagination": {
            "cursor": "eyJiIjpudWxsfQ"
          }
        }
        """.data(using: .utf8)!

        let decoded = try UserEmoteStore.decodePage(json)
        #expect(decoded.nextCursor == "eyJiIjpudWxsfQ")
        #expect(decoded.emotes.count == 2)
        #expect(decoded.emotes[0].ownerId == "23161357")
        #expect(decoded.emotes[0].emoteType == "subscriptions")
        #expect(decoded.emotes[0].format == ["static", "animated"])
        #expect(!decoded.emotes[0].isTwitchOwned)
        // Missing optional fields fall back safely without failing decode.
        #expect(decoded.emotes[1].ownerId == "0")
        #expect(decoded.emotes[1].isTwitchOwned)
    }
}
