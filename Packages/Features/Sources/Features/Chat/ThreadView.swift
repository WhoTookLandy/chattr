import SwiftUI
import ChatModel
import Channels

// MARK: - Thread sheet

/// `.sheet(item:)` requires its value-type to be `Identifiable`. We
/// wrap the thread root id String so we can pass it through
/// `@State viewingThreadRootId: ThreadRootID?`.
struct ThreadRootID: Identifiable, Equatable {
    let id: String
}

/// Modal sheet that filters chat to a single thread and offers a
/// dedicated compose bar that automatically threads against the
/// thread's latest message. Reuses `ChatRow` and `ComposeBar` for
/// visual consistency with the main chat.
///
/// Design choices:
///   - Lives in a NavigationStack with a Done button so the sheet
///     reads as a deliberate modal (not a swipe-down popover).
///   - Compose bar always threads — `replyOverride` is built from
///     the latest line in the thread, so the user doesn't need to
///     manually pick a parent for each send.
///   - Long-press inside the thread sheet does NOT offer "View
///     Thread" again (would be a no-op — we're already in it).
///   - "Reply" inside the thread sheet sets the model's reply
///     context to that specific line, then the compose bar's
///     replyOverride is preempted by it. Slightly confusing to have
///     two sources of reply intent — for MVP we just NOT offer Reply
///     inside the thread sheet either (threading is automatic, no
///     need for explicit "Reply").
///
/// Future polish (not in this commit):
///   - Scroll to the most recent message on open.
///   - Inline "View profile" / "Mention" actions on rows.
///   - Persisted scroll position so re-opening the sheet returns to
///     where you were reading.
struct ThreadView: View {
    @Environment(\.dismiss) private var dismiss

    let rootMessageId: String
    // Audit fix (axiom MEDIUM): was `@Bindable var chatModel` but no
    // bindings are created from it. @Observable references don't need
    // any wrapper to be observed — `let` is correct since ThreadView
    // never reassigns it, and dropping @Bindable removes the false
    // "this view uses bindings" signal.
    let chatModel: ChatTranscriptModel
    let badgeStore: ChatBadgeStore?
    let channelLoginName: String
    let channelDisplayName: String

    var body: some View {
        // Audit fix (axiom LOW): compute the filter result ONCE per body
        // and reuse it for both `ForEach` and the reply-target factory.
        // Previously each body call evaluated `lines(inThreadRootedAt:)`
        // twice (via the `threadLines` and `threadReplyTarget`
        // computed properties).
        let threadLines = chatModel.lines(inThreadRootedAt: rootMessageId)
        // Reply target for the thread compose bar — latest message in
        // the thread, built via the centralized factory so it matches
        // the main compose bar's reply chip formatting exactly.
        let threadReplyTarget: ChatTranscriptModel.ReplyContext? = threadLines.last.map {
            ChatTranscriptModel.replyContext(for: $0)
        }
        NavigationStack {
            VStack(spacing: 0) {
                if threadLines.isEmpty {
                    ContentUnavailableView(
                        "Thread not found",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("The original message may have aged out of the buffer.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(threadLines) { line in
                                VStack(alignment: .leading, spacing: 4) {
                                    ChatRow(
                                        line: line,
                                        badgeEntries: badgeStore?.entries(for: line.originalBadges) ?? [],
                                        // Note: deliberately no onRetry /
                                        // onReply / onViewThread inside the
                                        // thread sheet. Reply is implicit
                                        // (the compose bar threads
                                        // automatically); recursive
                                        // View Thread would be a no-op;
                                        // retry on optimistic rows still
                                        // works from the main chat view.
                                        //
                                        // Quotes are suppressed: inside a
                                        // thread, every reply's parent is
                                        // already visible above it.
                                        showsQuotedReply: false
                                    )
                                    // Thin rule under the root message so
                                    // the sheet reads "original ↑ /
                                    // replies ↓" at a glance. Only when
                                    // the root is still in the buffer AND
                                    // there's something below it.
                                    if line.id == rootMessageId, threadLines.count > 1 {
                                        Divider()
                                            .padding(.vertical, 2)
                                    }
                                }
                                .id(line.id)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    // Open at the most recent message instead of the
                    // root. Threads grow over time and the conversation
                    // context the user wants is at the bottom — opening
                    // at the top would require manual scrolling every
                    // time. `.defaultScrollAnchor(.bottom)` (iOS 17+)
                    // only affects the INITIAL anchor; subsequent
                    // scrolling behaves normally, so the user can swipe
                    // up to read the thread's history without fighting
                    // any auto-snap.
                    .defaultScrollAnchor(.bottom)
                }

                // Dedicated compose bar. The replyOverride is built
                // from `threadReplyTarget` — automatic threading
                // against the latest message in the thread, which is
                // what feels natural for "continue this conversation."
                ThreadComposeBar(
                    channelLoginName: channelLoginName,
                    channelDisplayName: channelDisplayName,
                    replyTarget: threadReplyTarget,
                    onSend: { draft in
                        await chatModel.send(
                            text: draft,
                            replyOverride: threadReplyTarget
                        )
                    }
                )
            }
            .navigationTitle("Thread")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                // `confirmationAction` placement → right side on iOS.
                // "Done" rather than "Cancel" because closing this
                // sheet isn't destructive — no input is being
                // abandoned, the user just finished reading.
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// Compose bar variant for the thread sheet. Same look as the main
/// ComposeBar but without the reply chip (threading is automatic and
/// always-on, so the chip would be redundant) and without the
/// restrictions strip (the user already saw it on the main bar).
///
/// Pulled out as a separate struct rather than reusing ComposeBar
/// because (a) ComposeBar's reply chip + restrictions strip + cancel
/// button machinery is dead weight here, and (b) the placeholder
/// text needs to read "Reply in thread" instead of "Send a message"
/// — switching ComposeBar to parameterize that one prompt seemed
/// less clean than a focused thread-specific variant.
struct ThreadComposeBar: View {
    let channelLoginName: String
    let channelDisplayName: String
    let replyTarget: ChatTranscriptModel.ReplyContext?
    let onSend: @MainActor (String) async -> Void

    @State private var composeText: String = ""
    @State private var isSending: Bool = false
    @FocusState private var focused: Bool

    /// Same trailing-slot rule as the main ComposeBar: the send button
    /// exists only while there's something to send.
    private var hasDraft: Bool {
        !composeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var prompt: String {
        if let target = replyTarget {
            return "Reply to \(target.parentAuthorDisplayName)"
        }
        return "Send to #\(channelLoginName)"
    }

    var body: some View {
        HStack(spacing: 8) {
            TextField(prompt, text: $composeText)
                .textFieldStyle(.plain)
                .focused($focused)
                .submitLabel(.send)
                .onSubmit { Task { await sendDraft() } }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: Capsule())
                .accessibilityLabel("Reply input")
                .accessibilityHint("Type a reply to send to \(channelDisplayName)")

            if hasDraft {
                Button {
                    Task { await sendDraft() }
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .padding(2)
                }
                .buttonStyle(.glassProminent)
                .tint(Color.accentColor)
                .disabled(isSending)
                .transition(.blurReplace)
                .accessibilityLabel("Send reply")
            }
        }
        .animation(.snappy(duration: 0.2), value: hasDraft)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func sendDraft() async {
        let draft = composeText
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !isSending else { return }
        isSending = true
        defer { isSending = false }
        composeText = ""
        await onSend(draft)
    }
}
