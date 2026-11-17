import Foundation

/// Recognises Twitch clip links so chat can open them in the in-app clip
/// player instead of handing them to Safari.
///
/// Accepted forms (any scheme, `www.` / `m.` hosts included):
///
///   - `clips.twitch.tv/<Slug>`
///   - `clips.twitch.tv/embed?clip=<Slug>`
///   - `twitch.tv/<channel>/clip/<Slug>`
///   - `twitch.tv/clip/<Slug>` and `twitch.tv/clips/<Slug>`
///
/// Anything else — a channel's clip *list* (`twitch.tv/<channel>/clips`),
/// `clips.twitch.tv/create`, a non-Twitch host — returns nil and keeps
/// opening the normal way. Pure and allocation-light: it runs on tap, not
/// per row render.
public enum TwitchClipLink {

    /// The clip's slug when `url` points at a single Twitch clip.
    public static func slug(in url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        let components = url.pathComponents.filter { $0 != "/" }

        if host == "clips.twitch.tv" {
            if components.first?.lowercased() == "embed" {
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
                return validated(query?.first { $0.name == "clip" }?.value)
            }
            guard components.count == 1 else { return nil }
            return validated(components[0])
        }

        guard twitchHosts.contains(host) else { return nil }
        // `/<channel>/clip/<slug>`, `/clip/<slug>`, `/clips/<slug>`.
        guard let marker = components.firstIndex(where: { segment in
                  let lower = segment.lowercased()
                  return lower == "clip" || lower == "clips"
              }),
              marker <= 1,
              components.indices.contains(marker + 1)
        else { return nil }
        // `/clips/<slug>` only at the root — `/<channel>/clips/…` is the
        // channel's clip browser, not a clip.
        if components[marker].lowercased() == "clips", marker != 0 { return nil }
        return validated(components[marker + 1])
    }

    private static let twitchHosts: Set<String> = ["twitch.tv", "www.twitch.tv", "m.twitch.tv"]

    /// Clip slugs are `Word-Word-Word-randomTail` (or legacy all-letters
    /// ids): letters, digits, `-` and `_`. Reserved paths are rejected.
    private static func validated(_ candidate: String?) -> String? {
        guard let candidate, (1...120).contains(candidate.count) else { return nil }
        guard candidate.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else { return nil }
        guard !reserved.contains(candidate.lowercased()) else { return nil }
        return candidate
    }

    private static let reserved: Set<String> = ["create", "embed", "api", "clips", "clip"]
}
