import SwiftUI
import Accounts
import Channels
import TwitchKit
import Core
import os

private let logger = AppLogger.make("Features.ChatScreen")

// MARK: - FlowLayout

/// A SwiftUI Layout that arranges children left-to-right, wrapping to the next
/// line when horizontal space is exhausted. Used by ChatRow to mix Text and
/// emote image subviews in a single natural-reading flow.
struct FlowLayout: Layout {
    var spacing: CGFloat
    var alignment: VerticalAlignment

    init(spacing: CGFloat = 4, alignment: VerticalAlignment = .firstTextBaseline) {
        self.spacing = spacing
        self.alignment = alignment
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let containerWidth = proposal.width ?? .infinity
        var totalHeight: CGFloat = 0
        var currentX: CGFloat = 0
        var currentRowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: containerWidth, height: nil))
            if currentX + size.width > containerWidth, currentX > 0 {
                // Wrap to next line
                totalHeight += currentRowHeight + spacing
                currentX = 0
                currentRowHeight = 0
            }
            currentX += size.width + spacing
            currentRowHeight = max(currentRowHeight, size.height)
        }
        totalHeight += currentRowHeight
        return CGSize(width: containerWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let containerWidth = bounds.width
        var currentX: CGFloat = bounds.minX
        var currentY: CGFloat = bounds.minY
        var rowSubviews: [(subview: LayoutSubview, size: CGSize)] = []

        func flushRow() {
            guard !rowSubviews.isEmpty else { return }
            let rowHeight = rowSubviews.map(\.size.height).max() ?? 0
            var x = bounds.minX
            for (subview, size) in rowSubviews {
                // Align within row based on vertical alignment
                let yOffset: CGFloat
                switch alignment {
                case .firstTextBaseline:
                    // Approximate baseline alignment: bottom-align short items (emote images)
                    // with text. Since we can't query baseline from LayoutSubview directly,
                    // we bottom-align all items within the row height.
                    yOffset = rowHeight - size.height
                case .center:
                    yOffset = (rowHeight - size.height) / 2
                case .bottom:
                    yOffset = rowHeight - size.height
                default:
                    yOffset = 0
                }
                subview.place(
                    at: CGPoint(x: x, y: currentY + yOffset),
                    proposal: ProposedViewSize(width: size.width, height: size.height)
                )
                x += size.width + spacing
            }
            currentY += rowHeight + spacing
            rowSubviews.removeAll()
        }

        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: containerWidth, height: nil))
            if currentX + size.width > bounds.maxX, currentX > bounds.minX {
                flushRow()
                currentX = bounds.minX
            }
            rowSubviews.append((subview, size))
            currentX += size.width + spacing
        }
        flushRow()
    }
}

// MARK: - TwitchEmoteImage

/// Loads and displays a single Twitch native emote from the CDN.
/// Falls back to the literal text name while loading or on failure.
struct TwitchEmoteImage: View {
    let emote: EmoteReference
    let displayName: String

    var body: some View {
        AsyncImage(url: emoteURL) { phase in
            switch phase {
            case .empty:
                Text(displayName).font(.callout).foregroundStyle(.secondary)
            case .success(let image):
                image.resizable().scaledToFit().frame(height: 24)
            case .failure:
                Text(displayName).font(.callout)
            @unknown default:
                Text(displayName).font(.callout)
            }
        }
        .accessibilityLabel(Text(displayName))
    }

    private var emoteURL: URL? {
        let format = (emote.format ?? []).contains("animated") ? "animated" : "static"
        return URL(string: "https://static-cdn.jtvnw.net/emoticons/v2/\(emote.id)/\(format)/dark/2.0")
    }
}

// MARK: - ChatScreen

/// Renders live `channel.chat.message` events from EventSub as inline-emote rows.
///
/// Slice-2 interlude scope: Twitch native emote fragments render as CDN images.
/// Third-party emote providers (7TV/BTTV/FFZ) and animated WebP arrive in later slices.
public struct ChatScreen: View {
    private let account: Account
    private let accountStore: AccountStore
    private let channelId: String
    private let channelLoginName: String
    private let channelDisplayName: String

    @State private var session: ChannelSession?
    @State private var lines: [ChatMessage] = []
    @State private var errorMessage: String?

    public init(
        account: Account,
        accountStore: AccountStore,
        channelId: String,
        channelLoginName: String,
        channelDisplayName: String
    ) {
        self.account = account
        self.accountStore = accountStore
        self.channelId = channelId
        self.channelLoginName = channelLoginName
        self.channelDisplayName = channelDisplayName
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .padding()
                    }
                    ForEach(lines) { line in
                        ChatRow(message: line)
                            .id(line.messageId)
                    }
                }
                .padding(.horizontal)
            }
            .onChange(of: lines.count) { _, _ in
                if let last = lines.last {
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(last.messageId, anchor: .bottom)
                    }
                }
            }
        }
        .navigationTitle("#\(channelLoginName)")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .task { await startSession() }
    }

    @MainActor
    private func startSession() async {
        do {
            let client = accountStore.client(for: account)
            let session = ChannelSession(
                client: client,
                channelId: channelId,
                channelLoginName: channelLoginName,
                accountUserId: account.userId
            )
            try await session.start()
            self.session = session
            logger.info("ChatScreen started session for #\(channelLoginName)")

            // Bridge AsyncStream → @State updates on the main actor.
            Task { [session] in
                for await snapshot in session.lines {
                    await MainActor.run {
                        self.lines = snapshot
                    }
                }
            }
        } catch {
            errorMessage = "Couldn't open chat: \(error.localizedDescription)"
            logger.error("ChatScreen start failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - ChatRow

/// One chat-message row: bold username followed by inline-rendered fragments
/// (text, Twitch emote images, @mention highlights, cheermote text).
struct ChatRow: View {
    let message: ChatMessage

    var body: some View {
        FlowLayout(spacing: 4, alignment: .firstTextBaseline) {
            // Username prefix
            Text(message.chatterUserName)
                .font(.callout.weight(.semibold))
                .foregroundStyle(color)
            Text(":")
                .foregroundStyle(.secondary)

            // Walk message fragments
            ForEach(Array(message.message.fragments.enumerated()), id: \.offset) { _, fragment in
                fragmentView(for: fragment)
            }
        }
    }

    @ViewBuilder
    private func fragmentView(for fragment: ChatFragment) -> some View {
        switch fragment.type {
        case .emote:
            if let emoteRef = fragment.emote {
                TwitchEmoteImage(emote: emoteRef, displayName: fragment.text)
            } else {
                Text(fragment.text).font(.callout)
            }
        case .mention:
            Text(fragment.text)
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.accentColor)
        case .text, .cheermote:
            // Cheermotes render as text for slice-2 interlude; full bits rendering is a later slice.
            Text(fragment.text).font(.callout)
        case .unknown:
            Text(fragment.text).font(.callout)
        }
    }

    /// Best-effort author color. Falls back to neutral when not parseable.
    private var color: Color {
        guard !message.color.isEmpty,
              let parsed = Color(hex: message.color) else {
            return .primary
        }
        return parsed
    }
}

// MARK: - Color hex helper

/// Tiny helper: Color from "#RRGGBB" string.
private extension Color {
    init?(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt64(s, radix: 16) else { return nil }
        let r = Double((v >> 16) & 0xff) / 255
        let g = Double((v >> 8) & 0xff) / 255
        let b = Double(v & 0xff) / 255
        self.init(red: r, green: g, blue: b)
    }
}
