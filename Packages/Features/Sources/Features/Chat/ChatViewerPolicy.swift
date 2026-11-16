import TwitchKit
import ChatModel

/// What one viewer's attach does to each session row, on top of the session's
/// shared normalization: drop messages the chat filters hide, and layer the
/// viewer's highlight keywords onto the session's self-mention flag.
///
/// Snapshotted once per attach and consulted by every ingest path — live
/// arrivals and replayed history alike — so a mid-session settings change
/// can't make the two drift; changes apply on the next attach.
///
/// Why this lives with the transcript rather than the session: a session's
/// rows are shared by every tab showing the channel, so baking one tab's
/// keywords into them would leak into the others. The per-row cost is one
/// branch for the default empty matcher, a lowercase-contains per word
/// otherwise.
struct ChatViewerPolicy {

    /// The chat-filter toggles (You → Chat → Filters) at attach time.
    struct Filters: Equatable, Sendable {
        var hideCommands = false
        var hideBots = false
    }

    /// The viewer's own messages are never filtered — hiding your own
    /// "!drops" the moment you send it reads as a send failure.
    var viewerUserId: String
    var filters: Filters
    var highlightMatcher: HighlightMatcher

    /// Shows everything, highlights nothing extra — an un-attached model.
    init() {
        self.init(viewerUserId: "", filters: Filters(), highlightKeywords: [])
    }

    init(viewerUserId: String, filters: Filters, highlightKeywords: [String]) {
        self.viewerUserId = viewerUserId
        self.filters = filters
        self.highlightMatcher = HighlightMatcher(keywords: highlightKeywords)
    }

    /// Whether `message` should be dropped before it touches the transcript —
    /// before echo reconciliation, ingest, and the highlight sound.
    func hides(_ message: ChatMessage) -> Bool {
        guard message.chatterUserId != viewerUserId else { return false }
        return ChatFilterSettings.shouldHide(
            authorLogin: message.chatterUserLogin,
            text: message.message.text,
            hideCommands: filters.hideCommands,
            hideBots: filters.hideBots
        )
    }

    /// The row as this viewer sees it: the session's line plus this attach's
    /// keyword highlight. Message rows only — bubbles are never highlighted.
    func presenting(_ line: ChatLine) -> ChatLine {
        guard !line.isHighlighted,
              !highlightMatcher.isEmpty,
              case .message = line.kind,
              highlightMatcher.matches(line.runs) else { return line }
        var highlighted = line
        highlighted.isHighlighted = true
        return highlighted
    }
}
