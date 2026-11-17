import SwiftUI
import TwitchKit
import Nuke
import NukeUI

extension View {
    /// Long-press on a channel row → a preview card (thumbnail, title,
    /// category, viewers) with quick actions: Watch / Listen / Chat only,
    /// and Close Chat where it applies. A plain tap keeps doing `open`
    /// with the current video preference.
    ///
    /// `open` receives the intent: `.explicit` from Watch / Listen / Chat
    /// Only (they set the video state themselves, so Settings → When a Chat
    /// Opens must not override it), `.implicit` from Open Chat.
    func channelPreviewMenu(
        name: String,
        profileImageURL: URL?,
        stream: TwitchStream?,
        open: @escaping (ChatOpenIntent) -> Void,
        close: (() -> Void)? = nil
    ) -> some View {
        modifier(ChannelPreviewMenu(
            name: name,
            profileImageURL: profileImageURL,
            stream: stream,
            open: open,
            close: close
        ))
    }
}

private struct ChannelPreviewMenu: ViewModifier {
    let name: String
    let profileImageURL: URL?
    let stream: TwitchStream?
    let open: (ChatOpenIntent) -> Void
    let close: (() -> Void)?

    // The same preferences the chat header and its More menu use.
    @AppStorage(StreamHeaderView.expandedKey) private var videoVisible = false
    @AppStorage(PlayerSettings.audioOnlyKey) private var audioOnly = false

    func body(content: Content) -> some View {
        content.contextMenu {
            if stream != nil {
                Button {
                    videoVisible = true
                    audioOnly = false
                    open(.explicit)
                } label: {
                    Label("Watch", systemImage: "play.rectangle")
                }
                #if os(iOS)
                Button {
                    videoVisible = true
                    audioOnly = true
                    open(.explicit)
                } label: {
                    Label("Listen (Audio Only)", systemImage: "headphones")
                }
                #endif
                Button {
                    videoVisible = false
                    audioOnly = false
                    open(.explicit)
                } label: {
                    Label("Chat Only", systemImage: "bubble.left.and.bubble.right")
                }
            } else {
                Button { open(.implicit) } label: {
                    Label("Open Chat", systemImage: "bubble.left.and.bubble.right")
                }
            }
            if let close {
                Divider()
                Button(role: .destructive, action: close) {
                    Label("Close Chat", systemImage: "xmark")
                }
            }
        } preview: {
            ChannelPreviewCard(name: name, profileImageURL: profileImageURL, stream: stream)
        }
    }
}

/// The lifted preview: the stream thumbnail with live info, or the avatar
/// and "Offline" for a channel that isn't live.
private struct ChannelPreviewCard: View {
    let name: String
    let profileImageURL: URL?
    let stream: TwitchStream?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let stream {
                LazyImage(url: StreamFormatting.thumbnailURL(stream.thumbnailUrl, width: 640, height: 360)) { state in
                    if let image = state.image {
                        image.resizable().scaledToFill()
                    } else {
                        Color.black
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipped()
                .overlay(alignment: .bottomLeading) {
                    LiveBadge(viewerCount: stream.viewerCount, style: .overlay)
                        .padding(8)
                }
            }
            HStack(alignment: .top, spacing: 10) {
                LazyImage(request: ImageRequest.avatar(url: profileImageURL, side: 36)) { state in
                    if let image = state.image {
                        image.resizable().scaledToFill()
                    } else {
                        Image(systemName: "person.crop.circle.fill")
                            .resizable()
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 36, height: 36)
                .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.headline)
                    if let stream {
                        if !stream.title.isEmpty {
                            Text(stream.title)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        if !stream.gameName.isEmpty {
                            Text(stream.gameName)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    } else {
                        Text("Offline")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
        }
        .frame(width: 320)
    }
}
