import SwiftUI
import TwitchKit
import Channels
import ChatModel
import EmoteSources
import DesignSystem
import NukeUI

/// One chat-message row: badges → bold username → inline-rendered runs
/// (text, third-party emote images, Twitch native emote images, @mention
/// highlights, cheermote text).
///
/// **Phase 2.2 change**: input type is now `ChatModel.ChatLine` (the
/// display-ready, pre-normalized form) instead of `TwitchKit.ChatMessage`.
/// The `LineRun`s in the line are already tokenized — this view does
/// nothing more than dispatch each run to the right inline subview.
/// No regex, no string scanning, no per-render allocation.
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
    var onRetry: (() -> Void)? = nil
    /// Called when the user picks "Reply" from the long-press menu on
    /// a `.message` row. Optional for the same reason as `onRetry`.
    var onReply: (() -> Void)? = nil
    /// Called when the user picks "View Thread" from the long-press
    /// menu OR taps the quoted-reply preview line. Optional — when nil,
    /// the menu item is hidden and the quote tap is disabled (so the
    /// thread-sheet view itself, which doesn't recurse, sets it nil
    /// to suppress both).
    var onViewThread: (() -> Void)? = nil
    /// Called when a moderator picks "Delete Message" from the
    /// long-press menu. Optional — when nil, the menu item is hidden.
    /// `ChatScreen` only passes a non-nil closure when
    /// `chatModel.currentUserCanModerate` is true, so non-mods never
    /// see the affordance.
    var onDelete: (() -> Void)? = nil
    /// Called when the user picks "Block" from the long-press menu. nil hides the
    /// item (ChatScreen passes nil for the current user's own messages).
    var onBlock: (() -> Void)? = nil
    /// Called when the user picks a reason from "Report…". Same nil-hides rule.
    var onReport: ((UserBlockReason) -> Void)? = nil
    /// Whether a reply line renders its quoted-parent block. The thread
    /// sheet sets this false — inside a thread every message's parent is
    /// already visible right above it, so per-row quotes are pure noise.
    var showsQuotedReply: Bool = true

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
    // Without explicit Equatable, SwiftUI's default View diffing compares
    // stored properties by Swift's structural equality — but `ChatScreen`
    // passes freshly-allocated arrays (`badgeEntries`) and closures
    // (`onRetry`/`onReply`/`onViewThread`/`onDelete`) per body
    // re-evaluation. Closures aren't Equatable in Swift, so SwiftUI gives
    // up and treats every parent re-eval as "params changed" → re-runs
    // ChatRow.body even when nothing visible changed.
    //
    // Profile measured: 93,732 ChatRow body evaluations in a 68-second
    // recording (~1,378/sec) — far beyond what visible-row × 60Hz could
    // justify. Each individual eval was fast (~15µs), but the volume
    // accumulated to 1.48s of CPU on the main thread.
    //
    // With explicit Equatable comparing the semantically-significant
    // fields (line + badgeEntries), SwiftUI's diff short-circuits when
    // the underlying data is unchanged:
    //   - `line`: ChatLine is itself Equatable; identical line → equal
    //   - `badgeEntries`: array element-wise compare; identical
    //     ChatBadgeEntry sequence → equal (typically stable per line)
    //   - Closures: deliberately IGNORED. They're functionally identical
    //     across body re-evals (capture the same `line.id`, `chatModel`,
    //     etc.), and treating them as equal lets the short-circuit fire.
    //
    // SwiftUI applies this comparison automatically when a View conforms
    // to Equatable — no need to wrap in `EquatableView()` at call sites.
    //
    // `nonisolated` because Equatable conformance from a @MainActor View
    // requires `==` to be callable from any actor. The args are Sendable
    // (ChatLine + [ChatBadgeEntry]) so this is safe — no instance state
    // is accessed.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.line == rhs.line
            && lhs.badgeEntries == rhs.badgeEntries
            && lhs.showsQuotedReply == rhs.showsQuotedReply
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
        .contextMenu {
            // Reply only makes sense on actual chat messages — not
            // on sub/raid/system bubbles or deleted placeholders.
            // The menu is empty for those rows, which makes the
            // long-press a no-op (no menu pops), matching the
            // platform default.
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
                // Moderation action — visually separated from the
                // benign read-only actions above by .destructive
                // role (red icon + label, slight visual gap in
                // the menu). Only present when `onDelete` is
                // non-nil, which `ChatScreen` only does for
                // moderators.
                //
                // Doesn't show on `.deletedPlaceholder` rows
                // (the outer `if case .message` covers that — a
                // placeholder's kind is `.deletedPlaceholder`,
                // not `.message`).
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
            //
            // If this row is a reply (`line.replyParent != nil`), we
            // stack a quoted-preview block above the message body so
            // the reader sees what's being responded to. Twitch web
            // does the same thing — replaces the "@parentUser " prefix
            // Twitch normally puts in the message body with a distinct
            // visual treatment.
            switch line.deliveryState {
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
                    failureFooter(reason: reason)
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
            VStack(alignment: .leading, spacing: 3) {
                quotedPreview(reply)
                messageBody(highlightPlate: false)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(line.isHighlighted
                          ? Color.accentColor.opacity(0.12)
                          : Color.secondary.opacity(0.07))
            }
        } else {
            messageBody
        }
    }

    /// Quoted-parent preview: ONE line — reply arrow, parent author,
    /// truncated parent body. Single-line (vs the old stacked author/body)
    /// because vertical space is the scarcest resource in a fast chat;
    /// the quote is a glanceable hint, not content to read, and the full
    /// context is one tap away.
    ///
    /// The whole line is a button that opens the thread sheet — same
    /// action as the long-press "View Thread" menu item, but actually
    /// discoverable. Read-only contexts (thread sheet, previews) pass
    /// `onViewThread == nil`, which disables the tap without changing
    /// the visual.
    @ViewBuilder
    private func quotedPreview(_ reply: ChatLine.ReplyParent) -> some View {
        Button {
            onViewThread?()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(reply.parentAuthorDisplayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(reply.parentBody)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .buttonStyle(.plain)
        .disabled(onViewThread == nil)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Replying to \(reply.parentAuthorDisplayName): \(reply.parentBody)")
        .accessibilityHint(onViewThread == nil ? "" : "Opens the thread")
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
            if appearance.showTimestamps {
                Text(line.timestamp, format: Self.timestampFormat)
                    .font(bodyFont.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            // Badges keyed by `url` — stable per-badge identity across row
            // re-renders means SwiftUI doesn't destroy + re-create the
            // underlying AsyncImage (which would re-fetch the badge image).
            // Pre-fix: `id: \.offset` triggered AsyncImage churn whenever
            // a row re-rendered (e.g., on `.deletedPlaceholder` flip).
            if appearance.showBadges {
                ForEach(badgeEntries, id: \.url) { entry in
                    BadgeImage(entry: entry, scale: imgScale)
                }
            }
            // Username prefix. The colon is interpolated into the same Text
            // so it hugs the name ("Landy:") instead of floating 4pt away as
            // its own flow item — and the pair can never wrap apart.
            Text("\(usernamePrefix(bodyFont: bodyFont, color: nameColor))\(Text(":").foregroundStyle(.secondary))")

            // Walk the pre-normalized runs in order. `line.runs` is immutable
            // after `Normalizer.normalize(...)` returns (we replace the whole
            // ChatLine on mutation, never patch runs in place), so positional
            // indices are safe identity here. Critically, this avoids
            // `Array(...enumerated())` allocation per body call AND avoids
            // tripping AsyncImage's identity-change re-fetch for runs that
            // contain `.emote` / `.twitchEmote` cases.
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
        // message reads as 5-8 fragments. Pure accessibility-tree modifier;
        // adds nothing to the render hot path.
        .accessibilityElement(children: .combine)
    }

    /// Failure-state footer rendered below a `.failed` message row.
    /// Shows the drop reason from Twitch / the network error, and the
    /// whole strip is tappable to retry the send.
    ///
    /// Design choices:
    ///   - `exclamationmark.triangle.fill` with hierarchical rendering
    ///     in `.red` reads as "error" at any size without needing a
    ///     filled background — the symbol carries the meaning.
    ///   - "Tap to retry" reads better than a separate icon-button.
    ///     The whole strip is one tap target → bigger hit area, less
    ///     visual clutter than a 44pt circle next to the row.
    ///   - Disabling the tap when `onRetry` is nil keeps the same
    ///     visual for read-only contexts (priming, previews) without
    ///     a broken affordance.
    @ViewBuilder
    private func failureFooter(reason: String) -> some View {
        Button {
            onRetry?()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.red)
                    .imageScale(.small)
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.red)
                Spacer(minLength: 4)
                if onRetry != nil {
                    Image(systemName: "arrow.clockwise")
                        .imageScale(.small)
                        .foregroundStyle(.red)
                    Text("Retry")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.red.opacity(0.10))
            )
        }
        .buttonStyle(.plain)
        .disabled(onRetry == nil)
        .accessibilityLabel("Failed to send: \(reason). Tap to retry.")
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
            Text(body)
                .font(bodyFont)

        case .emote(let emote):
            // 7TV / BTTV / FFZ inline. Prefer the 2x size (matches the
            // approx 24pt height of a chat row's line) for a sharp,
            // not-too-large render.
            EmoteImage(
                emote: emote,
                scale: imageScale,
                allowAnimation: appearance.animatedEmotes
            )

        case .twitchEmote(let reference, let displayName):
            // Existing Twitch CDN renderer — same component used pre-2.2.
            TwitchEmoteImage(emote: reference, displayName: displayName)

        case .mention(let login, let isMe):
            // @mentions render in accent color. Self-mentions get an
            // extra weight bump so they pop more (in addition to the
            // row-level highlight backplate).
            Text("@\(login)")
                .font(bodyFont.weight(isMe ? .bold : .semibold))
                .foregroundStyle(Color.accentColor)

        case .url(let urlString):
            // Slice-2 renders URLs as accent-tinted text. Tappable links
            // come in a later slice.
            Text(urlString)
                .font(bodyFont)
                .foregroundStyle(Color.accentColor)

        case .cheermote(let prefix, let bits, _):
            // Cheermotes render as compact text for now ("cheer100" → "💎100").
            // Full bits rendering (animated tier-colored icons) is a later slice.
            Text("\(prefix)\(bits)")
                .font(bodyFont.weight(.semibold))
                .foregroundStyle(.orange)
        }
    }

    /// Per-row username color. Empty `line.authorColor` (user hasn't picked one)
    /// falls back to `.primary` so the system handles light/dark automatically.
    private var usernameColor: Color {
        guard !line.authorColor.isEmpty else { return .primary }
        return .twitchUsername(hex: line.authorColor, scheme: colorScheme)
    }
}

// MARK: - System bubbles
//
// Three distinct row types for system events. Each shares a common visual
// foundation: a tinted capsule background, a leading SF Symbol, and the
// Twitch-formatted system message. They diverge in tint and icon so the
// user can tell at a glance which kind of event happened.
//
// Design intent (from axiom-design's HIG guidance — see docs/conventions.md):
//   - Use semantic colors that adapt to light/dark mode automatically.
//   - Hierarchical symbol rendering for depth without explicit shadowing.
//   - Subtle tinted backgrounds (`opacity(0.15)` on accent colors) — not
//     opaque, not loud. The row is information, not an alert.

/// The shared shell behind every system bubble: a leading 20pt hierarchical
/// symbol and a tinted capsule background, with the event-specific content
/// slotted in. Tint drives both the icon colour and the background fill
/// (`tint.opacity(fillOpacity)`), so a bubble reads as one coherent accent.
private struct SystemEventBubble<Content: View>: View {
    let icon: String
    var iconWeight: Font.Weight = .semibold
    let tint: Color
    var fillOpacity: Double = 0.15
    var alignment: VerticalAlignment = .top
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: alignment, spacing: 10) {
            Image(systemName: icon)
                .font(.body.weight(iconWeight))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .frame(width: 20)
                // Decorative once the bubble reads as one combined element.
                .accessibilityHidden(true)

            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(tint.opacity(fillOpacity))
        )
        // One VoiceOver stop per event bubble (sub/raid/announcement),
        // matching ChatRow.messageBody's grouping.
        .accessibilityElement(children: .combine)
    }
}

/// Sub/resub/gift/Prime bubble. Tier drives the leading symbol's tint
/// (Tier 1 / Prime → blue, Tier 2 → purple, Tier 3 → gold).
private struct SubBubbleRow: View {
    let bubble: ChatLine.SubBubble

    var body: some View {
        SystemEventBubble(icon: bubble.isGift ? "gift.fill" : "star.fill", tint: tierColor) {
            VStack(alignment: .leading, spacing: 4) {
                // Twitch-formatted system message — the authoritative text.
                // We don't rebuild it because Twitch's localization is
                // already correct for the user's selected language.
                Text(bubble.systemMessage)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)

                // If the resub included a user message, render it dimmed
                // below — matches the Twitch web layout.
                if let userMessage = bubble.userMessage, !userMessage.isEmpty {
                    Text(userMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Tier-driven accent color. Maps to Twitch's conventional tier tints
    /// (T1 = blue / T2 = purple / T3 = gold / Prime = blue).
    private var tierColor: Color {
        switch bubble.tier {
        case .prime, .t1: return .blue
        case .t2:         return .purple
        case .t3:         return .yellow
        }
    }
}

/// "Someone raided you with N viewers" bubble.
private struct RaidBubbleRow: View {
    let bubble: ChatLine.RaidBubble

    var body: some View {
        SystemEventBubble(icon: "person.3.fill", tint: .pink, alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(bubble.fromBroadcasterDisplayName) raided!")
                    .font(.callout.weight(.semibold))
                Text("^[\(bubble.viewers) viewer](inflect: true)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Generic system bubble — announcements, charity events, bits-badge-tier
/// upgrades, etc. Same visual treatment as the typed bubbles but with a
/// neutral icon and accent tint.
private struct SystemBubbleRow: View {
    let text: String

    var body: some View {
        SystemEventBubble(icon: "info.circle.fill", iconWeight: .regular, tint: .secondary, fillOpacity: 0.1) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
        }
    }
}

/// The red "New" rule — separates messages from before the user was watching
/// (join backfill or a reconnect gap-fill) from live messages, matching the
/// Twitch-native treatment: a thin red line with a trailing "New" caption.
///
/// Pure presentation: no content, no context menu (the `.message`-only guard
/// in `ChatRow.body` keeps the long-press a no-op), and a single combined
/// accessibility element so VoiceOver reads one "New messages" landmark
/// instead of a meaningless 1pt rectangle. The `.isHeader` trait makes the
/// divider rotor-navigable — a VoiceOver user can jump straight to it in a
/// 500-row transcript, which is the divider's whole purpose.
private struct NewMessagesDividerRow: View {
    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(.red)
                .frame(height: 1)
            Text("New")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("New messages")
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Third-party emote rendering

/// Inline image view for a 7TV / BTTV / FFZ emote. Matches the visual
/// scale of `TwitchEmoteImage` (24×24pt nominal) so the rows look
/// consistent regardless of which CDN provided each emote.
///
/// **Format note**: 7TV serves WebP, BTTV serves PNG/GIF, FFZ serves PNG
/// (with optional animated variants). All three are decoded natively by
/// AsyncImage on iOS 14+ via ImageIO — **for static (first-frame only)**.
/// Phase 2.2 ships static rendering; animation lands in a follow-up.
private struct EmoteImage: View {
    let emote: Emote
    /// Size multiplier from the chat text-size setting, so emotes track
    /// the surrounding text instead of staying fixed at 24pt.
    let scale: CGFloat
    /// From `ChatAppearance.animatedEmotes`. When false, animated emotes
    /// take the static `LazyImage` path below and render their first
    /// frame — cheaper (no per-frame decode loop) and calmer.
    let allowAnimation: Bool
    /// Pre-resolved CDN URL, computed once in `init`. Storing as `let`
    /// (vs a `var` computed property) ensures `AsyncImage(url:)` sees a
    /// stable URL across re-renders — without this, the computed
    /// expression can appear different to SwiftUI between body calls
    /// and cause AsyncImage to abandon its in-flight load.
    private let imageURL: URL?

    init(emote: Emote, scale: CGFloat = 1, allowAnimation: Bool = true) {
        self.emote = emote
        self.scale = scale
        self.allowAnimation = allowAnimation
        // Pick the 2x size (the middle of x1/x2/x4) — matches chat row
        // line height on @2x/@3x displays. Fall back to whatever size
        // we have if 2x is missing (rare but possible for partial-
        // variant emotes).
        self.imageURL = emote.urls[.x2] ?? emote.urls[.x1] ?? emote.urls[.x4]
    }

    var body: some View {
        // Fixed line height, natural width: wide 7TV/FFZ emotes get their
        // real aspect ratio instead of being crushed into a square-ish box.
        // Computed from API metadata (not the loaded image) so the row
        // reserves the right width before the image arrives — no reflow
        // when a wide emote pops in.
        let emoteHeight = 24 * scale
        let emoteWidth = EmoteDisplayMetrics.width(aspectRatio: emote.aspectRatio, height: emoteHeight)
        Group {
            if emote.isAnimated {
                // Animated 7TV WebP / BTTV GIF / FFZ APNG — decode frames
                // via ImageIO and cycle them. Only animated emotes pay
                // this cost; the static majority use the cheap LazyImage
                // path below.
                //
                // With animations off this STILL goes through the frame
                // decoder (with `animate: false`) rather than LazyImage:
                // a first-frame-only decode renders delta-encoded WebPs
                // (blank opening frame) as empty space, while the decoder
                // picks the first VISIBLE frame as the static poster.
                AnimatedImageView(url: imageURL, width: emoteWidth, height: emoteHeight, animate: allowAnimation) {
                    Text(emote.name).font(.callout)
                }
            } else {
                // Static emote. LazyImage: sync memory-cache hit on first
                // frame (no flash on re-scroll), off-main decode, auto
                // memory+disk cache.
                LazyImage(url: imageURL) { state in
                    if let image = state.image {
                        image
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                    } else {
                        // While loading or on failure, show the emote name
                        // as text — the name often hints at the emote.
                        Text(emote.name)
                            .font(.callout)
                    }
                }
                .frame(maxWidth: emoteWidth, maxHeight: emoteHeight)
            }
        }
        .accessibilityLabel(emote.name)
    }
}

// MARK: - Badge rendering

/// 18pt-square inline badge image. Failed/loading badges collapse to nothing
/// (`Color.clear` at zero size) rather than showing a placeholder — chat rows
/// look cleaner without a stand-in icon, and the username + message still
/// render correctly while images load.
///
/// `interpolation(.high)` is important: badges are bitmaps being downsampled
/// from 72px (source 4x) to 54px physical pixels on @3x devices. Without
/// high-quality interpolation, edges look jagged on small icons.
private struct BadgeImage: View {
    let entry: ChatBadgeEntry
    /// Size multiplier from the chat text-size setting — see `EmoteImage`.
    var scale: CGFloat = 1

    var body: some View {
        LazyImage(url: entry.url) { state in
            if let image = state.image {
                image
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                // Don't reserve space — let layout flow as if the badge weren't there.
                Color.clear.frame(width: 0, height: 0)
            }
        }
        .frame(width: 18 * scale, height: 18 * scale)
        .accessibilityLabel(entry.title ?? "Chat badge")
    }
}
