import SwiftUI
import TwitchKit
import Nuke
import NukeUI

/// Full-bleed edge-to-edge live stream card for Home → Live — modeled on
/// Twitch's vertical home feed so every live stream gets the same consistent
/// visual treatment, with an inline muted live video preview on the focused
/// card:
///
///   ┌──────────────────────────────────────┐
///   │                              ● Live  │
///   │       live preview / thumbnail       │
///   │ 2.3K viewers                 🔇  ••• │
///   └──────────────────────────────────────┘
///   (av) hello_kiko                   2h 50m
///   [ENG/KR/JP] MY NEW HOUSE IN TAIWAN…
///   [ Just Chatting ]
///                    ──────
struct LiveStreamCard: View {
    let stream: TwitchStream
    let profileImageURL: URL?
    let onOpen: (ChatOpenIntent) -> Void
    #if os(iOS)
    var previewController: HomeFeedPreviewController? = nil
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            mediaSurface
            metadataSection
            cardDivider
        }
        .contentShape(Rectangle())
    }

    // MARK: - Full-bleed 16:9 media

    private var mediaSurface: some View {
        ZStack {
            thumbnail
                .contentShape(Rectangle())
                .onTapGesture { onOpen(.implicit) }

            #if os(iOS)
            if let previewController, previewController.activeStreamID == stream.userId {
                let isReady = previewController.readyStreamID == stream.userId
                HomeFeedPreviewVideoView(controller: previewController, streamID: stream.userId)
                    .opacity(isReady ? 1 : 0)
                    .animation(.easeInOut(duration: 0.25), value: isReady)
                    .allowsHitTesting(false)
            }
            #endif
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .background(.black)
        .clipped()
        .overlay(alignment: .topTrailing) {
            livePill
                .padding(10)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottomLeading) {
            viewersPill
                .padding(10)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottomTrailing) {
            mediaActions
                .padding(10)
        }
    }

    private var thumbnail: some View {
        LazyImage(request: StreamFormatting.thumbnailRequest(stream.thumbnailUrl, width: 640, height: 360)) { state in
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    /// Top-right `● Live` pill matching Twitch's home feed chrome.
    private var livePill: some View {
        HStack(spacing: 5) {
            Image(systemName: "circle.fill")
                .font(.system(size: 7))
                .foregroundStyle(.red)
                .symbolEffect(.pulse, options: .repeating)
                .accessibilityHidden(true)
            Text("Live")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.black.opacity(0.65), in: Capsule())
        .accessibilityLabel("Live")
    }

    /// Bottom-left viewer count pill (`2.3K viewers`).
    private var viewersPill: some View {
        let count = StreamFormatting.viewers(stream.viewerCount)
        return Text("\(count) viewers")
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(.white)
            .contentTransition(.numericText())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityLabel("\(count) viewers")
    }

    /// Bottom-right circular mute toggle (when live preview is active) + more menu.
    private var mediaActions: some View {
        HStack(spacing: 8) {
            #if os(iOS)
            if let previewController, previewController.activeStreamID == stream.userId {
                Button {
                    previewController.toggleMute(for: stream.userId)
                } label: {
                    Image(systemName: previewController.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(.black.opacity(0.6), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(previewController.isMuted ? "Unmute preview" : "Mute preview")
            }
            #endif

            Menu {
                Button {
                    setVideoPreference(visible: true, audioOnly: false)
                    onOpen(.explicit)
                } label: {
                    Label("Watch", systemImage: "play.rectangle")
                }
                #if os(iOS)
                if PlayerSettings.isNativePlaybackEnabled {
                    Button {
                        setVideoPreference(visible: true, audioOnly: true)
                        onOpen(.explicit)
                    } label: {
                        Label("Listen (Audio Only)", systemImage: "headphones")
                    }
                }
                #endif
                Button {
                    setVideoPreference(visible: false, audioOnly: false)
                    onOpen(.explicit)
                } label: {
                    Label("Chat Only", systemImage: "bubble.left.and.bubble.right")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .bold))
                    .rotationEffect(.degrees(90))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(.black.opacity(0.6), in: Circle())
                    .contentShape(Circle())
            }
            .accessibilityLabel("More options for \(stream.userName)")
        }
    }

    private func setVideoPreference(visible: Bool, audioOnly: Bool) {
        let defaults = UserDefaults.standard
        defaults.set(visible, forKey: StreamHeaderView.expandedKey)
        defaults.set(audioOnly, forKey: PlayerSettings.audioOnlyKey)
    }

    // MARK: - Metadata below video

    private var metadataSection: some View {
        Button {
            onOpen(.implicit)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 10) {
                    avatar
                    Text(stream.userName)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(StreamFormatting.uptime(since: stream.startedAt))
                        .font(.caption.weight(.medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if !stream.title.isEmpty {
                    Text(stream.title)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                if !stream.gameName.isEmpty {
                    categoryBadge(stream.gameName)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private func categoryBadge(_ gameName: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "rectangle.stack")
                .font(.caption2.weight(.semibold))
            Text(gameName)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
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

    /// Subtle Twitch-style horizontal separator bar between full-bleed cards.
    private var cardDivider: some View {
        Capsule()
            .fill(Color.secondary.opacity(0.28))
            .frame(width: 44, height: 3)
            .frame(maxWidth: .infinity)
            .padding(.top, 2)
            .padding(.bottom, 14)
            .accessibilityHidden(true)
    }
}
