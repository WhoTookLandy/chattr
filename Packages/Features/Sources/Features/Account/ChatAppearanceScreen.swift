import SwiftUI
import ChatModel
import Channels
import EmoteSources

/// Chat appearance settings with a live preview. Pushed from
/// ProfileScreen's Chat section.
///
/// ## Why a live preview
///
/// Appearance knobs (text size, timestamps, badges) are impossible to
/// evaluate from a label alone — "Large" means nothing until you see a
/// message rendered at it. The preview section renders *real* `ChatRow`
/// instances (the exact view live chat uses) against mock `ChatLine`s,
/// with the appearance environment built from the same `@AppStorage`
/// values the controls below write. Toggle a control → UserDefaults
/// changes → both this preview AND any open chat behind this screen
/// re-render in the same frame.
///
/// Using the production row view (not a hand-drawn imitation) means the
/// preview can never drift from reality when ChatRow's rendering evolves.
struct ChatAppearanceScreen: View {
    /// The signed-in user's login, used to render a realistic
    /// "@you" mention in the highlighted preview row.
    let currentUserLogin: String

    // Same keys RootView injects from — writing here re-renders every
    // chat surface live (see ChatAppearance's reactivity note).
    @AppStorage(ChatAppearance.textSizeKey) private var textSizeRaw: String = ChatAppearance.TextSize.standard.rawValue
    @AppStorage(ChatAppearance.showTimestampsKey) private var showTimestamps: Bool = false
    @AppStorage(ChatAppearance.showBadgesKey) private var showBadges: Bool = true
    @AppStorage(ChatAppearance.animatedEmotesKey) private var animatedEmotes: Bool = true

    private var textSize: ChatAppearance.TextSize {
        ChatAppearance.TextSize(rawValue: textSizeRaw) ?? .standard
    }

    /// Appearance assembled from the local @AppStorage mirrors —
    /// applied to the preview rows via `.environment` so they reflect
    /// edits immediately (this screen sits outside no special scope;
    /// RootView's injection would cover it too, but the explicit local
    /// injection keeps the preview correct even if this screen is ever
    /// presented outside RootView, e.g. in a #Preview).
    private var previewAppearance: ChatAppearance {
        ChatAppearance(
            textSize: textSize,
            showTimestamps: showTimestamps,
            showBadges: showBadges,
            animatedEmotes: animatedEmotes
        )
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    ChatRow(line: Self.previewLineChatter, badgeEntries: Self.previewModBadge)
                    ChatRow(line: Self.previewLineEmote, badgeEntries: [])
                    ChatRow(line: Self.previewLineMention(of: currentUserLogin), badgeEntries: [])
                }
                .environment(\.chatAppearance, previewAppearance)
                .padding(.vertical, 4)
                // The preview is illustrative, not interactive — block the
                // context menu's long-press so it doesn't read as real chat.
                .allowsHitTesting(false)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Chat preview reflecting the current appearance settings")
            } header: {
                Text("Preview")
            } footer: {
                Text("A sample of how chat messages will look.")
            }

            Section {
                Picker("Text Size", selection: Binding(
                    get: { textSize },
                    set: { textSizeRaw = $0.rawValue }
                )) {
                    ForEach(ChatAppearance.TextSize.allCases) { size in
                        Text(size.displayName).tag(size)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Text Size")
            } footer: {
                Text("Sizes scale with your Dynamic Type setting. Emotes and badges scale to match.")
            }

            Section {
                Toggle(isOn: $showTimestamps) {
                    Label("Timestamps", systemImage: "clock")
                }
                Toggle(isOn: $showBadges) {
                    Label("Badges", systemImage: "checkmark.seal")
                }
            } header: {
                Text("Message Details")
            } footer: {
                Text("Show the send time before each message, and chatter badges (moderator, subscriber, VIP) before usernames.")
            }

            Section {
                Toggle(isOn: $animatedEmotes) {
                    Label("Animated Emotes", systemImage: "sparkles")
                }
            } footer: {
                Text("When off, animated emotes show their first frame. Saves battery in busy chats.")
            }
        }
        .navigationTitle("Chat Appearance")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: - Preview fixtures
    //
    // Static so they're built once, not per body evaluation. Timestamps
    // are derived from .now at first access — close enough for a
    // preview, and avoids hardcoding a timezone-dependent date.

    /// Moderator badge from Twitch's global badge CDN. If the fetch
    /// fails (offline), `BadgeImage` collapses to zero size — preview
    /// still reads fine, just badge-less.
    private static let previewModBadge: [ChatBadgeEntry] = [
        ChatBadgeEntry(
            url: URL(string: "https://static-cdn.jtvnw.net/badges/v1/3267646d-33f0-4b17-b3df-f923a41db1d0/2")!,
            title: "Moderator"
        )
    ]

    private static let previewLineChatter = ChatLine(
        id: "preview-chatter",
        authorDisplayName: "PixelPeach",
        authorColor: "#FF69B4",
        // Word-level runs, matching Normalizer output — the preview must
        // wrap exactly like real chat lines do.
        runs: ChatModel.Normalizer.wordRuns(text: "welcome to the stream! today we're checking out the new update"),
        timestamp: Date.now.addingTimeInterval(-150)
    )

    /// 7TV "catJAM" — animated, so the Animated Emotes toggle visibly
    /// does something in the preview. On fetch failure the emote name
    /// renders as text (ChatRow's standard fallback).
    private static let previewLineEmote = ChatLine(
        id: "preview-emote",
        authorDisplayName: "DankDan",
        authorColor: "#1E90FF",
        runs: ChatModel.Normalizer.wordRuns(text: "this song is a banger") + [
            .emote(Emote(
                id: "60ae7316f7c927fad14e6ca2",
                name: "catJAM",
                urls: [.x2: URL(string: "https://cdn.7tv.app/emote/60ae7316f7c927fad14e6ca2/2x.webp")!],
                isAnimated: true,
                isZeroWidth: false,
                source: .sevenTV
            )),
        ],
        timestamp: Date.now.addingTimeInterval(-60)
    )

    private static func previewLineMention(of login: String) -> ChatLine {
        ChatLine(
            id: "preview-mention",
            authorDisplayName: "ChatterBoi",
            authorColor: "#9146FF",
            runs: [.mention(login: login, isMe: true)]
                + ChatModel.Normalizer.wordRuns(text: "totally agree with you on that one"),
            isHighlighted: true,
            timestamp: Date.now.addingTimeInterval(-15)
        )
    }
}
