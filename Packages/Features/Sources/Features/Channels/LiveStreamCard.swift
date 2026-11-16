import SwiftUI
import TwitchKit
import Nuke
import NukeUI

/// Full-width featured card for Home's top live streams — the Twitch-feed
/// treatment, so Home leads with what's on rather than a settings-list row:
///
///   ┌──────────────────────────────────┐
///   │                                  │
///   │            thumbnail             │
///   │ ● 41                     2h 50m  │
///   └──────────────────────────────────┘
///   (av) Soochu
///        Twitch con day 4 best ABG POV @salamigal
///        Just Chatting
///
/// The remaining streams use the compact `LiveStreamRow`. Pure presentation:
/// stream + resolved avatar URL in, no stores.
struct LiveStreamCard: View {
    let stream: TwitchStream
    let profileImageURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            thumbnail
            HStack(alignment: .top, spacing: 10) {
                avatar
                VStack(alignment: .leading, spacing: 3) {
                    Text(stream.userName)
                        .font(.headline)
                        .lineLimit(1)
                    if !stream.title.isEmpty {
                        Text(stream.title)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                    }
                    if !stream.gameName.isEmpty {
                        Text(stream.gameName)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var thumbnail: some View {
        LazyImage(url: StreamFormatting.thumbnailURL(stream.thumbnailUrl, width: 640, height: 360)) { state in
            if let image = state.image {
                image.resizable().scaledToFill()
            } else if state.error != nil {
                ZStack {
                    Color.secondary.opacity(0.15)
                    Image(systemName: "tv").foregroundStyle(.secondary)
                }
            } else {
                Color.secondary.opacity(0.15)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            LiveBadge(viewerCount: stream.viewerCount, style: .overlay)
                .padding(8)
        }
        .overlay(alignment: .bottomTrailing) {
            StreamUptimeBadge(startedAt: stream.startedAt)
                .padding(8)
        }
    }

    private var avatar: some View {
        LazyImage(request: ImageRequest.avatar(url: profileImageURL, side: 36)) { state in
            if let image = state.image {
                image.resizable().scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary.opacity(0.5))
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(Circle())
    }
}
