import Foundation

extension LineRun {

    /// How a run should read when flattened to plain text.
    public enum PlainTextStyle: Sendable {
        /// What the reader sees, condensed — the reply chip's snippet:
        /// a cheermote reads `cheer100`.
        case visual
        /// What VoiceOver should say — the row's accessibility label:
        /// a cheermote reads `cheer 100 bits`.
        case spoken
    }

    /// The run as plain text: a word stays itself, an emote becomes its
    /// name, a mention becomes `@login`, a cheermote its prefix and bit
    /// count (spelled out for `.spoken`).
    ///
    /// The single run → text mapping shared by every place a message is
    /// flattened (reply snippets, VoiceOver labels), so a new run case only
    /// has to be taught here. Runs are word-level, so callers join pieces
    /// with single spaces.
    public func plainText(_ style: PlainTextStyle = .visual) -> String {
        switch self {
        case .text(let word):
            return word
        case .emote(let emote):
            return emote.name
        case .twitchEmote(_, let displayName):
            return displayName
        case .mention(let login, _):
            return "@\(login)"
        case .cheermote(let prefix, let bits, _):
            switch style {
            case .visual: return "\(prefix)\(bits)"
            case .spoken: return "\(prefix) \(bits) bits"
            }
        }
    }
}
