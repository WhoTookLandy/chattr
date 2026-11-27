#if os(iOS)
import SwiftUI
import Core
import DesignSystem
import Nuke
import NukeUI

/// Slim horizontal bar beneath inline video showing pinned background audio
/// streams (Option 1 — default in portrait). Renders 0pt when nothing is pinned.
///
/// Self-contained observer of `playback.pinnedAudio` so pinning/unpinning
/// never invalidates `ChatScreen` or `ChatListView`.
struct PinnedAudioStripView: View {
    let playback: PlaybackCenter
    let onOpenMixer: () -> Void
    let onPromoteToVideo: (PlaybackSlot) -> Void
    let onOpenChat: (ChannelDescriptor) -> Void

    var body: some View {
        if !playback.pinnedAudio.isEmpty {
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(playback.pinnedAudio) { slot in
                            PinnedAudioChip(
                                slot: slot,
                                isSoloed: playback.soloSlotID == slot.id,
                                onToggleSolo: { playback.toggleSolo(slotID: slot.id) },
                                onPromoteToVideo: { onPromoteToVideo(slot) },
                                onOpenChat: { onOpenChat(slot.channel) },
                                onUnpin: {
                                    withAnimation(.snappy(duration: 0.2)) {
                                        playback.unpinBackgroundAudio(channelId: slot.channel.channelId)
                                    }
                                }
                            )
                        }
                    }
                    .padding(.vertical, 5)
                }

                Button(action: onOpenMixer) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 28, height: 28)
                        .background(Color.primary.opacity(0.09), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open audio mixer")
            }
            .padding(.horizontal, 10)
            .background(Color.chatSurface)
            .overlay(alignment: .bottom) { Divider() }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}

private struct PinnedAudioChip: View {
    let slot: PlaybackSlot
    let isSoloed: Bool
    let onToggleSolo: () -> Void
    let onPromoteToVideo: () -> Void
    let onOpenChat: () -> Void
    let onUnpin: () -> Void

    private var controller: StreamPlayerController { slot.controller }
    private var isEffectivelyMuted: Bool { controller.isMuted || controller.volume == 0 || controller.isPaused }

    var body: some View {
        HStack(spacing: 5) {
            Button {
                controller.toggleMute()
            } label: {
                HStack(spacing: 5) {
                    LazyImage(request: ImageRequest.avatar(url: slot.profileImageURL, side: 20)) { state in
                        if let image = state.image {
                            image.resizable().scaledToFill()
                        } else {
                            Image(systemName: "person.crop.circle.fill")
                                .resizable()
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 20, height: 20)
                    .clipShape(Circle())

                    Text(slot.channel.channelDisplayName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isEffectivelyMuted ? .secondary : .primary)
                        .lineLimit(1)

                    Image(systemName: isEffectivelyMuted ? "speaker.slash.fill" : "waveform")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isEffectivelyMuted ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
                        .symbolEffect(.variableColor.iterative.dimInactiveLayers, isActive: !isEffectivelyMuted)
                }
                .padding(.leading, 3)
                .padding(.trailing, 2)
                .frame(height: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(slot.channel.channelDisplayName) background audio, \(isEffectivelyMuted ? "muted" : "playing")")
            .accessibilityHint("Tap to mute or unmute")

            Button(action: onUnpin) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(Color.primary.opacity(0.08), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 3)
            .accessibilityLabel("Unpin \(slot.channel.channelDisplayName)")
        }
        .background(
            isEffectivelyMuted ? Color.primary.opacity(0.07) : Color.accentColor.opacity(0.18),
            in: Capsule()
        )
        .overlay {
            Capsule()
                .strokeBorder(
                    isEffectivelyMuted ? Color.primary.opacity(0.12) : Color.accentColor.opacity(0.38),
                    lineWidth: 0.5
                )
        }
        .contextMenu {
            Button(
                controller.isMuted ? "Unmute" : "Mute",
                systemImage: controller.isMuted ? "speaker.wave.2.fill" : "speaker.slash.fill"
            ) {
                controller.toggleMute()
            }
            Button(
                isSoloed ? "Exit Solo" : "Solo",
                systemImage: "headphones"
            ) {
                onToggleSolo()
            }
            Button("Watch Video", systemImage: "video.fill", action: onPromoteToVideo)
            Button("Open Chat", systemImage: "bubble.left.and.bubble.right", action: onOpenChat)
            Divider()
            Button("Unpin Audio", systemImage: "xmark", role: .destructive, action: onUnpin)
        }
    }
}
#endif
