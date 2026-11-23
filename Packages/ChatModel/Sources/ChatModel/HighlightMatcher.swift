import Foundation

/// Case-insensitive highlight-keyword matcher over a line's word runs.
///
/// Built ONCE per keyword list (per attach) and reused for every message, so
/// the per-message work is only what the message itself requires: keywords
/// are lowercased and classified up front instead of being re-folded by a
/// `range(of:options: .caseInsensitive)` call per keyword per span.
///
/// ## Semantics (unchanged from the original `containsHighlight`)
///
/// A line matches when any contiguous span of `.text` runs, joined with a
/// single space, contains any keyword as a case-insensitive substring.
/// Non-text runs (emotes, mentions, …) end a span, so words that were never
/// adjacent can't fake a phrase match and emote names never match.
///
/// The join is only materialized for keywords that contain a space: a
/// space-free keyword can only ever match inside ONE word of the joined span
/// (word runs never carry whitespace), so those are checked word by word with
/// no join allocation at all.
///
/// Case folding: ASCII keywords against ASCII text — the overwhelming case —
/// compare via `lowercased()` + `contains`, which is exactly what
/// `.caseInsensitive` does for ASCII. Anything non-ASCII on either side falls
/// back to Foundation's `.caseInsensitive` search, so Unicode folding edge
/// cases (e.g. "ß" vs "ss") behave exactly as before.
public struct HighlightMatcher: Sendable, Equatable {

    private struct Keyword: Sendable, Equatable {
        /// As the user typed it — used for the Foundation fallback.
        let original: String
        /// ASCII-lowercased UTF-8 bytes; only meaningful when `isASCII`.
        let loweredASCIIBytes: [UInt8]
        let isASCII: Bool
    }

    /// Keywords with no space: matched per word.
    private let wordKeywords: [Keyword]
    /// Keywords containing a space: matched against each joined span.
    private let phraseKeywords: [Keyword]

    public init(keywords: [String]) {
        var words: [Keyword] = []
        var phrases: [Keyword] = []
        for keyword in keywords where keyword.contains(where: { !$0.isWhitespace }) {
            let ascii = Self.isASCII(keyword)
            let entry = Keyword(
                original: keyword,
                loweredASCIIBytes: ascii ? keyword.utf8.map(Self.asciiLower) : [],
                isASCII: ascii
            )
            if keyword.contains(" ") {
                phrases.append(entry)
            } else {
                words.append(entry)
            }
        }
        self.wordKeywords = words
        self.phraseKeywords = phrases
    }

    /// True when there is nothing to match — the common case (no keywords
    /// configured). Callers check this to skip the run walk entirely.
    public var isEmpty: Bool { wordKeywords.isEmpty && phraseKeywords.isEmpty }

    /// Whether `runs` contain any keyword (see the type doc for semantics).
    public func matches(_ runs: [LineRun]) -> Bool {
        guard !isEmpty else { return false }

        if !wordKeywords.isEmpty {
            for run in runs {
                guard case .text(let word) = run else { continue }
                if Self.contains(word, anyOf: wordKeywords) { return true }
            }
        }

        if !phraseKeywords.isEmpty {
            var span: [String] = []
            for run in runs {
                if case .text(let word) = run {
                    span.append(word)
                } else {
                    if spanMatchesPhrase(span) { return true }
                    span.removeAll(keepingCapacity: true)
                }
            }
            if spanMatchesPhrase(span) { return true }
        }
        return false
    }

    private func spanMatchesPhrase(_ span: [String]) -> Bool {
        // Phrase keywords always contain a space, which can only appear once
        // at least two adjacent words are joined.
        guard span.count >= 2 else { return false }
        return Self.contains(span.joined(separator: " "), anyOf: phraseKeywords)
    }

    /// Case-insensitive "haystack contains any keyword". ASCII vs ASCII scans
    /// raw UTF-8 bytes with zero heap allocations; non-ASCII falls back to
    /// Foundation's `.caseInsensitive` search.
    private static func contains(_ haystack: String, anyOf keywords: [Keyword]) -> Bool {
        let haystackIsASCII = isASCII(haystack)
        for keyword in keywords {
            if haystackIsASCII && keyword.isASCII {
                if asciiContainsCaseInsensitive(haystack, needle: keyword.loweredASCIIBytes) {
                    return true
                }
            } else if haystack.range(of: keyword.original, options: .caseInsensitive) != nil {
                return true
            }
        }
        return false
    }

    @inline(__always)
    private static func asciiLower(_ byte: UInt8) -> UInt8 {
        (byte >= 65 && byte <= 90) ? (byte &+ 32) : byte
    }

    private static func asciiContainsCaseInsensitive(_ haystack: String, needle: [UInt8]) -> Bool {
        let needleCount = needle.count
        guard needleCount > 0 else { return false }
        return haystack.utf8.withContiguousStorageIfAvailable { buf -> Bool in
            guard buf.count >= needleCount else { return false }
            let lastStart = buf.count - needleCount
            let firstNeedle = needle[0]
            var i = 0
            while i <= lastStart {
                if asciiLower(buf[i]) == firstNeedle {
                    var j = 1
                    while j < needleCount && asciiLower(buf[i &+ j]) == needle[j] {
                        j &+= 1
                    }
                    if j == needleCount { return true }
                }
                i &+= 1
            }
            return false
        } ?? haystack.lowercased().contains(String(decoding: needle, as: UTF8.self))
    }

    static func isASCII(_ string: String) -> Bool {
        !string.utf8.contains { $0 >= 0x80 }
    }
}
