import Channels
import DesignSystem
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

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
    /// The signed-in user's own standing here (timed out / banned / warned).
    /// Read only in this body, so a change re-renders the bar and nothing
    /// else. nil (previews, tests) = never restricted.
    let ownRestriction: OwnChatRestrictionState?
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
    /// Opens the chat settings sheet from the ⋯ menu. nil hides the item.
    let onOpenSettings: (() -> Void)?

    @Environment(\.openURL) private var openURL
    /// Same preference the stream header reads — the ⋯ menu's Show/Hide
    /// Video flips it.
    @AppStorage(StreamHeaderView.expandedKey) private var videoVisible = false
    @AppStorage(PlayerSettings.audioOnlyKey) private var audioOnly = false
    @Environment(\.chatTabs) private var chatTabs
    #if os(iOS)
    @Environment(\.playback) private var playback
    #endif

    /// The open tab showing this channel — for "Close Chat".
    private var tabId: UUID? {
        chatTabs?.tabs.first { $0.channels.first?.channelLoginName == channelLoginName }?.id
    }

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
        ownRestriction: OwnChatRestrictionState? = nil,
        seedDraft: String,
        onCancelReply: @escaping () -> Void,
        onDraftChange: @escaping (String) -> Void,
        emoteSectionsProvider: @escaping () -> [EmoteSection],
        onSend: @escaping @MainActor (String) async -> Void,
        onOpenSettings: (() -> Void)? = nil
    ) {
        self.onOpenSettings = onOpenSettings
        self.channelLoginName = channelLoginName
        self.channelDisplayName = channelDisplayName
        self.replyContext = replyContext
        self.chatRestrictions = chatRestrictions
        self.ownRestriction = ownRestriction
        self.onCancelReply = onCancelReply
        self.onDraftChange = onDraftChange
        self.emoteSectionsProvider = emoteSectionsProvider
        self.onSend = onSend
        self._composeText = State(initialValue: seedDraft)
    }

    var body: some View {
        VStack(spacing: 6) {
            // Active restrictions (followers-only, slow mode…) ride in the
            // field's placeholder instead of a strip that cost a row.

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
        // Our own timeout / ban / warning outranks everything else: it's
        // why the field is disabled (or why sends will be dropped).
        if let restriction = ownRestriction?.current {
            switch restriction {
            case .timedOut(let until?) where until > .now:
                return "You're timed out until \(until.formatted(date: .omitted, time: .shortened))"
            case .timedOut:
                return "You may be timed out here"
            case .banned:
                return "You're banned from this chat"
            case .warned:
                return "Acknowledge your warning on Twitch to chat"
            case .removedByModerator:
                return "A moderator removed your messages"
            }
        }
        if let reply = replyContext {
            return "Reply to \(reply.parentAuthorDisplayName)"
        }
        if let restrictions = chatRestrictions, restrictions.hasAny {
            return "\(restrictionsLabel(restrictions)) · Send a message"
        }
        return "Send a message in #\(channelLoginName)"
    }

    /// True while our own timeout / ban means Twitch would drop any send.
    private var isSendBlocked: Bool {
        ownRestriction?.current?.blocksSending() ?? false
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
          // Pill + the ⋯ actions circle beside it (same container, so the
          // two glass shapes blend as one surface family).
          HStack(alignment: .bottom, spacing: 8) {
            // `.bottom` alignment so the trailing buttons stay pinned to
            // the bottom of the pill as the field grows multi-line, rather
            // than floating to the vertical center of a tall field.
            HStack(alignment: .bottom, spacing: 2) {
                // ⋯ lives inside the pill now (leading), a quiet glyph like
                // the emote button — one surface instead of a pill plus a
                // floating circle.
                moreMenu

                // Single-line: Return sends (no send button), and the keyboard
                // stays up for the next message. Chat messages are one line
                // on Twitch anyway.
                TextField(textFieldPrompt, text: $composeText)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .submitLabel(.send)
                    .onSubmit {
                        Task { await sendDraft() }
                        focused = true
                    }
                    // Forward every text change to the parent, which hands
                    // it to `DraftStorage.scheduleSave` — debounced (~400ms),
                    // so a burst of typing costs one UserDefaults write, and
                    // flushed when the chat goes away or the app leaves the
                    // foreground.
                    .onChange(of: composeText) { _, newValue in
                        onDraftChange(newValue)
                    }
                    .padding(.leading, 2)
                    .padding(.vertical, 9)
                    // Twitch would drop the message anyway; the prompt
                    // says why. A timeout re-enables itself when it ends.
                    .disabled(isSendBlocked)
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
                        .font(.system(size: 20, weight: .regular))
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
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Emotes")

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
    }

    /// ⋯ — chat actions that don't earn a permanent button: chat settings
    /// (moved here from the top bar, where it competed with the channel
    /// pill), clearing the draft, and channel link hand-offs.
    private var moreMenu: some View {
        Menu {
            if let onOpenSettings {
                Button {
                    onOpenSettings()
                } label: {
                    Label("Chat Settings", systemImage: "gearshape")
                }
            }
            if hasDraft {
                Button(role: .destructive) {
                    composeText = ""
                } label: {
                    Label("Clear Draft", systemImage: "xmark.circle")
                }
            }
            // Video modes: watch, listen, or neither.
            if !videoVisible || audioOnly {
                Button {
                    withAnimation(.snappy(duration: 0.25)) {
                        videoVisible = true
                        audioOnly = false
                    }
                } label: {
                    Label("Show Video", systemImage: "play.rectangle")
                }
            }
            #if os(iOS)
            if !audioOnly {
                Button {
                    withAnimation(.snappy(duration: 0.25)) {
                        videoVisible = true
                        audioOnly = true
                    }
                } label: {
                    Label("Audio Only", systemImage: "headphones")
                }
            }
            #endif
            if videoVisible {
                Button {
                    withAnimation(.snappy(duration: 0.25)) {
                        videoVisible = false
                        audioOnly = false
                    }
                } label: {
                    Label(audioOnly ? "Stop Audio" : "Hide Video", systemImage: "rectangle.slash")
                }
            }
            Divider()
            if let channelURL {
                Button {
                    openURL(channelURL)
                } label: {
                    Label("Open in Twitch App", systemImage: "arrow.up.forward.app")
                }
                ShareLink(item: channelURL) {
                    Label("Share Channel", systemImage: "square.and.arrow.up")
                }
                Button {
                    #if os(iOS)
                    UIPasteboard.general.url = channelURL
                    #endif
                } label: {
                    Label("Copy Channel Link", systemImage: "link")
                }
            }
            if let tabId {
                Divider()
                Button(role: .destructive) {
                    #if os(iOS)
                    // Closing the chat also stops its stream (otherwise it
                    // would carry on in the mini player).
                    if playback?.channel?.channelLoginName == channelLoginName {
                        playback?.stop()
                    }
                    #endif
                    chatTabs?.close(tabId: tabId)
                } label: {
                    Label("Close Chat", systemImage: "xmark")
                }
            }
        } label: {
            // A filled "+" disc, iMessage-style: reads as a button that opens
            // more options, where a bare ⋯ read as decoration.
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 30, height: 30)
                .background(Color.emoteButton, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .padding(.leading, 4)
        .accessibilityLabel("More options")
    }

    private var channelURL: URL? {
        URL(string: "https://www.twitch.tv/\(channelLoginName)")
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
