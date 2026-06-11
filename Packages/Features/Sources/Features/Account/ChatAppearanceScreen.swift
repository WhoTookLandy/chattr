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
    @AppStorage(ChatAppearance.textSizePointsKey) private var textSizePoints: Double = ChatAppearance.defaultTextSizePoints
    @AppStorage(ChatAppearance.showTimestampsKey) private var showTimestamps: Bool = false
    @AppStorage(ChatAppearance.showBadgesKey) private var showBadges: Bool = true
    @AppStorage(ChatAppearance.animatedEmotesKey) private var animatedEmotes: Bool = true
    @AppStorage(ChatAppearance.edgeToEdgeKey) private var edgeToEdge: Bool = false
    @AppStorage(ChatAppearance.loginNameDisplayKey) private var loginNameDisplay: ChatAppearance.LoginNameDisplay = .displayFirst
    @AppStorage(ChatAppearance.chatHistoryLinesKey) private var chatHistoryLines: Int = ChatAppearance.defaultChatHistoryLines

    /// Same Dynamic Type multiplier RootView applies at injection — the
    /// preview must render at the size live chat will actually use.
    @ScaledMetric(relativeTo: .callout) private var typeScale: CGFloat = 1.0

    /// Appearance assembled from the local @AppStorage mirrors —
    /// applied to the preview rows via `.environment` so they reflect
    /// edits immediately (this screen sits outside no special scope;
    /// RootView's injection would cover it too, but the explicit local
    /// injection keeps the preview correct even if this screen is ever
    /// presented outside RootView, e.g. in a #Preview).
    private var previewAppearance: ChatAppearance {
        ChatAppearance(
            textSizePoints: textSizePoints * typeScale,
            showTimestamps: showTimestamps,
            showBadges: showBadges,
            animatedEmotes: animatedEmotes,
            loginNameDisplay: loginNameDisplay
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
                HStack(spacing: 12) {
                    // Anchor glyphs at the slider's actual bounds so the
                    // endpoints communicate real sizes, not abstract ideas.
                    Text("A")
                        .font(.system(size: ChatAppearance.textSizePointsRange.lowerBound))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Slider(
                        value: $textSizePoints,
                        in: ChatAppearance.textSizePointsRange,
                        step: 1
                    ) {
                        Text("Text Size")
                    }
                    Text("A")
                        .font(.system(size: ChatAppearance.textSizePointsRange.upperBound))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            } header: {
                HStack {
                    Text("Text Size")
                    Spacer()
                    // Live readout — gives the slider a concrete, repeatable
                    // value (useful for "what size was I on before?").
                    Text("\(Int(textSizePoints)) pt")
                        .monospacedDigit()
                }
            } footer: {
                Text("Scales with your Dynamic Type setting. Emotes and badges scale to match.")
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
                Picker(selection: $loginNameDisplay) {
                    Text("Off").tag(ChatAppearance.LoginNameDisplay.off)
                    Text("デレク (derek)").tag(ChatAppearance.LoginNameDisplay.displayFirst)
                    Text("derek (デレク)").tag(ChatAppearance.LoginNameDisplay.loginFirst)
                } label: {
                    Label("Show Username", systemImage: "at")
                }
            } header: {
                Text("Localized Names")
            } footer: {
                Text("When a chatter's display name differs from their username — common for non-Latin names — show the username alongside it.")
            }

            Section {
                Toggle(isOn: $animatedEmotes) {
                    Label("Animated Emotes", systemImage: "sparkles")
                }
            } footer: {
                Text("When off, animated emotes show their first frame. Saves battery in busy chats.")
            }

            Section {
                Picker(selection: $chatHistoryLines) {
                    ForEach(ChatAppearance.chatHistoryOptions, id: \.self) { count in
                        Text("\(count) messages").tag(count)
                    }
                } label: {
                    Label("Chat History", systemImage: "clock.arrow.circlepath")
                }
            } footer: {
                Text("How many messages each chat keeps in scrollback. Larger histories use more memory and make switching between open chats slower. Applies the next time a chat opens.")
            }

            Section {
                Toggle(isOn: $edgeToEdge) {
                    Label("Edge-to-Edge Chat", systemImage: "arrow.up.left.and.arrow.down.right")
                }
            } footer: {
                Text("Chat runs to the top of the screen and scrolls behind the floating header.")
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
        authorDisplayName: "デレク",
        authorUserLogin: "derek",
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
