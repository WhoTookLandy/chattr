import SwiftUI
import TwitchKit
import Channels
import ChatModel
import EmoteSources
import DesignSystem

/// One chat-message row: badges → bold username → inline-rendered runs
/// (text, third-party emote images, Twitch native emote images, @mention
/// highlights, cheermote text) — or, for non-message lines, the matching
/// bubble / divider row.
///
/// The input is a display-ready `ChatLine`: its `LineRun`s are already
/// tokenized, so this view only dispatches each run to the right inline
/// subview. No regex, no string scanning, no per-render allocation.
///
/// Username color is HSL-lightness-clamped per color scheme — see
/// `Color.twitchUsername(hex:scheme:)` in DesignSystem. Twitch's user-picked
/// colors are tuned for dark UIs; without clamping, bright yellows / pale
/// pastels are unreadable on light backgrounds.
///
/// Badges are pre-resolved by the parent (`ChatScreen` owns the
/// `ChatBadgeStore`) and passed in as already-looked-up `ChatBadgeEntry`s
/// — keeps `ChatRow` purely presentational and avoids re-doing the
/// dictionary lookup on every body recomputation.
struct ChatRow: View, Equatable {
    let line: ChatLine
    let badgeEntries: [ChatBadgeEntry]
    /// Called when the user taps the retry control on a `.failed` row.
    /// Optional so call sites without a retry path (priming, previews,
    /// future read-only chat) don't have to manufacture a callback.
    private let onRetry: (() -> Void)?
    /// Called when the user picks "Reply" from the long-press menu on
    /// a `.message` row. Optional for the same reason as `onRetry`.
    private let onReply: (() -> Void)?
    /// Called when the user picks "View Thread" from the long-press
    /// menu OR taps the quoted-reply preview line. Optional — when nil,
    /// the menu item is hidden and the quote tap is disabled (so the
    /// thread-sheet view itself, which doesn't recurse, sets it nil
    /// to suppress both).
    private let onViewThread: (() -> Void)?
    /// Called when a moderator picks "Delete Message" from the
    /// long-press menu. Optional — when nil, the menu item is hidden.
    /// `ChatScreen` only passes a non-nil closure when
    /// `chatModel.currentUserCanModerate` is true, so non-mods never
    /// see the affordance.
    private let onDelete: (() -> Void)?
    /// Called when the user picks "Block" from the long-press menu. nil hides the
    /// item (ChatScreen passes nil for the current user's own messages).
    private let onBlock: (() -> Void)?
    /// Called when the user picks a reason from "Report…". Same nil-hides rule.
    private let onReport: ((UserBlockReason) -> Void)?
    /// Whether a reply line renders its quoted-parent block. The thread
    /// sheet sets this false — inside a thread every message's parent is
    /// already visible right above it, so per-row quotes are pure noise.
    let showsQuotedReply: Bool

    /// Which of the callbacks above are present — the comparable shadow `==`
    /// uses instead of the (incomparable) closures themselves. Derived in
    /// `init`, so it can't drift from them.
    private let affordances: Affordances

    /// One bit per optional callback.
    struct Affordances: OptionSet, Hashable, Sendable {
        let rawValue: UInt8
        static let retry      = Affordances(rawValue: 1 << 0)
        static let reply      = Affordances(rawValue: 1 << 1)
        static let viewThread = Affordances(rawValue: 1 << 2)
        static let delete     = Affordances(rawValue: 1 << 3)
        static let block      = Affordances(rawValue: 1 << 4)
        static let report     = Affordances(rawValue: 1 << 5)
    }

    init(
        line: ChatLine,
        badgeEntries: [ChatBadgeEntry],
        onRetry: (() -> Void)? = nil,
        onReply: (() -> Void)? = nil,
        onViewThread: (() -> Void)? = nil,
        onDelete: (() -> Void)? = nil,
        onBlock: (() -> Void)? = nil,
        onReport: ((UserBlockReason) -> Void)? = nil,
        showsQuotedReply: Bool = true
    ) {
        self.line = line
        self.badgeEntries = badgeEntries
        self.onRetry = onRetry
        self.onReply = onReply
        self.onViewThread = onViewThread
        self.onDelete = onDelete
        self.onBlock = onBlock
        self.onReport = onReport
        self.showsQuotedReply = showsQuotedReply

        var affordances: Affordances = []
        if onRetry != nil { affordances.insert(.retry) }
        if onReply != nil { affordances.insert(.reply) }
        if onViewThread != nil { affordances.insert(.viewThread) }
        if onDelete != nil { affordances.insert(.delete) }
        if onBlock != nil { affordances.insert(.block) }
        if onReport != nil { affordances.insert(.report) }
        self.affordances = affordances
    }

    /// Fixed-width `HH:mm` (24-hour, zero-padded) — the Twitch-native chat
    /// timestamp shape. Verbatim because every locale-aware hour style adds
    /// an am/pm marker on 12-hour devices; a chat column needs the stable
    /// 5-character form regardless of region. Built once: format-string
    /// parsing isn't free, and rows render by the thousand.
    private static let timestampFormat = Date.VerbatimFormatStyle(
        format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
        locale: .current,
        timeZone: .current,
        calendar: .current
    )

    /// Read once per row so the username color recomputes when the user toggles
    /// theme in Settings. (Environment changes trigger a re-render.)
    @Environment(\.colorScheme) private var colorScheme

    /// Chat rendering preferences (text size, timestamps, badges, animated
    /// emotes). Injected at RootView from @AppStorage-backed keys, so
    /// edits in ChatAppearanceScreen re-render visible rows live — the
    /// same environment-invalidation mechanism as `colorScheme` above,
    /// which also means it composes safely with the Equatable
    /// short-circuit (environment changes bypass `==`).
    @Environment(\.chatAppearance) private var appearance

    // MARK: - Equatable (profile-guided perf fix)
    //
    // Without it, SwiftUI can't compare the fresh closures and arrays
    // `ChatScreen` passes on every body re-evaluation, treats every parent
    // re-eval as "params changed", and re-runs ChatRow.body — a profile
    // measured ~1,400 evals/sec (1.48s of main-thread CPU in 68s).
    //
    // So `==` compares what the row renders from: `line`, `badgeEntries`,
    // `showsQuotedReply`, and the callbacks by PRESENCE (`affordances`),
    // never identity. A fresh closure does the same thing as the last one
    // (same line, same model), so it must not defeat the short-circuit; but
    // gaining or losing one changes the row (a menu item, the retry strip,
    // the quote's tap), so it must count. (Ignoring closures outright used
    // to swallow a reconfigure that only added `onDelete` once mod status
    // was learned.) SwiftUI applies this automatically for Equatable views.
    //
    // `nonisolated` because Equatable conformance from a @MainActor View
    // requires `==` to be callable from any actor. Every compared field is
    // a Sendable `let`, so no actor-isolated state is touched.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.line == rhs.line
            && lhs.badgeEntries == rhs.badgeEntries
            && lhs.showsQuotedReply == rhs.showsQuotedReply
            && lhs.affordances == rhs.affordances
    }

    var body: some View {
        // The VStack makes the row "unary": rowContent's top-level switch
        // branches between structurally different views, and a multi-shape
        // row defeats the lazy-container fast path that templates row ids
        // without running every row's body (matters on the macOS LazyVStack
        // path; free on iOS where each row is its own hosting-cell root).
        // Single child + spacing 0 — layout-neutral. The .contextMenu also
        // attaches once here instead of per switch case.
        VStack(alignment: .leading, spacing: 0) {
            rowContent
        }
        // History dim: rustlog-sourced rows (join backfill, reconnect
        // gap-fill) render slightly faded so witnessed-live and fetched
        // history separate at a glance — the "New" divider marks the
        // boundary, the dim confirms it row by row. 0.75 sits above the
        // 0.55 in-flight treatment so the two states stay distinguishable.
        .opacity(line.isHistorical ? 0.75 : 1)
        .contextMenu { contextMenuItems }
    }

    /// Long-press actions. Only real chat messages get any — not bubbles,
    /// the divider, or deleted placeholders (whose kind isn't `.message`);
    /// for those the menu is empty and the long-press is a no-op, matching
    /// the platform default. Each item is present only when its callback is.
    @ViewBuilder
    private var contextMenuItems: some View {
        if case .message = line.kind {
            if let onReply {
                Button {
                    onReply()
                } label: {
                    Label("Reply", systemImage: "arrowshape.turn.up.left")
                }
            }
            if let onViewThread {
                Button {
                    onViewThread()
                } label: {
                    Label("View Thread", systemImage: "bubble.left.and.bubble.right")
                }
            }
            // Moderation and safety actions are `.destructive` — red, and
            // visually set apart from the benign read-only actions above.
            if let onDelete {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete Message", systemImage: "trash")
                }
            }
            if let onBlock {
                Button(role: .destructive) {
                    onBlock()
                } label: {
                    Label("Block", systemImage: "hand.raised")
                }
            }
            if let onReport {
                Menu {
                    Button("Harassment") { onReport(.harassment) }
                    Button("Spam") { onReport(.spam) }
                } label: {
                    Label("Report…", systemImage: "exclamationmark.bubble")
                }
            }
        }
    }

    @ViewBuilder
    private var rowContent: some View {
        // Dispatch on the line's Kind. .message renders inline; bubble
        // cases render as styled system rows; .deletedPlaceholder dims
        // and strikethroughs the content in place.
        switch line.kind {
        case .message:
            // Delivery-state dispatch only applies to .message rows —
            // sub/raid/system bubbles can't be in `.sending` or
            // `.failed` since we don't send those (they always arrive
            // via EventSub already-delivered).
            switch line.deliveryState {
            case .delivered where isCompactBot:
                compactBotBody
            case .delivered:
                messageWithOptionalQuote
            case .sending:
                // Dimmed treatment so the user reads "this is in flight."
                // We don't add a spinner — chat updates fast enough
                // (~150ms to echo) that a spinner would barely render.
                // The opacity dip is more legible than animation churn.
                // 0.65 floor: a send stuck in flight on a slow connection can
                // be the only visible copy — keep it above AA contrast.
                messageWithOptionalQuote
                    .opacity(0.65)
            case .failed(let reason, _):
                // Stack the row + a compact failure footer. Tap the
                // whole failure footer to retry.
                VStack(alignment: .leading, spacing: 4) {
                    messageWithOptionalQuote
                        .opacity(0.7)
                    FailedSendFooter(reason: reason, onRetry: onRetry)
                }
            }
        case .deletedPlaceholder:
            // Render the original content but dimmed + struck-through.
            // We don't change the data shape — the original `runs` stays
            // available — so future "moderator-only reveal" features
            // can show the original content behind the strike.
            // 0.75 (matching the isHistorical dim), not 0.6: `.secondary` is
            // already reduced-contrast — stacking a deep opacity cut on top
            // compounds below the AA floor in light mode.
            messageBody
                .foregroundStyle(.secondary)
                .opacity(0.75)
                .overlay(alignment: .leading) {
                    // Subtle strikethrough line across the row's text run.
                    Rectangle()
                        .fill(.tertiary)
                        .frame(height: 1)
                        .offset(y: -2)
                }
        case .subBubble(let bubble):
            SubBubbleRow(bubble: bubble)
        case .raidBubble(let bubble):
            RaidBubbleRow(bubble: bubble)
        case .systemBubble(let text):
            SystemBubbleRow(text: text)
        case .newMessagesDivider:
            NewMessagesDividerRow()
        }
    }

    /// Wraps `messageBody` with a quoted-preview line above it when
    /// the line is a reply (and quoting isn't suppressed). For non-reply
    /// messages, this is just `messageBody` unchanged — no layout cost.
    /// Twitch web does the same: the "@parentUser " prefix Twitch puts in
    /// the body is replaced by a distinct quote.
    ///
    /// Quote + body share ONE container background so they read as a
    /// single unit. Proximity alone doesn't bind them in a dense chat
    /// list — without the shared plate, the quote visually attaches to
    /// whichever message happens to sit above it. When the line is also
    /// highlighted (@-mention), the container takes the accent tint
    /// instead of stacking a second plate inside.
    @ViewBuilder
    private var messageWithOptionalQuote: some View {
        if showsQuotedReply, let reply = line.replyParent {
            // Discord-style: a thin elbow curves from the quoted line down
            // into the reply — binds the pair without a heavy grey plate.
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .center, spacing: 4) {
                    ReplyElbow()
                        .stroke(Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .frame(width: 16, height: 9)
                        .offset(y: 4)
                        .accessibilityHidden(true)
                    QuotedReplyPreview(reply: reply, onViewThread: onViewThread)
                }
                .padding(.leading, 6)
                messageBody(highlightPlate: line.isHighlighted)
            }
        } else {
            messageBody
        }
    }

    /// The standard inline message body (badges + username + runs).
    /// Pulled out as a property so .deletedPlaceholder can overlay it
    /// without duplicating the layout.
    private var messageBody: some View {
        messageBody(highlightPlate: line.isHighlighted)
    }

    /// Styled username Text, ready to interpolate alongside the colon.
    /// When the chatter's display name is a localized variant of their
    /// login (and the setting is on), the login is appended in dimmed
    /// parentheses — order per `appearance.loginNameDisplay`.
    ///
    /// Takes the row's already-computed body font: `appearance.font`
    /// allocates a fresh `Font` per access, so `messageBody` computes it
    /// once and threads it through here and every `runView`.
    private func usernamePrefix(bodyFont: Font, color: Color) -> Text {
        let nameFont = bodyFont.weight(.semibold)
        // Fast path: only a genuinely localized name needs the annotation
        // lookup. `hasLocalizedDisplayName` is precomputed on the line, so the
        // common case (display name is just the login) short-circuits here and
        // skips `loginAnnotation`'s two `.lowercased()` allocations per body.
        // The flag mirrors that trigger, so this is behavior-preserving.
        guard line.hasLocalizedDisplayName,
              let pair = ChatAppearance.loginAnnotation(
                  displayName: line.authorDisplayName,
                  login: line.authorUserLogin,
                  style: appearance.loginNameDisplay
              ) else {
            return Text(line.authorDisplayName)
                .font(nameFont)
                .foregroundStyle(color)
        }
        let primary = Text(pair.primary)
            .font(nameFont)
            .foregroundStyle(color)
        let secondary = Text(" (\(pair.secondary))")
            .font(nameFont)
            .foregroundStyle(Color.secondary)
        return Text("\(primary)\(secondary)")
    }

    /// Combined VoiceOver label for the whole message row, e.g.
    /// "Landy, Moderator: hello chat KappaPride". Without the combined
    /// element, every timestamp/badge/word/emote run is its own VoiceOver
    /// stop — one message becomes 10+ swipes, and a full scrollback
    /// thousands. O(runs) string joins; only rebuilt when the row's body
    /// actually re-evaluates (the Equatable short-circuit still applies).
    /// Runs read through the shared `LineRun.plainText(.spoken)` mapping.
    private var accessibilityMessageLabel: String {
        let body = line.runs.map { $0.plainText(.spoken) }.joined(separator: " ")
        var speaker = line.authorDisplayName
        if appearance.showBadges {
            let titles = badgeEntries.compactMap(\.title)
            if !titles.isEmpty {
                speaker += ", " + titles.joined(separator: ", ")
            }
        }
        if case .deletedPlaceholder = line.kind {
            return "\(speaker): message deleted. \(body)"
        }
        return "\(speaker): \(body)"
    }

    /// `highlightPlate: false` lets the reply container own the tint —
    /// a highlighted reply gets ONE accent plate around quote + body,
    /// not a second one nested inside.
    @ViewBuilder
    private func messageBody(highlightPlate: Bool) -> some View {
        // Computed ONCE per body — `appearance.font` builds a new
        // `Font.system(size:)` on every access, and this body would
        // otherwise read it once per text run plus timestamp + username.
        let bodyFont = appearance.font
        // Computed ONCE per body too — `usernameColor` runs a hex parse +
        // RGB→HSL→clamp→RGB conversion, and the username prefix would otherwise
        // read it once per name component.
        let nameColor = usernameColor
        // `imageScale` is also a computed property (a division); read it once
        // rather than per badge + per emote run.
        let imgScale = appearance.imageScale
        // No hanging indent — wrapped lines continue flush at the leading
        // edge, matching Twitch's native chat. The 14pt indent we shipped
        // briefly made continuations look misaligned ("starts a little bit
        // after the edge") rather than intentionally nested.
        FlowLayout(spacing: 4, alignment: .firstTextBaseline) {
            // Optional leading timestamp. Fixed-width 24-hour HH:mm (matching
            // Twitch's native chat) — verbatim rather than locale-aware
            // `.dateTime.hour().minute()`, which appends an am/pm marker in
            // 12-hour locales and makes the column wide and ragged. Body-size
            // + secondary grey so rows read uniformly, not metadata-tiny.
            //
            // One step smaller than the body (0.8×): at full body size the
            // timestamp column competed with usernames for attention. It still
            // shares the first text baseline, so it lines up with the name.
            if appearance.showTimestamps {
                timestampText
            }
            // Badges keyed by `url` — a stable per-badge identity across row
            // re-renders, so SwiftUI keeps each badge's `LazyImage` (and its
            // loaded image) instead of destroying and re-creating it. Keying
            // by offset churned them whenever a row re-rendered (e.g. on a
            // `.deletedPlaceholder` flip).
            if appearance.showBadges {
                ForEach(badgeEntries, id: \.url) { entry in
                    BadgeImage(entry: entry, scale: imgScale)
                }
            }
            // Username prefix. The colon is interpolated into the same Text
            // so it hugs the name ("Landy:") instead of floating 4pt away as
            // its own flow item — and the pair can never wrap apart.
            Text("\(usernamePrefix(bodyFont: bodyFont, color: nameColor))\(Text(":").foregroundStyle(.secondary))")

            // Walk the pre-normalized runs in order. `line.runs` never
            // changes shape for a given line id (a mutation replaces the
            // whole ChatLine; see `ChatLineRunsInvariantTests`), so
            // positional indices are safe identity here — and they avoid an
            // `Array(...enumerated())` allocation per body without disturbing
            // the stateful emote image views (`LazyImage` /
            // `AnimatedImageView`) of unchanged runs.
            ForEach(line.runs.indices, id: \.self) { idx in
                runView(for: line.runs[idx], bodyFont: bodyFont, imageScale: imgScale)
            }
        }
        // Highlighted lines get an accent-tinted backplate so a "@me ..."
        // mention stands out at a glance. Subtle — uses the system accent at
        // low opacity so it doesn't fight with the row content.
        .padding(.horizontal, highlightPlate ? 4 : 0)
        .padding(.vertical, highlightPlate ? 2 : 0)
        .background {
            if highlightPlate {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.12))
            }
        }
        // One VoiceOver stop per message. Without this, every timestamp,
        // badge, name, and text/emote run is its own swipe stop — a single
        // message reads as 5-8 fragments. The explicit label replaces the
        // awkward child concatenation ("14 32 Moderator Landy colon hello…")
        // with a purpose-built read-out (author, badge titles, emote names).
        // Only rebuilt when the row's body re-evaluates — the Equatable
        // short-circuit still gates that.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityMessageLabel)
    }

    /// Dispatch a single run to its inline view. Each case is a one-liner —
    /// the Normalizer already did all the tokenization work, so this is
    /// purely "given run X, what view?"
    @ViewBuilder
    private func runView(for run: LineRun, bodyFont: Font, imageScale: CGFloat) -> some View {
        // All text runs derive their font from the appearance setting —
        // passed in by `messageBody`, which computes it once per row.
        switch run {
        case .text(let body):
            // Link-looking words become tappable (an AttributedString link
            // keeps this a plain `Text`, so baseline alignment in the flow
            // layout is unchanged). The detector's fast path rejects any word
            // without a dot, so ordinary words cost one byte scan.
            if let url = ChatLinkDetector.url(in: body) {
                Text(Self.linkText(body, url: url))
                    .font(bodyFont)
            } else {
                Text(body)
                    .font(bodyFont)
            }

        case .emote(let emote):
            // 7TV / BTTV / FFZ inline, through the shared `EmoteImageView`.
            ThirdPartyEmoteImage(
                emote: emote,
                scale: imageScale,
                allowAnimation: appearance.animatedEmotes
            )

        case .twitchEmote(let reference, let displayName):
            TwitchEmoteImage(emote: reference, displayName: displayName)

        case .mention(let login, let isMe):
            // @mentions render in accent color. Self-mentions get an
            // extra weight bump so they pop more (in addition to the
            // row-level highlight backplate).
            Text("@\(login)")
                .font(bodyFont.weight(isMe ? .bold : .semibold))
                .foregroundStyle(Color.accentColor)

        case .cheermote(let prefix, let bits, _):
            // Cheermotes render as compact text for now ("cheer100" → "💎100").
            // Full bits rendering (animated tier-colored icons) is a later slice.
            Text("\(prefix)\(bits)")
                .font(bodyFont.weight(.semibold))
                .foregroundStyle(.orange)
        }
    }

    // MARK: - Timestamps, links, compact bots

    /// Leading `HH:mm`, one step smaller than the body text.
    private var timestampText: some View {
        Text(line.timestamp, format: Self.timestampFormat)
            .font(.system(size: appearance.textSizePoints * 0.8).monospacedDigit())
            .foregroundStyle(.secondary)
    }

    /// A word rendered as an underlined link in the tint color.
    private static func linkText(_ word: String, url: URL) -> AttributedString {
        var text = AttributedString(word)
        text.link = url
        text.underlineStyle = .single
        return text
    }

    /// True when this row should take the compact bot treatment. Twitch
    /// logins are already lowercase, so no per-render `lowercased()`.
    private var isCompactBot: Bool {
        appearance.compactBots
            && !line.isHighlighted
            && ChatFilterSettings.knownBotLogins.contains(line.authorUserLogin)
    }

    /// Bot message, compact: smaller, dimmed, at most three lines, with
    /// box-drawing / dingbat banner decoration stripped. Rendered as ONE
    /// `Text` (emotes fall back to their names — bots rarely use them) so
    /// `lineLimit` can cap it; the flow layout can't truncate.
    private var compactBotBody: some View {
        let font = Font.system(size: appearance.textSizePoints * 0.85)
        let name = Text(line.authorDisplayName)
            .font(font.weight(.semibold))
            .foregroundStyle(usernameColor)
        let message = Text(Self.compactBotAttributedBody(line.runs)).font(font)
        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            if appearance.showTimestamps {
                timestampText
            }
            Text("\(name)\(Text(":").foregroundStyle(.secondary)) \(message)")
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .opacity(0.85)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityMessageLabel)
    }

    /// Words joined back into one string, decoration stripped, links kept.
    static func compactBotAttributedBody(_ runs: [LineRun]) -> AttributedString {
        var result = AttributedString()
        for run in runs {
            let word = stripDecoration(run.plainText(.visual))
            guard !word.isEmpty else { continue }
            if !result.characters.isEmpty { result.append(AttributedString(" ")) }
            if case .text = run, let url = ChatLinkDetector.url(in: word) {
                result.append(linkText(word, url: url))
            } else {
                result.append(AttributedString(word))
            }
        }
        return result
    }

    /// Removes box-drawing, block-element and dingbat scalars — the
    /// "❀────SHOUTOUT────❀" banner furniture bots wrap messages in.
    static func stripDecoration(_ word: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in word.unicodeScalars {
            switch scalar.value {
            case 0x2500...0x259F, 0x2700...0x27BF, 0x2E3A...0x2E3B, 0x2014, 0x2015:
                continue
            default:
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    /// Per-row username color. Empty `line.authorColor` (user hasn't picked one)
    /// falls back to `.primary` so the system handles light/dark automatically.
    private var usernameColor: Color {
        guard !line.authorColor.isEmpty else { return .primary }
        return .twitchUsername(hex: line.authorColor, scheme: colorScheme)
    }
}
