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
    /// "(twitch.tv/foo)." still links.
    private static let trailingTrim: Set<Character> = [".", ",", "!", "?", ";", ":", ")", "]", "}", "'", "\""]
    private static let leadingTrim: Set<Character> = ["(", "[", "{", "'", "\""]

    /// The URL `word` points at, or nil when it isn't a link.
    public static func url(in word: String) -> URL? {
        // Fast reject: every accepted form contains a dot. Most chat words
        // don't, so this keeps the per-row cost to one byte scan.
        guard word.utf8.contains(UInt8(ascii: ".")) else { return nil }

        var candidate = Substring(word)
        while let last = candidate.last, trailingTrim.contains(last) { candidate = candidate.dropLast() }
        while let first = candidate.first, leadingTrim.contains(first) { candidate = candidate.dropFirst() }
        guard candidate.count >= 4 else { return nil }

        let lower = candidate.lowercased()
        if lower.hasPrefix("https://") || lower.hasPrefix("http://") {
            guard let url = URL(string: String(candidate)),
                  let host = url.host, host.contains(".") else { return nil }
            return url
        }

        let hostEnd = lower.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? lower.endIndex
        let labels = lower[..<hostEnd].split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2,
              labels.allSatisfy({ label in
                  !label.isEmpty && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
              }),
              let tld = labels.last
        else { return nil }
        guard lower.hasPrefix("www.") || bareDomainTLDs.contains(String(tld)) else { return nil }
        return URL(string: "https://" + candidate)
    }
}
