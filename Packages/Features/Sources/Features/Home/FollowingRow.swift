import SwiftUI
import TwitchKit
import NukeUI
import Nuke

/// One Following row: avatar (red ring when live), name, and either
/// "● 41 · Just Chatting" or "Streamed 2 days ago" / "@login".
struct FollowingRow: View {
    let displayName: String
    let login: String
    let profileImageURL: URL?
    let stream: TwitchStream?
    let lastLiveAt: Date?

    var body: some View {
        HStack(spacing: 12) {
            LazyImage(request: ImageRequest.avatar(url: profileImageURL, side: 42)) { state in
                if let image = state.image {
                    image.resizable().scaledToFill()
                } else {
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.secondary.opacity(0.5))
                }
            }
            .frame(width: 42, height: 42)
            .clipShape(Circle())
            .padding(2)
            .overlay {
                if stream != nil { Circle().strokeBorder(.red, lineWidth: 2) }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.headline)
                    .lineLimit(1)
                if let stream {
                    HStack(spacing: 4) {
                        Circle().fill(.red).frame(width: 6, height: 6)
                        Text(stream.gameName.isEmpty
                             ? StreamFormatting.viewers(stream.viewerCount)
                             : "\(StreamFormatting.viewers(stream.viewerCount)) · \(stream.gameName)")
                            .lineLimit(1)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                } else {
                    Text(lastLiveAt.map(StreamFormatting.lastLive) ?? "@\(login)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
