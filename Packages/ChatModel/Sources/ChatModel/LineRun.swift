import Foundation
import EmoteSources
import TwitchKit

/// One inline run inside a chat message.
///
/// A chat message renders as a sequence of `LineRun`s in reading order:
/// e.g., `[.text("hello"), .emote(pog), .mention("xqc", isMe: false)]`.
/// The `FlowLayout` view in the chat row lays them out with shared baselines
/// so emote images and surrounding text align visually.
///
/// Runs are WORD-LEVEL: a `.text` run is exactly one whitespace-delimited
/// word and never contains whitespace. `FlowLayout` can only wrap *between*
/// runs, so one-run-per-word is what makes chat lines wrap naturally; the
/// inter-word gap is the layout's `spacing`, not characters in the data.
///
/// ## Why this is separate from `TwitchKit.ChatFragment`
///
/// `ChatFragment` is the *input* shape: Twitch's pre-tokenized view of
/// a message (.text / .emote / .mention / .cheermote / .unknown). It only
/// knows about Twitch-native emotes — text-fragment tokens like "PogChamp"
/// (a 7TV emote name) arrive as plain text from Twitch's perspective.
///
/// `LineRun` is the *display* shape: it's the result of running each
/// `ChatFragment.text` token through the EmoteIndex to upgrade matching
/// names into `.emote` runs. After normalization, the renderer has a
/// uniform list of "render this thing" instructions without any further
/// tokenization work.
///
/// ## Why `.emote` and `.twitchEmote` are separate cases
///
/// They render differently:
///   - `.emote(EmoteSources.Emote)` → AsyncImage against a 7TV/BTTV/FFZ CDN URL
///   - `.twitchEmote(TwitchKit.EmoteReference)` → composed URL via
///     `static-cdn.jtvnw.net/emoticons/v2/<id>/...`
///
/// Folding them into one case would force the renderer to branch internally
/// on which CDN family the emote belongs to. Two cases keeps each renderer
/// focused on one URL pattern.
// Conformances: `Sendable` for cross-actor handoff, `Equatable` so SwiftUI
// can diff ChatLines containing arrays of runs. `Hashable` deliberately
// omitted because TwitchKit's `EmoteReference` doesn't conform — and
// SwiftUI's `ForEach` uses `Identifiable.id` for row identity rather
// than Hashable, so Hashable isn't actually needed here.
public enum LineRun: Sendable, Equatable {
    /// One word of plain text — no whitespace, see the type-level note.
    case text(String)

    /// A third-party emote (7TV / BTTV / FFZ) — resolved via EmoteIndex
    /// from a text token that matched a known emote name.
    case emote(Emote)

    /// A Twitch-native emote — comes pre-resolved inside the EventSub
    /// payload's `ChatFragment.emote`. Carries the full `EmoteReference`
    /// so the renderer can construct the correct Twitch CDN URL with
    /// format/theme/scale variants.
    case twitchEmote(reference: EmoteReference, displayName: String)

    /// A `@username` mention. `isMe` is true when the mentioned login
    /// matches the current user — drives the "highlighted" message
    /// styling (your name in the chat = visual emphasis).
    case mention(login: String, isMe: Bool)

    /// A URL detected in the text. Slice-2 renders these as plain styled
    /// text (foreground tint, optional underline); future slices can
    /// upgrade to tappable links / OG previews without changing this enum.
    case url(String)

    /// A cheermote (bits). Twitch fragments expose these pre-tokenized
    /// (e.g., "cheer100" → `(prefix: "cheer", bits: 100, tier: 1)`).
    /// Slice-2 renders the surface text only; full cheermote rendering
    /// (animated tier-colored icons) is a later slice.
    case cheermote(prefix: String, bits: Int, tier: Int)
}
