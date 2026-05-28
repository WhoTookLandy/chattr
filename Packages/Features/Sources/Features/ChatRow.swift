import SwiftUI
import TwitchKit
import ChatModel
import EmoteSources
import DesignSystem

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
struct ChatRow: View {
    let line: ChatLine
    let badgeEntries: [ChatBadgeEntry]

    /// Read once per row so the username color recomputes when the user toggles
    /// theme in Settings. (Environment changes trigger a re-render.)
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        FlowLayout(spacing: 4, alignment: .firstTextBaseline) {
            // Badges (zero or more — broadcasters typically have 1, partners 2-3,
            // moderators 1, regular subscribers 1, etc.)
            ForEach(Array(badgeEntries.enumerated()), id: \.offset) { _, entry in
                BadgeImage(entry: entry)
            }
            // Username prefix
            Text(line.authorDisplayName)
                .font(.callout.weight(.semibold))
                .foregroundStyle(usernameColor)
            Text(":")
                .foregroundStyle(.secondary)

            // Walk the pre-normalized runs in order. The Normalizer already
            // coalesced adjacent text runs, so we get a clean "text, emote,
            // text, mention, text" pattern with minimum Text views — better
            // baseline alignment for inline emote rows.
            ForEach(Array(line.runs.enumerated()), id: \.offset) { _, run in
                runView(for: run)
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

    /// Pick the 2x size (the middle of x1/x2/x4) — matches chat row line
    /// height closely on 1x/2x/3x displays, with the CDN doing the
    /// upscaling/downscaling. Fall back to whatever size we have if 2x
    /// isn't present (rare but possible for partial-variant emotes).
    private var imageURL: URL? {
        emote.urls[.x2] ?? emote.urls[.x1] ?? emote.urls[.x4]
    }

    var body: some View {
        AsyncImage(url: imageURL) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            case .empty, .failure:
                // While loading or on failure, show the emote name as
                // text — better than a blank space, and the name often
                // hints at what the emote is ("KEKW", "POGGERS").
                Text(emote.name)
                    .font(.callout)
            @unknown default:
                Text(emote.name).font(.callout)
            }
        }
        .frame(maxWidth: 28, maxHeight: 24)
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
        AsyncImage(url: entry.url) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            case .empty, .failure:
                // Don't reserve space — let layout flow as if the badge weren't there.
                Color.clear.frame(width: 0, height: 0)
            @unknown default:
                Color.clear.frame(width: 0, height: 0)
            }
        }
        .frame(width: 18, height: 18)
        .accessibilityLabel(entry.title ?? "Chat badge")
    }
}
