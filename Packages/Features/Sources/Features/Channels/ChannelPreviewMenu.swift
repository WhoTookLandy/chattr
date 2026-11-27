import SwiftUI
import Core
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

    #if os(iOS)
    @Environment(\.playback) private var playback
    #endif

    /// Sets the preferences the chat header and its More menu use. Written
    /// straight to `UserDefaults` (their `@AppStorage` readers still see
    /// it): nothing here reads them, and an `@AppStorage` pair attached two
    /// observers to every row carrying this menu.
    private func setVideo(visible: Bool, audioOnly: Bool) {
        let defaults = UserDefaults.standard
        defaults.set(visible, forKey: StreamHeaderView.expandedKey)
        defaults.set(audioOnly, forKey: PlayerSettings.audioOnlyKey)
    }

    /// Reads the user's max-quality cap without attaching `@AppStorage` observers
    /// to every row carrying this preview menu.
    private var maxQuality: PlayerQuality {
        UserDefaults.standard.string(forKey: PlayerSettings.maxQualityKey)
            .flatMap(PlayerQuality.init(rawValue:)) ?? .auto
    }

    func body(content: Content) -> some View {
        content
            #if os(iOS)
            .retainsPinnedAudioFlag(for: stream?.userId ?? "", in: stream != nil ? playback : nil)
            #endif
            .contextMenu {
                if let stream {
                    Button {
                        #if os(iOS)
                        if let playback, playback.isPinnedAudio(stream.userId) {
                            playback.promotePinnedToPrimary(
                                channelId: stream.userId,
                                audioOnly: false,
                                quality: maxQuality,
                                syncGlobalDisplayPreferences: true
                            )
                        } else {
                            setVideo(visible: true, audioOnly: false)
                        }
                        #else
                        setVideo(visible: true, audioOnly: false)
                        #endif
                        open(.explicit)
                    } label: {
                        Label("Watch", systemImage: "play.rectangle")
                    }
                    #if os(iOS)
                    // Audio-only and pinned background audio require the native engine.
                    if PlayerSettings.isNativePlaybackEnabled {
                        Button {
                            setVideo(visible: true, audioOnly: true)
                            open(.explicit)
                        } label: {
                            Label("Listen (Audio Only)", systemImage: "headphones")
                        }
                        if let playback {
                            // Uses per-channel flag + non-observing capacity check so
                            // Home/Search/Chats rows never subscribe to `pinnedAudio`.
                            let isPinned = playback.pinnedAudioFlag(for: stream.userId).isPinned
                            let isFull = !isPinned && !playback.canPinMoreBackgroundAudio
                            Button {
                                if isPinned {
                                    playback.unpinBackgroundAudio(channelId: stream.userId)
                                } else {
                                    let descriptor = ChannelDescriptor(
                                        platform: .twitch,
                                        channelId: stream.userId,
                                        channelLoginName: stream.userLogin,
                                        channelDisplayName: stream.userName,
                                        profileImageURL: profileImageURL
                                    )
                                    _ = playback.pinBackgroundAudio(
                                        descriptor,
                                        title: stream.title,
                                        profileImageURL: profileImageURL,
                                        stream: stream,
                                        quality: maxQuality
                                    )
                                }
                            } label: {
                                Label(
                                    isPinned ? "Stop Background Audio" : "Listen in Background",
                                    systemImage: isPinned ? "speaker.slash.fill" : "pin"
                                )
                            }
                            .disabled(isFull)
                        }
                    }
                    #endif
                    Button {
                        setVideo(visible: false, audioOnly: false)
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
                LazyImage(request: StreamFormatting.thumbnailRequest(stream.thumbnailUrl, width: 640, height: 360)) { state in
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
