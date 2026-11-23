import SwiftUI
import TwitchKit
import DesignSystem
import Nuke
import NukeUI

/// Compact horizontal 1-tap avatar strip of live followed channels at the top
/// of Search's zero-state. Keeps live follows immediately reachable while
/// leaving vertical space for Recent Searches and Browse Categories.
struct SearchLiveFollowsRail: View {
    let streams: [TwitchStream]
    let profileImageURLs: [String: URL]
    let onSelect: (TwitchStream, ChatOpenIntent) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 12) {
                ForEach(streams, id: \.userId) { stream in
                    let profileURL = profileImageURLs[stream.userId]
                    Button {
                        onSelect(stream, .implicit)
                    } label: {
                        railItem(stream: stream, profileURL: profileURL)
                    }
                    .buttonStyle(.plain)
                    .channelPreviewMenu(
                        name: stream.userName,
                        profileImageURL: profileURL,
                        stream: stream,
                        open: { intent in onSelect(stream, intent) }
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
    }

    private func railItem(stream: TwitchStream, profileURL: URL?) -> some View {
        VStack(spacing: 6) {
            ZStack(alignment: .bottom) {
                LazyImage(request: ImageRequest.avatar(url: profileURL, side: 54)) { state in
                    if let image = state.image {
                        image.resizable().scaledToFill()
                    } else {
                        Image(systemName: "person.crop.circle.fill")
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(.secondary.opacity(0.5))
                    }
                }
                .frame(width: 54, height: 54)
                .clipShape(Circle())
                .padding(2.5)
                .overlay {
                    Circle().strokeBorder(.red, lineWidth: 2)
                }

                Text(StreamFormatting.viewers(stream.viewerCount))
                    .font(.system(size: 10, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Color.red, in: Capsule())
                    .overlay {
                        Capsule().strokeBorder(Color.chatSurface, lineWidth: 1.5)
                    }
                    .offset(y: 4)
            }
            .padding(.bottom, 2)

            Text(stream.userName)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .frame(width: 64)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(stream.userName), live with \(StreamFormatting.viewers(stream.viewerCount)) viewers")
    }
}
