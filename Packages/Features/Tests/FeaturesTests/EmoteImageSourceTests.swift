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
}
