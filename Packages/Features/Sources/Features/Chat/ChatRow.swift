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
    /// menu. Optional — when nil, the menu item is hidden (so the
    /// thread-sheet view itself, which doesn't recurse, sets it nil
    /// to suppress the entry).
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

    /// Read once per row so the username color recomputes when the user toggles
    /// theme in Settings. (Environment changes trigger a re-render.)
    @Environment(\.colorScheme) private var colorScheme

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
        lhs.line == rhs.line && lhs.badgeEntries == rhs.badgeEntries
    }

    var body: some View {
        // Wrap the actual content in a Group so we can attach modifiers
        // (.contextMenu) once at the outer level without duplicating
        // them across each case in the switch. The Group is layout-
        // transparent — it doesn't affect sizing or stacking.
        rowContent
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
                messageWithOptionalQuote
                    .opacity(0.55)
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
            messageBody
                .foregroundStyle(.secondary)
                .opacity(0.6)
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
        }
    }

    /// Wraps `messageBody` with a quoted-preview block above it when
    /// the line is a reply. For non-reply messages, this is just
    /// `messageBody` unchanged — no layout cost.
    ///
    /// The quoted block visually borrows from Twitch web's reply
    /// rendering: a thin leading bar (the "quote" affordance) +
    /// dimmed parent author name + truncated parent body. One line,
    /// truncated tail.
    @ViewBuilder
    private var messageWithOptionalQuote: some View {
        if let reply = line.replyParent {
            VStack(alignment: .leading, spacing: 2) {
                quotedPreview(reply)
                messageBody
            }
        } else {
            messageBody
        }
    }

    /// Quoted-parent block. Two stacked lines: parent author + body.
    /// Uses caption2 / footnote weights so it visually subordinates to
    /// the real message body below.
    @ViewBuilder
    private func quotedPreview(_ reply: ChatLine.ReplyParent) -> some View {
        HStack(alignment: .top, spacing: 6) {
            // Leading "quote" bar — 2pt-wide rounded rect using the
            // tertiary system fill so it adapts to light/dark
            // automatically. Reads as "this is a quoted block"
            // without needing a separate icon.
            Capsule()
                .fill(.tertiary)
                .frame(width: 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(reply.parentAuthorDisplayName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(reply.parentBody)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.leading, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Replying to \(reply.parentAuthorDisplayName): \(reply.parentBody)")
    }

    /// The standard inline message body (badges + username + runs).
    /// Pulled out as a property so .deletedPlaceholder can overlay it
    /// without duplicating the layout.
    @ViewBuilder
    private var messageBody: some View {
        FlowLayout(spacing: 4, alignment: .firstTextBaseline, hangingIndent: 14) {
            // Badges keyed by `url` — stable per-badge identity across row
            // re-renders means SwiftUI doesn't destroy + re-create the
            // underlying AsyncImage (which would re-fetch the badge image).
            // Pre-fix: `id: \.offset` triggered AsyncImage churn whenever
            // a row re-rendered (e.g., on `.deletedPlaceholder` flip).
            ForEach(badgeEntries, id: \.url) { entry in
                BadgeImage(entry: entry)
            }
            // Username prefix
            Text(line.authorDisplayName)
                .font(.callout.weight(.semibold))
                .foregroundStyle(usernameColor)
            Text(":")
                .foregroundStyle(.secondary)

            // Walk the pre-normalized runs in order. `line.runs` is immutable
            // after `Normalizer.normalize(...)` returns (we replace the whole
            // ChatLine on mutation, never patch runs in place), so positional
            // indices are safe identity here. Critically, this avoids
            // `Array(...enumerated())` allocation per body call AND avoids
            // tripping AsyncImage's identity-change re-fetch for runs that
            // contain `.emote` / `.twitchEmote` cases.
            ForEach(line.runs.indices, id: \.self) { idx in
                runView(for: line.runs[idx])
            }
        }
        // Highlighted lines get an accent-tinted backplate so a "@me ..."
        // mention stands out at a glance. Subtle — uses the system accent at
        // low opacity so it doesn't fight with the row content.
        .padding(.horizontal, line.isHighlighted ? 4 : 0)
        .padding(.vertical, line.isHighlighted ? 2 : 0)
        .background {
            if line.isHighlighted {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.12))
            }
        }
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
    private func runView(for run: LineRun) -> some View {
        switch run {
        case .text(let body):
            Text(body)
                .font(.callout)

        case .emote(let emote):
            // 7TV / BTTV / FFZ inline. Prefer the 2x size (matches the
            // approx 24pt height of a chat row's line) for a sharp,
            // not-too-large render.
            EmoteImage(emote: emote)

        case .twitchEmote(let reference, let displayName):
            // Existing Twitch CDN renderer — same component used pre-2.2.
            TwitchEmoteImage(emote: reference, displayName: displayName)

        case .mention(let login, let isMe):
            // @mentions render in accent color. Self-mentions get an
            // extra weight bump so they pop more (in addition to the
            // row-level highlight backplate).
            Text("@\(login)")
                .font(.callout.weight(isMe ? .bold : .semibold))
                .foregroundStyle(Color.accentColor)

        case .url(let urlString):
            // Slice-2 renders URLs as accent-tinted text. Tappable links
            // come in a later slice.
            Text(urlString)
                .font(.callout)
                .foregroundStyle(Color.accentColor)

        case .cheermote(let prefix, let bits, _):
            // Cheermotes render as compact text for now ("cheer100" → "💎100").
            // Full bits rendering (animated tier-colored icons) is a later slice.
            Text("\(prefix)\(bits)")
                .font(.callout.weight(.semibold))
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

/// Sub/resub/gift/Prime bubble. Tier drives the leading symbol's tint
/// (Tier 1 / Prime → blue, Tier 2 → purple, Tier 3 → gold).
private struct SubBubbleRow: View {
    let bubble: ChatLine.SubBubble

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: bubble.isGift ? "gift.fill" : "star.fill")
                .font(.body.weight(.semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tierColor)
                .frame(width: 20)

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
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(tierColor.opacity(0.15))
        )
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
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "person.3.fill")
                .font(.body.weight(.semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.pink)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(bubble.fromBroadcasterDisplayName) raided!")
                    .font(.callout.weight(.semibold))
                Text("^[\(bubble.viewers) viewer](inflect: true)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.pink.opacity(0.15))
        )
    }
}

/// Generic system bubble — announcements, charity events, bits-badge-tier
/// upgrades, etc. Same visual treatment as the typed bubbles but with a
/// neutral icon and accent tint.
private struct SystemBubbleRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .font(.body)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 20)

            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.1))
        )
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
    /// Pre-resolved CDN URL, computed once in `init`. Storing as `let`
    /// (vs a `var` computed property) ensures `AsyncImage(url:)` sees a
    /// stable URL across re-renders — without this, the computed
    /// expression can appear different to SwiftUI between body calls
    /// and cause AsyncImage to abandon its in-flight load.
    private let imageURL: URL?

    init(emote: Emote) {
        self.emote = emote
        // Pick the 2x size (the middle of x1/x2/x4) — matches chat row
        // line height on @2x/@3x displays. Fall back to whatever size
        // we have if 2x is missing (rare but possible for partial-
        // variant emotes).
        self.imageURL = emote.urls[.x2] ?? emote.urls[.x1] ?? emote.urls[.x4]
    }

    var body: some View {
        Group {
            if emote.isAnimated {
                // Animated 7TV WebP / BTTV GIF / FFZ APNG — decode frames
                // via ImageIO and cycle them. Only animated emotes pay
                // this cost; the static majority use the cheap LazyImage
                // path below.
                AnimatedImageView(url: imageURL, width: 28, height: 24) {
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
                .frame(maxWidth: 28, maxHeight: 24)
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
        .frame(width: 18, height: 18)
        .accessibilityLabel(entry.title ?? "Chat badge")
    }
}
