import Channels
import Core
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
/// Talks to the parent through callbacks only (`onSend`, `onDraftChange`,
/// `onCancelReply`, the ⋯ menu's actions) — never a binding to the draft.
/// `onSend` is async so a second submit is ignored while one is in flight.
///
/// Single-line input: Twitch chat has no newlines, so Return sends
/// (`.submitLabel(.send)` + `.onSubmit`) and there is no send button.
///
/// Layout: a glass pill (field + emote button) with the ⋯ menu in its own
/// glass circle on the right. Above it sits ONE context slot, so the bar
/// is never more than two rows tall. In priority order it shows @mention
/// suggestions, the reply quote card, or (while focused) your recent
/// emotes. During a slow-mode wait a countdown ring joins the pill.
struct ComposeBar: View {
    let channelLoginName: String
    let channelDisplayName: String
    /// The pager tab this bar's chat lives in — what the ⋯ menu's "Close
    /// Chat" closes. nil outside the pager, which hides the item.
    let tabId: UUID?
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
    /// Moderators and the broadcaster skip slow mode, so they get no
    /// countdown after sending.
    let slowModeExempt: Bool
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
    /// Builds the pool of people the `@` suggestions draw from (recent
    /// chatters + the broadcaster). Called once when a mention starts, not
    /// per keystroke — the strip then filters that snapshot as you type.
    let mentionPoolProvider: @MainActor () -> [MentionAutocomplete.Candidate]
    let onSend: @MainActor (String) async -> Void
    /// Opens the chat settings sheet from the ⋯ menu. nil hides the item.
    let onOpenSettings: (() -> Void)?
    /// "Create Clip" in the ⋯ menu (shown while the channel is live). nil
    /// hides it.
    let createClip: CreateClipEntry?
    /// One-shot `@mention` request from the user card. Observed via `.onChange`
    /// so inserting a mention never pulls draft `@State` up into `ChatScreen`.
    let pendingMention: PendingMention?

    /// One-shot request to append `@insertionName ` into the draft and focus
    /// the composer. Each tap creates a fresh `id` so mentioning the same
    /// chatter twice still triggers `.onChange`.
    struct PendingMention: Equatable {
        let id = UUID()
        let insertionName: String
    }

    /// What the ⋯ menu needs for "Create Clip": whose stream, and what to
    /// do (the parent presents `CreateClipSheet`).
    struct CreateClipEntry {
        let channelId: String
        let action: () -> Void
    }

    @Environment(\.openURL) private var openURL
    /// Same preference the stream header reads — the ⋯ menu's Show/Hide
    /// Video flips it.
    @AppStorage(StreamHeaderView.expandedKey) private var videoVisible = false
    @AppStorage(PlayerSettings.audioOnlyKey) private var audioOnly = false
    @Environment(\.chatTabs) private var chatTabs
    #if os(iOS)
    @Environment(\.playback) private var playback
    #endif

    @State private var composeText: String
    @State private var isSending: Bool = false
    @FocusState private var focused: Bool

    /// Picker presentation + its snapshot of sections (captured when the
    /// emote button is tapped, so the grid is stable while open).
    @State private var showingEmotePicker = false
    @State private var pickerSections: [EmoteSection] = []

    /// Snapshot of mention candidates, taken when the draft starts an
    /// `@mention` and dropped when it ends. nil = no mention in progress.
    @State private var mentionPool: [MentionAutocomplete.Candidate]?
    @Environment(\.colorScheme) private var colorScheme

    /// This channel's recently used emotes (newest first), loaded on
    /// appear and updated as you insert emotes.
    @State private var recentEmotes: [PickerEmote] = []
    /// The slow-mode wait after your last send. nil when none is running.
    @State private var cooldown: SlowModeCooldown?

    /// Emotes the quick row shows. Seven plus the "all emotes" button fit
    /// the narrowest iPhone, so the row hugs its content and never scrolls.
    private static let recentRowCount = 7

    /// Custom init that seeds `composeText`'s @State with the persisted
    /// draft. SwiftUI's `@State` semantics ensure the seed value is
    /// only used at first mount for a given view identity — subsequent
    /// re-renders ignore the seed and keep whatever the user typed.
    /// This gives us "load on first mount, never clobber typing"
    /// without a Binding.
    init(
        channelLoginName: String,
        channelDisplayName: String,
        tabId: UUID? = nil,
        replyContext: ChatTranscriptModel.ReplyContext?,
        chatRestrictions: ChatRestrictions?,
        ownRestriction: OwnChatRestrictionState? = nil,
        slowModeExempt: Bool = false,
        seedDraft: String,
        onCancelReply: @escaping () -> Void,
        onDraftChange: @escaping (String) -> Void,
        emoteSectionsProvider: @escaping () -> [EmoteSection],
        mentionPoolProvider: @escaping @MainActor () -> [MentionAutocomplete.Candidate] = { [] },
        onSend: @escaping @MainActor (String) async -> Void,
        onOpenSettings: (() -> Void)? = nil,
        createClip: CreateClipEntry? = nil,
        pendingMention: PendingMention? = nil
    ) {
        self.onOpenSettings = onOpenSettings
        self.createClip = createClip
        self.pendingMention = pendingMention
        self.channelLoginName = channelLoginName
        self.channelDisplayName = channelDisplayName
        self.tabId = tabId
        self.replyContext = replyContext
        self.chatRestrictions = chatRestrictions
        self.ownRestriction = ownRestriction
        self.slowModeExempt = slowModeExempt
        self.onCancelReply = onCancelReply
        self.onDraftChange = onDraftChange
        self.emoteSectionsProvider = emoteSectionsProvider
        self.mentionPoolProvider = mentionPoolProvider
        self.onSend = onSend
        self._composeText = State(initialValue: seedDraft)
    }

    var body: some View {
        // Computed once per body: the slot choice and its animation value
        // both read it, and each evaluation lowercases and scans the whole
        // chatter pool.
        let slot = contextSlot(mentions: mentionSuggestions)
        // One container for the slot and the bar so their glass shapes
        // blend and morph as one surface family.
        GlassEffectContainer(spacing: 8) {
            VStack(spacing: 8) {
                // Active restrictions (followers-only, slow mode…) ride in
                // the field's placeholder instead of a strip that cost a row.
                switch slot {
                case .mentions(let suggestions):
                    mentionStrip(suggestions)
                case .reply(let reply):
                    replyCard(reply)
                case .recentEmotes:
                    recentEmoteRow
                case .none:
                    EmptyView()
                }

                inputRow
            }
        }
        .padding(.horizontal)
        // Tight vertical padding — every point here is a point taken from
        // the transcript. The field's own internal padding plus the
        // safe-area gap below keep the bar comfortable at 4pt.
        .padding(.vertical, 4)
        // A soft fade of the chat surface behind the bar, so messages
        // scrolling under the glass dim before they reach it and don't
        // fight the draft for legibility. Never takes touches.
        .background(alignment: .bottom) {
            LinearGradient(
                stops: [
                    .init(color: Color.chatSurface.opacity(0), location: 0),
                    .init(color: Color.chatSurface.opacity(0.55), location: 0.45),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .padding(.top, -12)
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)
        }
        // Animate the slot switching between kinds only. Keyed on the
        // kind, not the content, so changing your reply target mid-compose
        // or narrowing the mention list updates in place without a jump.
        .animation(.snappy(duration: 0.2), value: slot.kind)
        .onAppear {
            recentEmotes = RecentEmotes.load(channel: channelLoginName)
        }
        .onChange(of: pendingMention) { _, mention in
            guard let mention else { return }
            insertMention(mention.insertionName)
        }
        // Clear the countdown when it runs out, which also drops the ring.
        .task(id: cooldown) {
            guard let cooldown else { return }
            try? await Task.sleep(for: .seconds(max(0, cooldown.endsAt.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self.cooldown = nil
        }
        // Emote picker. Stays open while you tap (so you can stack
        // several emotes); inserts each emote's name into the composer.
        .sheet(isPresented: $showingEmotePicker) {
            EmotePickerView(sections: pickerSections) { emote in
                insertEmote(emote)
            }
        }
    }

    // MARK: - Context slot

    /// What the single row above the bar shows. Mentions win because
    /// they're short-lived and need a tap; the reply card comes back as
    /// soon as the mention is finished.
    private enum ContextSlot {
        case none
        case mentions([MentionAutocomplete.Candidate])
        case reply(ChatTranscriptModel.ReplyContext)
        case recentEmotes

        enum Kind: Equatable { case none, mentions, reply, recentEmotes }

        var kind: Kind {
            switch self {
            case .none: .none
            case .mentions: .mentions
            case .reply: .reply
            case .recentEmotes: .recentEmotes
            }
        }
    }

    private func contextSlot(mentions: [MentionAutocomplete.Candidate]) -> ContextSlot {
        if !mentions.isEmpty { return .mentions(mentions) }
        if let replyContext { return .reply(replyContext) }
        // Recent emotes only while typing is possible: focused, not
        // blocked, and there is something to show.
        if focused, !isSendBlocked, !recentEmotes.isEmpty { return .recentEmotes }
        return .none
    }

    /// Append a tapped emote's name to the draft, ensuring a single
    /// space separates it from prior text (and a trailing space so the
    /// next token / emote doesn't fuse to it). Chat emotes are
    /// whitespace-delimited tokens, so the spacing is load-bearing —
    /// "KappaPride" is a different (or non-existent) emote vs
    /// "Kappa Pride". Also moves it to the front of the recent row.
    private func insertEmote(_ emote: PickerEmote) {
        let name = emote.name
        if composeText.isEmpty || composeText.hasSuffix(" ") {
            composeText += "\(name) "
        } else {
            composeText += " \(name) "
        }
        // onChange(of: composeText) fires from the mutation above, so
        // the draft persists automatically — no explicit onDraftChange
        // call needed here.
        recentEmotes = RecentEmotes.record(emote, channel: channelLoginName)
    }

    /// Append `@name ` to the draft and focus the text field (triggered by
    /// the user card's Mention action).
    private func insertMention(_ name: String) {
        composeText = Self.appendingMention(name, to: composeText)
        if !isSendBlocked {
            focused = true
        }
    }

    /// Pure string splice behind `insertMention(_:)`: guarantees a leading
    /// space when prior text doesn't end in whitespace, plus a trailing space
    /// so the user can keep typing immediately.
    nonisolated static func appendingMention(_ name: String, to text: String) -> String {
        let token = "@\(name) "
        if text.isEmpty || text.last?.isWhitespace == true {
            return text + token
        }
        return text + " " + token
    }

    /// Opens the full picker with a fresh snapshot of the sections.
    private func openEmotePicker() {
        pickerSections = emoteSectionsProvider()
        showingEmotePicker = true
    }

    /// The quick-emote row: your recent emotes in this channel on one glass
    /// strip, then a button for the full picker. Hugs its content.
    private var recentEmoteRow: some View {
        HStack(spacing: 2) {
            ForEach(recentEmotes.prefix(Self.recentRowCount)) { emote in
                Button {
                    insertEmote(emote)
                } label: {
                    EmoteCell(emote: emote, size: 30)
                        .frame(width: 38, height: 38)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Insert \(emote.name)")
            }
            Button {
                openEmotePicker()
            } label: {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 38, height: 38)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("All emotes")
        }
        .padding(4)
        .glassEffect(.regular, in: .rect(cornerRadius: 16, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.move(edge: .bottom).combined(with: .opacity))
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

    /// The reply quote card: who you're replying to and what they said, on
    /// its own glass card in the context slot, with an X to cancel. Uses
    /// `arrowshape.turn.up.left.fill` to mirror the long-press menu icon,
    /// so "I chose Reply" and "I'm now replying" look connected.
    @ViewBuilder
    private func replyCard(_ reply: ChatTranscriptModel.ReplyContext) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
                .imageScale(.medium)
            VStack(alignment: .leading, spacing: 1) {
                Text("Replying to \(reply.parentAuthorDisplayName)")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
                Text(reply.parentSnippet)
                    .font(.footnote)
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
                    .font(.system(size: 22))
                    // Inner padding grows the tap target toward the 44pt HIG
                    // minimum; the negative outer padding below cancels the
                    // layout growth so the card keeps its compact height.
                    .padding(11)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(-11)
            .accessibilityLabel("Cancel reply")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 16, style: .continuous))
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

    /// True when the draft has at least one non-whitespace character —
    /// what the ⋯ menu's "Clear Draft" item appears for.
    private var hasDraft: Bool {
        !composeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// True while a slow-mode wait from your last send is still running.
    private var isCoolingDown: Bool {
        cooldown?.isActive(at: .now) ?? false
    }

    /// The bar: a glass pill holding the field, the emote button and (during
    /// a slow-mode wait) the countdown ring, with the ⋯ menu in its own
    /// glass circle on the right. No send button: Return sends. Both shapes
    /// sit in the body's `GlassEffectContainer`, so they blend as one
    /// surface family.
    @ViewBuilder
    private var inputRow: some View {
        // `.bottom` alignment so the trailing controls stay pinned to the
        // bottom of the pill as the field grows multi-line, rather than
        // floating to the vertical center of a tall field.
        HStack(alignment: .bottom, spacing: 8) {
            HStack(alignment: .bottom, spacing: 2) {
                // Single-line: Return sends (no send button). Chat messages
                // are one line on Twitch anyway. The keyboard drops after a
                // send so the chat gets the screen back (TestFlight feedback);
                // `onSubmit` resigns focus by default, so we just don't
                // re-assert it.
                TextField(textFieldPrompt, text: $composeText)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .submitLabel(.send)
                    .onSubmit {
                        // Mid-cooldown Twitch would drop the message: keep
                        // the draft and the keyboard, and buzz instead.
                        if isCoolingDown {
                            focused = true
                            #if os(iOS)
                            UINotificationFeedbackGenerator().notificationOccurred(.warning)
                            #endif
                            return
                        }
                        Task { await sendDraft() }
                        focused = false
                    }
                    // Forward every text change to the parent, which hands
                    // it to `DraftStorage.scheduleSave` — debounced (~400ms),
                    // so a burst of typing costs one UserDefaults write, and
                    // flushed when the chat goes away or the app leaves the
                    // foreground.
                    .onChange(of: composeText) { _, newValue in
                        onDraftChange(newValue)
                        updateMentionPool(for: newValue)
                    }
                    .padding(.leading, 14)
                    .padding(.vertical, 11)
                    // Twitch would drop the message anyway; the prompt
                    // says why. A timeout re-enables itself when it ends.
                    .disabled(isSendBlocked)
                    .accessibilityLabel("Message input")
                    .accessibilityHint("Type a chat message to send to \(channelDisplayName)")

                // Emote-picker button — always present. Borderless glyph
                // (no glass of its own): it sits *on* the pill glass.
                Button {
                    openEmotePicker()
                } label: {
                    Image(systemName: "face.smiling")
                        .font(.system(size: 20, weight: .regular))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                        // 44pt touch target (Apple HIG minimum) around the
                        // 30pt visual glyph.
                        .frame(width: 30, height: 30)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Emotes")

                if let cooldown {
                    SlowModeRing(cooldown: cooldown)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            // Trailing inset keeps the controls off the pill's right edge.
            .padding(.trailing, 2)
            .animation(.snappy(duration: 0.2), value: cooldown == nil)
            // Fixed continuous radius (NOT a Capsule): a capsule's radius is
            // always half its height, so if the field grows taller the
            // corners balloon. 22pt reads as a pill at one line.
            .glassEffect(.regular, in: .rect(cornerRadius: 22, style: .continuous))

            moreMenu
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
            if let createClip {
                // Live-only; reads status in its own view (see type doc).
                CreateClipMenuItem(channelId: createClip.channelId, action: createClip.action)
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
            // Audio-only is the native engine's; not offered while that's
            // switched off.
            if !audioOnly, PlayerSettings.isNativePlaybackEnabled {
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
            if DeveloperSettings.isUnlocked {
                Divider()
                DeveloperComposeMenuItems()
            }
        } label: {
            // ⋯ in its own interactive glass circle beside the pill, the
            // same height as the pill so the bar reads as one row. A "+"
            // read as "add/attach" rather than "more options" (TestFlight
            // feedback), so it stays the standard ellipsis.
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .glassEffect(.regular.interactive(), in: Circle())
        }
        .accessibilityLabel("More options")
    }

    // MARK: - @mention suggestions

    /// Take the candidate snapshot when a mention starts; drop it when the
    /// draft no longer ends in one (space typed, text cleared, sent).
    private func updateMentionPool(for text: String) {
        let mentioning = MentionAutocomplete.activeQuery(in: text) != nil
        if mentioning, mentionPool == nil {
            mentionPool = mentionPoolProvider()
        } else if !mentioning, mentionPool != nil {
            mentionPool = nil
        }
    }

    /// Current matches. Empty unless a mention is being typed and the field
    /// has focus (no strip hovering over chat once the keyboard is gone).
    private var mentionSuggestions: [MentionAutocomplete.Candidate] {
        guard focused, let pool = mentionPool,
              let query = MentionAutocomplete.activeQuery(in: composeText) else { return [] }
        return MentionAutocomplete.suggestions(for: query, in: pool)
    }

    /// A row of name chips above the field, newest chatters first. Tapping
    /// one swaps the half-typed "@que" for "@Name ".
    private func mentionStrip(_ suggestions: [MentionAutocomplete.Candidate]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(suggestions, id: \.login) { candidate in
                    Button {
                        composeText = MentionAutocomplete.complete(composeText, with: candidate)
                    } label: {
                        Text("@\(candidate.insertionName)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(
                                candidate.color.isEmpty
                                    ? Color.primary
                                    : Color.twitchUsername(hex: candidate.color, scheme: colorScheme)
                            )
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .glassEffect(.regular.interactive(), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Mention \(candidate.displayName)")
                }
            }
            .padding(.horizontal, 2)
        }
        .scrollClipDisabled()
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var channelURL: URL? {
        Endpoints.TwitchWeb.channel(login: channelLoginName)
    }

    private func sendDraft() async {
        let draft = composeText.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !draft.isEmpty else { return }
        guard !isSending else { return }
        guard !isCoolingDown else { return }

        isSending = true
        defer { isSending = false }

        // Optimistic clear — the message immediately appears in chat as an
        // optimistic row via chatModel.send, so leaving the bar populated
        // would feel like the message is still in flight.
        composeText = ""

        await onSend(draft)

        // Start the slow-mode wait from when the send went out.
        if !slowModeExempt, let seconds = chatRestrictions?.slowModeSeconds, seconds > 0 {
            cooldown = SlowModeCooldown(startedAt: .now, seconds: seconds)
        }
    }
}

/// Developer-only items in the compose bar's `⋯` menu. Kept in a child view
/// so `@AppStorage` for the Debug HUD never subscribes `ComposeBar.body`.
private struct DeveloperComposeMenuItems: View {
    @AppStorage(DeveloperSettings.chatDebugHUDKey) private var showDebugHUD = false

    var body: some View {
        Menu {
            Button {
                let entries = AppLogger.recentEntries(limit: 500, minLevel: .debug)
                let report = DiagnosticReportBuilder.build(entries: entries)
                DeveloperSettings.copyToClipboard(report)
            } label: {
                Label("Copy Chat Diagnostics", systemImage: "doc.on.doc")
            }
            Button {
                showDebugHUD.toggle()
            } label: {
                Label(
                    showDebugHUD ? "Hide Debug HUD" : "Show Debug HUD",
                    systemImage: showDebugHUD ? "eye.slash" : "gauge.with.dots.needle.33percent"
                )
            }
        } label: {
            Label("Developer", systemImage: "ladybug")
        }
    }
}

/// The slow-mode countdown ring in the compose pill: a draining arc with
/// the seconds left in the middle. Ticks on its own timeline so only the
/// ring re-renders while it counts.
private struct SlowModeRing: View {
    let cooldown: SlowModeCooldown

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { context in
            let fraction = cooldown.fractionRemaining(at: context.date)
            let seconds = cooldown.remaining(at: context.date)
            ZStack {
                Circle()
                    .stroke(.quaternary, lineWidth: 3)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(Color.orange, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.2), value: fraction)
                Text("\(seconds)")
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }
            .frame(width: 26, height: 26)
            .frame(width: 36, height: 44)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Slow mode")
            .accessibilityValue("\(seconds) seconds until you can send")
        }
    }
}

#if DEBUG
// Live design harness for the compose bar. Pinned to the bottom over the
// chat surface so it reads like the real `.safeAreaBar` placement. The
// TextField is interactive in the canvas; Return sends.
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
