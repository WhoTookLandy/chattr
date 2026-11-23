import SwiftUI
import TwitchKit
import Nuke
import NukeUI

/// Lightweight display item for one card in Home's top horizontal rail of
/// recently-streamed followed channels.
struct RecentChannelItem: Identifiable, Equatable {
    let broadcasterId: String
    let broadcasterLogin: String
    let broadcasterName: String
    let profileImageURL: URL?
    /// Static fallback values for `#Preview` / `-uiPreview` where
    /// `ChannelStatusStore` isn't injected.
    var fallbackTitle: String? = nil
    var fallbackLastLiveAt: Date? = nil
    var fallbackThumbnailURL: String? = nil

    var id: String { broadcasterId }
}

/// Horizontal rail of portrait cards across the top of Home → Live (matching
/// Twitch's top row of recently-streamed followed channels).
///
/// Each card isolates its own `ChannelStatusStore` lookup so lazy
/// `ensureLastLive` responses redraw only that card, never the entire feed.
struct RecentChannelsRail: View {
    let items: [RecentChannelItem]
    let onTap: (RecentChannelItem, ChatOpenIntent) -> Void
    let onCardAppear: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 10) {
                ForEach(items) { item in
                    RecentChannelCard(
                        item: item,
                        onTap: { intent in onTap(item, intent) },
                        onCardAppear: { onCardAppear(item.broadcasterId) }
                    )
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 12)
        }
    }
}

private struct RecentChannelCard: View {
    let item: RecentChannelItem
    let onTap: (ChatOpenIntent) -> Void
    let onCardAppear: () -> Void

    @Environment(\.channelStatus) private var channelStatus

    private static let cardWidth: CGFloat = 114
    private static let cardHeight: CGFloat = 148

    private var status: ChannelStatusStore.Status? {
        channelStatus?.statuses[item.broadcasterId]
    }

    private var lastTitle: String? {
        status?.lastLiveTitle ?? status?.channelInfo?.title ?? item.fallbackTitle
    }

    private var lastLiveAt: Date? {
        status?.lastLiveAt ?? item.fallbackLastLiveAt
    }

    private var thumbnailTemplate: String? {
        status?.lastLiveThumbnailURL ?? item.fallbackThumbnailURL
    }

    var body: some View {
        Button {
            onTap(.implicit)
        } label: {
            ZStack(alignment: .bottomLeading) {
                backdrop
                scrim
                metadata
            }
            .frame(width: Self.cardWidth, height: Self.cardHeight)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .channelPreviewMenu(
            name: item.broadcasterName,
            profileImageURL: item.profileImageURL,
            stream: nil,
            open: onTap
        )
        .onAppear(perform: onCardAppear)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var backdrop: some View {
        if let request = StreamFormatting.vodThumbnailRequest(thumbnailTemplate, width: 320, height: 180) {
            LazyImage(request: request) { state in
                if let image = state.image {
                    image.resizable().scaledToFill()
                } else {
                    avatarBackdrop
                }
            }
            .frame(width: Self.cardWidth, height: Self.cardHeight)
            .clipped()
        } else {
            avatarBackdrop
        }
    }

    private var avatarBackdrop: some View {
        ZStack {
            Color.secondary.opacity(0.18)
            if let avatarURL = item.profileImageURL {
                LazyImage(request: ImageRequest.avatar(url: avatarURL, side: 120)) { state in
                    if let image = state.image {
                        image
                            .resizable()
                            .scaledToFill()
                            .blur(radius: 10)
                            .opacity(0.45)
                    }
                }
            }
        }
        .frame(width: Self.cardWidth, height: Self.cardHeight)
        .clipped()
    }

    private var scrim: some View {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(0.2), location: 0),
                .init(color: .black.opacity(0.48), location: 0.48),
                .init(color: .black.opacity(0.88), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                avatar
                Text(item.broadcasterName)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            if let lastTitle, !lastTitle.isEmpty {
                Text(lastTitle)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)
            }
            Text(lastLiveLabel)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    private var avatar: some View {
        LazyImage(request: ImageRequest.avatar(url: item.profileImageURL, side: 20)) { state in
            if let image = state.image {
                image.resizable().scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .frame(width: 20, height: 20)
        .clipShape(Circle())
    }

    private var lastLiveLabel: String {
        if let lastLiveAt {
            return "Streamed \(StreamFormatting.lastLiveShort(lastLiveAt))"
        }
        return "@\(item.broadcasterLogin)"
    }

    private var accessibilityText: String {
        var parts = [item.broadcasterName]
        if let lastTitle, !lastTitle.isEmpty { parts.append(lastTitle) }
        parts.append(lastLiveLabel)
        return parts.joined(separator: ", ")
    }
}
