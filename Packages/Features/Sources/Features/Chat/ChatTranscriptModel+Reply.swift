import ChatModel

// Reply and thread helpers: the reply-intent payload plus the pure,
// side-effect-free functions that decide how a reply chip reads and where a
// message sits in a thread. Static so `ThreadView` (and tests) use the exact
// same construction as the main compose bar.

extension ChatTranscriptModel {

    /// Payload for an in-flight reply intent. Held by `replyContext`;
    /// passed to `ChannelSession.send` as `replyParentMessageId` when the
    /// user finally taps Send.
    public struct ReplyContext: Sendable, Equatable {
        public let parentMessageId: String
        public let parentAuthorDisplayName: String
        public let parentSnippet: String      // already-truncated so the view doesn't need to
        /// The root of the thread this reply belongs to. For replies to a
        /// top-level message, this equals `parentMessageId`. For
        /// replies-to-replies mid-thread, this equals the original thread
        /// root (walked from the parent's own `replyParent`).
        ///
        /// Stamped onto the optimistic row's `ChatLine.ReplyParent` so the
        /// thread sheet groups the row correctly BEFORE the echo replaces it
        /// with Twitch's authoritative `threadMessageId` — otherwise an
        /// optimistic mid-thread reply renders as its own singleton thread
        /// until the echo lands.
        public let threadRootMessageId: String

        public init(
            parentMessageId: String,
            parentAuthorDisplayName: String,
            parentSnippet: String,
            threadRootMessageId: String
        ) {
            self.parentMessageId = parentMessageId
            self.parentAuthorDisplayName = parentAuthorDisplayName
            self.parentSnippet = parentSnippet
            self.threadRootMessageId = threadRootMessageId
        }

        /// Recovers the intent from a row's reply attachment — how a retried
        /// failed reply threads against the same parent. The attachment
        /// already carries the resolved thread root, so nothing is re-walked.
        init(_ replyParent: ChatLine.ReplyParent) {
            self.init(
                parentMessageId: replyParent.parentMessageId,
                parentAuthorDisplayName: replyParent.parentAuthorDisplayName,
                parentSnippet: replyParent.parentBody,
                threadRootMessageId: replyParent.threadRootMessageId
            )
        }

        /// The attachment an optimistic reply row carries.
        var replyParent: ChatLine.ReplyParent {
            ChatLine.ReplyParent(
                parentMessageId: parentMessageId,
                parentAuthorDisplayName: parentAuthorDisplayName,
                parentBody: parentSnippet,
                threadRootMessageId: threadRootMessageId
            )
        }
    }

    /// Returns the thread root id for a given line. If the line is itself a
    /// reply, the thread root is `replyParent.threadRootMessageId`; if not,
    /// the line itself is the candidate root.
    ///
    /// "Candidate" because a single line can't tell whether it has actually
    /// been replied to. The View Thread menu item doesn't need the
    /// distinction: the sheet handles a singleton thread the same way it
    /// handles a 50-message one.
    public static func threadRoot(of line: ChatLine) -> String {
        line.replyParent?.threadRootMessageId ?? line.id
    }

    /// Factory: build a `ReplyContext` from any line. Used by `beginReply`
    /// (main compose bar) AND by `ThreadView` (the thread sheet's compose
    /// bar replies to the latest thread message), so callers don't need to
    /// know how the snippet is built.
    public static func replyContext(for line: ChatLine) -> ReplyContext {
        // Replying to a reply continues ITS thread (same root); otherwise
        // the line itself roots the thread.
        ReplyContext(
            parentMessageId: line.id,
            parentAuthorDisplayName: line.authorDisplayName,
            parentSnippet: snippet(from: line.runs, cap: 80),
            threadRootMessageId: threadRoot(of: line)
        )
    }

    /// A short, single-line preview of a message's runs for the reply chip:
    /// each run's visual plain text (`LineRun.plainText`), joined with single
    /// spaces (runs are word-level), capped with an ellipsis.
    static func snippet(from runs: [LineRun], cap: Int) -> String {
        var out = ""
        for run in runs {
            let piece = run.plainText(.visual)
            if piece.isEmpty { continue }
            if !out.isEmpty { out += " " }
            out += piece
            if out.count >= cap { break }
        }
        if out.count > cap {
            // `prefix(cap)` cuts on Character boundaries — safe for grapheme
            // clusters (emoji, combining marks).
            return String(out.prefix(cap)) + "…"
        }
        return out
    }
}
