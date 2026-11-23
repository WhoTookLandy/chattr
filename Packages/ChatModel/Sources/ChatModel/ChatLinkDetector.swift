import Foundation

/// Decides whether one whitespace-delimited chat word is a link, and if so
/// which URL to open. Chat text arrives pre-split into words (`LineRun.text`
/// is one word), so this works per word rather than scanning whole messages —
/// no `NSDataDetector`, which is far too heavy to run per row render.
///
/// Deliberately conservative: an explicit `http(s)://` scheme, a `www.`
/// prefix, or a bare `host.tld[/path]` whose TLD is on a short list of ones
/// that actually show up in Twitch chat. Words like "e.g.", "1.5" or
/// "lol...ok" must never turn into links.
public enum ChatLinkDetector {

    /// TLDs accepted for scheme-less, `www`-less words ("twitch.tv/foo",
    /// "youtu.be/x"). Kept short on purpose — a false positive underlines
    /// ordinary chat text, a false negative just leaves a word plain.
    static let bareDomainTLDs: Set<String> = [
        "com", "net", "org", "tv", "gg", "io", "co", "me", "ly", "be", "gl",
        "app", "dev", "xyz", "uk", "au", "nz", "ca", "de", "fr", "jp", "us",
        "info", "link", "live", "store", "shop", "fm", "to", "sh", "ai",
    ]

    /// Punctuation peeled off a word's edges before testing it, so
    /// "(twitch.tv/foo)." still links. Closing brackets are peeled only when
    /// unmatched inside the candidate, preserving URLs like Wikipedia links
    /// that end in balanced parentheses.
    private static let unconditionalTrailingTrim: Set<Character> = [".", ",", "!", "?", ";", ":", "'", "\""]
    private static let leadingTrim: Set<Character> = ["(", "[", "{", "'", "\""]

    /// The URL `word` points at, or nil when it isn't a link.
    public static func url(in word: String) -> URL? {
        // Fast reject: every accepted form contains a dot. Most chat words
        // don't, so this keeps the per-row cost to one byte scan.
        guard word.utf8.contains(UInt8(ascii: ".")) else { return nil }

        var candidate = Substring(word)
        while let first = candidate.first, leadingTrim.contains(first) { candidate = candidate.dropFirst() }
        while let last = candidate.last {
            if unconditionalTrailingTrim.contains(last) {
                candidate = candidate.dropLast()
            } else if let open = matchingOpeningBracket(for: last),
                      !hasBalancedBracket(open: open, close: last, in: candidate) {
                candidate = candidate.dropLast()
            } else {
                break
            }
        }
        // Re-check for a dot AFTER trimming trailing punctuation so ordinary
        // sentence-ending words ("hello.", "really...") reject without
        // allocating `lowercased()` or splitting labels.
        guard candidate.count >= 4, candidate.utf8.contains(UInt8(ascii: ".")) else { return nil }

        let lower = candidate.lowercased()
        if lower.hasPrefix("https://") || lower.hasPrefix("http://") {
            guard let url = URL(string: String(candidate)),
                  let host = url.host,
                  Self.hasValidHostLabels(host) else { return nil }
            return url
        }

        let hostEnd = lower.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? lower.endIndex
        let host = lower[..<hostEnd]
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2,
              labels.allSatisfy(Self.isValidHostLabel),
              let tld = labels.last
        else { return nil }
        let isValidWww = lower.hasPrefix("www.") && labels.count >= 3
        guard isValidWww || bareDomainTLDs.contains(String(tld)) else { return nil }
        return URL(string: "https://" + candidate)
    }

    private static func matchingOpeningBracket(for closing: Character) -> Character? {
        switch closing {
        case ")": return "("
        case "]": return "["
        case "}": return "{"
        default: return nil
        }
    }

    private static func hasBalancedBracket(open: Character, close: Character, in s: Substring) -> Bool {
        var depth = 0
        for ch in s {
            if ch == open { depth += 1 }
            else if ch == close { depth -= 1 }
        }
        return depth >= 0
    }

    private static func hasValidHostLabels(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 2 && labels.allSatisfy(isValidHostLabel)
    }

    private static func isValidHostLabel(_ label: Substring) -> Bool {
        guard !label.isEmpty, label.first != "-", label.last != "-" else { return false }
        return label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
}
