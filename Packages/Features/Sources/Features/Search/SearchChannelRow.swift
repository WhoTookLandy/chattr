import SwiftUI
import TwitchKit
import Nuke
import NukeUI

/// Full-bleed channel row for Search (category drill-down and live/offline
/// following matches). Shows right-aligned tabular viewer counts and the
/// stream title when live so rows carry real context without extra chrome.
struct SearchChannelRow: View {
    let displayName: String
    let login: String
    let profileImageURL: URL?
    let stream: TwitchStream?

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
                if stream != nil {
                    Circle().strokeBorder(.red, lineWidth: 2)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(displayName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let stream {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(.red)
                                .frame(width: 6, height: 6)
                            Text(StreamFormatting.viewers(stream.viewerCount))
                                .font(.caption.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let stream {
                    if !stream.title.isEmpty {
                        Text(stream.title)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if !stream.gameName.isEmpty {
                        Text(stream.gameName)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                } else {
                    Text("@\(login)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
