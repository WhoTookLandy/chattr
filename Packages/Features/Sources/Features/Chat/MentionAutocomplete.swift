import ChatModel
import Foundation

/// Pure logic behind the compose bar's `@` suggestions: spotting the mention
/// being typed, building the pool of people to suggest, ranking matches, and
/// splicing the pick back into the draft. No SwiftUI, so it's unit-tested
/// directly (`MentionAutocompleteTests`).
///
/// SwiftUI's `TextField` doesn't expose the caret, so the "mention being
/// typed" is the draft's LAST token — which is where the caret is in chat
/// (you type forwards, then send) in practice.
enum MentionAutocomplete {
    struct Candidate: Equatable, Hashable, Sendable {
        /// Lowercase Twitch login — the unique handle.
        let login: String
        let displayName: String
        /// Hex name colour ("#FF0000"), or empty for the default.
        let color: String

        /// What gets inserted after the "@". The display name when it's just
        /// a re-cased login (what people expect to see), otherwise the login —
        /// a localized display name ("정서이") doesn't ping anyone.
        var insertionName: String {
            displayName.lowercased() == login ? displayName : login
        }
    }

    /// The query of the mention being typed (the text after "@", possibly
    /// empty), or nil when the draft's last token isn't a mention.
    static func activeQuery(in text: String) -> String? {
        guard let last = text.last, !last.isWhitespace else { return nil }
        let token = text.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
        guard token.first == "@" else { return nil }
        let query = token.dropFirst()
        // "@@" or "@foo@bar" isn't a mention someone is typing.
        guard !query.contains("@") else { return nil }
        return String(query)
    }

    /// Everyone worth suggesting, most recently active first: chatters from
    /// the transcript (newest message wins), then the broadcaster if they
    /// haven't spoken. Excludes the signed-in user.
    static func pool(
        from lines: [ChatLine],
        broadcasterLogin: String,
        broadcasterDisplayName: String,
        excludingLogin selfLogin: String
    ) -> [Candidate] {
        var seen: Set<String> = []
        if !selfLogin.isEmpty { seen.insert(selfLogin.lowercased()) }
        var out: [Candidate] = []
        for line in lines.reversed() {
            guard case .message = line.kind else { continue }
            let login = line.authorUserLogin.lowercased()
            guard !login.isEmpty, seen.insert(login).inserted else { continue }
            out.append(Candidate(
                login: login,
                displayName: line.authorDisplayName.isEmpty ? login : line.authorDisplayName,
                color: line.authorColor
            ))
        }
        let broadcaster = broadcasterLogin.lowercased()
        if !broadcaster.isEmpty, seen.insert(broadcaster).inserted {
            out.append(Candidate(
                login: broadcaster,
                displayName: broadcasterDisplayName.isEmpty ? broadcaster : broadcasterDisplayName,
                color: ""
            ))
        }
        return out
    }

    /// Matches for `query`, best first: prefix matches (in pool order, i.e.
    /// most recently active first) before substring matches. An empty query
    /// returns the most recent chatters.
    static func suggestions(for query: String, in pool: [Candidate], limit: Int = 8) -> [Candidate] {
        let q = query.lowercased()
        guard !q.isEmpty else { return Array(pool.prefix(limit)) }
        var prefix: [Candidate] = []
        var contains: [Candidate] = []
        for c in pool {
            let display = c.displayName.lowercased()
            if c.login.hasPrefix(q) || display.hasPrefix(q) {
                prefix.append(c)
                if prefix.count == limit { break }
            } else if contains.count < limit, c.login.contains(q) || display.contains(q) {
                contains.append(c)
            }
        }
        // An exact, complete match is still worth showing (it confirms the
        // name and adds the trailing space), so no special-casing.
        return Array((prefix + contains).prefix(limit))
    }

    /// Replace the draft's trailing "@query" with "@name " (trailing space so
    /// the next word doesn't fuse onto the mention).
    static func complete(_ text: String, with candidate: Candidate) -> String {
        guard activeQuery(in: text) != nil,
              let at = text.lastIndex(of: "@") else { return text }
        return String(text[..<at]) + "@" + candidate.insertionName + " "
    }
}
