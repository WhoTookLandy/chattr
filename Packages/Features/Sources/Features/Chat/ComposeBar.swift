import Channels
import DesignSystem
import SwiftUI

// MARK: - ComposeBar

/// Bottom-pinned text input + send button for chat. Lives in its own
/// `View` struct so the draft `@State` is isolated from the parent
/// `ChatScreen`'s body — every keystroke mutates `composeText`, and
/// keeping that mutation OUT of ChatScreen prevents the LazyVStack of
/// chat rows from re-evaluating its body on every typed character.
///
/// Communicates with the parent only through:
///   - `onSend`: async callback the parent uses to actually post via
///     `chatModel.send(text:)`. Async-typed so the button can show a
///     disabled state while a send is in flight.
///
/// Multi-line growing input: Twitch chat doesn't support newlines (the
/// server strips them before sending), but `axis: .vertical` lets the
/// field expand as the user types long messages — matching the native
/// Twitch iOS experience. `.submitLabel` / `.onSubmit` are intentionally
/// omitted because `axis: .vertical` re-assigns Return to newline; the
/// send button is the submit action instead.
struct ComposeBar: View {
    let channelLoginName: String
    let channelDisplayName: String
    /// When non-nil, the bar shows a "Replying to …" chip above the
    /// field and the next send threads against this parent. Owned by
    /// `ChatTranscriptModel.replyContext` upstream — the bar is purely
    /// presentational.
    let replyContext: ChatTranscriptModel.ReplyContext?
    /// Channel-wide restrictions to surface above the input (slow mode,
    /// followers-only, etc.). nil before the first chat-settings fetch
    /// completes — same visual as a channel with no restrictions, which
    /// is the common case.
    let chatRestrictions: ChatRestrictions?
    /// Tapped on the chip's X — dismisses the reply attachment without
    /// sending. The parent (`ChatScreen`) calls `chatModel.cancelReply()`.
    let onCancelReply: () -> Void
    /// Fired on every text change so the parent (`ChatScreen`) can
    /// persist the draft to `DraftStorage`. We don't expose @State or
    /// a Binding<String> — that would re-trigger ChatScreen.body on
    /// every keystroke (the typing-lag regression commit 2 fixed).
    /// Instead the bar owns its @State internally and notifies via
    /// callback, which doesn't propagate as a dependency change.
    let onDraftChange: (String) -> Void
    /// Builds the emote-picker sections on demand (when the emote button
    /// is tapped) so we don't recompute them on every body eval.
    let emoteSectionsProvider: () -> [EmoteSection]
    let onSend: @MainActor (String) async -> Void

    @State private var composeText: String
    @State private var isSending: Bool = false
    @FocusState private var focused: Bool

    /// Picker presentation + its snapshot of sections (captured when the
    /// emote button is tapped, so the grid is stable while open).
    @State private var showingEmotePicker = false
    @State private var pickerSections: [EmoteSection] = []

    /// Custom init that seeds `composeText`'s @State with the persisted
    /// draft. SwiftUI's `@State` semantics ensure the seed value is
    /// only used at first mount for a given view identity — subsequent
    /// re-renders ignore the seed and keep whatever the user typed.
    /// This gives us "load on first mount, never clobber typing"
    /// without a Binding.
    init(
        channelLoginName: String,
        channelDisplayName: String,
        replyContext: ChatTranscriptModel.ReplyContext?,
        chatRestrictions: ChatRestrictions?,
        seedDraft: String,
        onCancelReply: @escaping () -> Void,
        onDraftChange: @escaping (String) -> Void,
        emoteSectionsProvider: @escaping () -> [EmoteSection],
        onSend: @escaping @MainActor (String) async -> Void
    ) {
        self.channelLoginName = channelLoginName
        self.channelDisplayName = channelDisplayName
        self.replyContext = replyContext
        self.chatRestrictions = chatRestrictions
        self.onCancelReply = onCancelReply
        self.onDraftChange = onDraftChange
        self.emoteSectionsProvider = emoteSectionsProvider
        self.onSend = onSend
        self._composeText = State(initialValue: seedDraft)
    }

    var body: some View {
        VStack(spacing: 6) {
            if let restrictions = chatRestrictions, restrictions.hasAny {
                restrictionsStrip(restrictions)
            }

            if let reply = replyContext {
                replyChip(reply)
            }

            inputRow
        }
        .padding(.horizontal)
        // Tight vertical padding — every point here is a point taken from
        // the transcript. The field's own internal padding plus the
        // safe-area gap below keep the bar comfortable at 4pt.
        .padding(.vertical, 4)
        // Animate the chip's appearance/disappearance. We trigger on
        // `replyContext != nil` (not the full context value) because
        // we only want the animation on chip appear/disappear, NOT on
        // mid-compose target switches (long-press another message to
        // reply to it instead). The chip's content updates in place
        // without an animation — which feels right for "I changed my
        // mind about who to reply to."
        //
        // `ReplyContext` is fully `Equatable` (all stored fields are
        // String), so we could use `value: replyContext` if we wanted
        // the chip to animate when the target changes. Not chosen
        // today — feels jumpier.
        .animation(.snappy(duration: 0.2), value: replyContext != nil)
        // Emote picker. Stays open while you tap (so you can stack
        // several emotes); inserts each emote's name into the composer.
        .sheet(isPresented: $showingEmotePicker) {
            EmotePickerView(sections: pickerSections) { name in
                insertEmote(name)
            }
        }
    }

    /// Append a tapped emote's name to the draft, ensuring a single
    /// space separates it from prior text (and a trailing space so the
    /// next token / emote doesn't fuse to it). Chat emotes are
    /// whitespace-delimited tokens, so the spacing is load-bearing —
    /// "KappaPride" is a different (or non-existent) emote vs
    /// "Kappa Pride".
    private func insertEmote(_ name: String) {
        if composeText.isEmpty || composeText.hasSuffix(" ") {
            composeText += "\(name) "
        } else {
            composeText += " \(name) "
        }
        // onChange(of: composeText) fires from the mutation above, so
        // the draft persists automatically — no explicit onDraftChange
        // call needed here.
    }

    /// Inline informational strip above the input, listing chat
    /// restrictions that affect what the user can send (slow mode,
    /// followers-only, etc.). Non-blocking — the send button stays
    /// enabled, and if the user fails the restriction (e.g. not yet
    /// following), Twitch's `dropReason` surfaces on the failed row.
    ///
    /// Why informational not blocking: pre-flighting "is the user
    /// following / subscribed" requires per-user API calls and produces
    /// the same outcome as letting Twitch tell us via dropReason. The
    /// strip is just a heads-up so users don't get a surprise rejection.
    @ViewBuilder
    private func restrictionsStrip(_ r: ChatRestrictions) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .imageScale(.small)
            Text(restrictionsLabel(r))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.10))
        )
    }

    /// Build a human-readable comma-joined label of the active
    /// restrictions. Each phrase is short enough to coexist on one line
    /// of caption2 when the channel has 1-2 restrictions; with 3+ the
    /// strip allows up to 2 lines of wrap.
    private func restrictionsLabel(_ r: ChatRestrictions) -> String {
        var parts: [String] = []
        if let secs = r.slowModeSeconds {
            parts.append("Slow mode: \(secs)s")
        }
        if r.followersOnly {
            if let mins = r.followersDurationMinutes, mins > 0 {
                // Render "30m" / "1h" / "1d" for readability — Twitch's
                // duration is in minutes which gets unwieldy at high
                // values ("43800 minutes").
                parts.append("Followers only (\(Self.formatMinutes(mins)))")
            } else {
                parts.append("Followers only")
            }
        }
        if r.subscribersOnly {
            parts.append("Subscribers only")
        }
        if r.emoteOnly {
            parts.append("Emote only")
        }
        return parts.joined(separator: " · ")
    }

    /// Format a follower-mode duration in the most natural unit:
    /// minutes for <60, hours for <24h, days otherwise.
    private static func formatMinutes(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 60 * 24 { return "\(minutes / 60)h" }
        return "\(minutes / (60 * 24))d"
    }

    /// "Replying to @author: snippet" chip with an X button. Tinted
    /// with the accent color at low opacity so it reads as informative,
    /// not alarming. Uses `arrowshape.turn.up.left.fill` to mirror the
    /// long-press menu icon — visual continuity between "I chose
    /// Reply" and "I'm now in reply mode."
    @ViewBuilder
    private func replyChip(_ reply: ChatTranscriptModel.ReplyContext) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
                .imageScale(.small)
            VStack(alignment: .leading, spacing: 1) {
                Text("Replying to \(reply.parentAuthorDisplayName)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                Text(reply.parentSnippet)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            Button {
                onCancelReply()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .imageScale(.medium)
                    // Inner padding grows the tap target toward the 44pt HIG
                    // minimum (the bare glyph was ~20pt); the negative outer
                    // padding below cancels the layout growth so the chip
                    // keeps its compact height. Net: bigger hit area, same
                    // visual.
                    .padding(12)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(-12)
            .accessibilityLabel("Cancel reply")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.accentColor.opacity(0.12))
        )
        // Subtle transition so the chip appearing isn't jarring.
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// Placeholder text — switches to "Reply to @author" when a reply
    /// is attached so the user has a second visual cue (beyond the
    /// chip) that their next send will be threaded.
    private var textFieldPrompt: String {
        if let reply = replyContext {
            return "Reply to \(reply.parentAuthorDisplayName)"
        }
        return "Send a message in #\(channelLoginName)"
    }

    /// True when the draft has at least one non-whitespace character.
    /// Drives the send button's appearance: hidden while empty (the bar
    /// reads as a clean pill with just the emote button), faded in once
    /// there's text. (Send clears `composeText` synchronously at
    /// send-start, so the button disappears the instant a send is
    /// committed — no separate isSending check needed for the swap.)
    private var hasDraft: Bool {
        !composeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The compose pill: a single glass surface holding the text field,
    /// the always-present emote button, and the send button (which only
    /// appears once there's a draft). One unified pill — not three
    /// separate glass shapes — so the bar reads calm; the only filled
    /// shape is the prominent send button, which carries the
    /// call-to-action signal (axiom-design Liquid Glass guidance).
    @ViewBuilder
    private var inputRow: some View {
        GlassEffectContainer(spacing: 6) {
            // `.bottom` alignment so the trailing buttons stay pinned to
            // the bottom of the pill as the field grows multi-line, rather
            // than floating to the vertical center of a tall field.
            HStack(alignment: .bottom, spacing: 2) {
                TextField(textFieldPrompt, text: $composeText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .focused($focused)
                    // Forward every text change to the parent so it can
                    // persist via DraftStorage. UserDefaults batches writes
                    // so per-keystroke saves don't actually hit disk on
                    // every call — observed throughput is roughly the same
                    // as a debounced save without the .task(id:) sleep.
                    .onChange(of: composeText) { _, newValue in
                        onDraftChange(newValue)
                    }
                    .padding(.leading, 16)
                    .padding(.vertical, 9)
                    .accessibilityLabel("Message input")
                    .accessibilityHint("Type a chat message to send to \(channelDisplayName)")

                // Emote-picker button — always present, pinned right.
                // Borderless glyph (no glass circle of its own): it sits
                // *on* the pill glass, keeping a single surface. Snapshots
                // the sections (built on demand) and presents the grid.
                Button {
                    pickerSections = emoteSectionsProvider()
                    showingEmotePicker = true
                } label: {
                    Image(systemName: "face.smiling")
                        // 28pt so the glyph's circle reads at the same
                        // diameter as the send button's 30pt disc — the two
                        // trailing controls match in size even though only
                        // send is filled.
                        .font(.system(size: 17, weight: .regular))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                        // Borderless grey glyph (no fill) — styled like the
                        // mic icon in the Claude composer: a quiet control
                        // sitting directly on the pill, leaving the orange
                        // send circle as the only filled shape in the bar.
                        // 44pt outer frame (Apple HIG minimum touch target;
                        // this and send are the most-tapped controls in the
                        // app) around the unchanged 30pt visual disc.
                        .frame(width: 30, height: 30)
                        .background(Color.emoteButton, in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Emotes")

                // Send — only once there's text. The single filled/tinted
                // shape in the bar; `.glassProminent` reads as a control
                // sitting on the pill, matching the iMessage send affordance.
                if hasDraft {
                    Button {
                        Task { await sendDraft() }
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            // Flat orange circle (Color.sendButton, not the
                            // blue app accent) — the single warm CTA in the
                            // bar, mirroring the Claude composer's send
                            // affordance. An explicit Circle (not
                            // `.glassProminent`, whose ~44pt min height made
                            // the button hang below the emote) so the inner
                            // 30pt disc and the emote share one 40pt frame and
                            // sit perfectly level under `.bottom` alignment.
                            // 44pt outer frame to match the emote button —
                            // HIG-minimum touch target, unchanged 30pt disc.
                            .frame(width: 30, height: 30)
                            .background(Color.sendButton, in: Circle())
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isSending)
                    .transition(.blurReplace)
                    .accessibilityLabel("Send message")
                }
            }
            // Trailing inset keeps the emote/send off the pill's right edge.
            .padding(.trailing, 5)
            // The pill's single glass surface. Fixed continuous radius
            // (NOT a Capsule): a capsule's radius is always half its
            // height, so once the field grows multi-line (lineLimit 1...5)
            // the corners balloon into an over-rounded blob. A constant
            // 24pt radius stays pill-ish at one line and tidy as it grows.
            .glassEffect(.regular, in: .rect(cornerRadius: 24, style: .continuous))
            // Animate the send button fading in/out (and the field width
            // change it causes). Value-scoped so unrelated re-renders don't
            // animate.
            .animation(.snappy(duration: 0.2), value: hasDraft)
        }
    }

    private func sendDraft() async {
        let draft = composeText.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !draft.isEmpty else { return }
        guard !isSending else { return }

        isSending = true
        defer { isSending = false }

        // Optimistic clear — the message immediately appears in chat as an
        // optimistic row via chatModel.send, so leaving the bar populated
        // would feel like the message is still in flight.
        composeText = ""

        await onSend(draft)
    }
}

#if DEBUG
// Live design harness for the compose bar. Pinned to the bottom over the
// chat surface so it reads like the real `.safeAreaBar` placement. The
// TextField is interactive in the canvas — type to watch the orange send
// button fade in next to the emote glyph.
#Preview("Compose bar – empty") {
    VStack(spacing: 0) {
        Spacer()
        ComposeBar(
            channelLoginName: "xqc",
            channelDisplayName: "xQc",
            replyContext: nil,
            chatRestrictions: nil,
            seedDraft: "",
            onCancelReply: {},
            onDraftChange: { _ in },
            emoteSectionsProvider: { [] },
            onSend: { _ in }
        )
    }
    .background(Color.chatSurface)
}

#Preview("Compose bar – with draft") {
    VStack(spacing: 0) {
        Spacer()
        ComposeBar(
            channelLoginName: "xqc",
            channelDisplayName: "xQc",
            replyContext: nil,
            chatRestrictions: nil,
            seedDraft: "Okay",
            onCancelReply: {},
            onDraftChange: { _ in },
            emoteSectionsProvider: { [] },
            onSend: { _ in }
        )
    }
    .background(Color.chatSurface)
}
#endif
