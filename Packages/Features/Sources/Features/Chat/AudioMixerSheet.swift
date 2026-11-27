#if os(iOS)
import SwiftUI
import Core
import TwitchKit
import Nuke
import NukeUI

/// Unified mixer sheet controlling the primary stage stream and up to 3 pinned
/// background audio streams: per-stream volume sliders (native slots), mute,
/// 1-tap Solo, Mute All, promote-to-video, demote-to-pinned, and quick-add
/// from open live chats.
struct AudioMixerSheet: View {
    let playback: PlaybackCenter

    @Environment(\.dismiss) private var dismiss
    @Environment(\.chatTabs) private var chatTabs
    @Environment(\.channelStatus) private var channelStatus
    @Environment(\.followsStore) private var followsStore
    @Environment(\.openChannel) private var openChannel

    private var canPinMore: Bool {
        PlayerSettings.isNativePlaybackEnabled
            && playback.pinnedAudio.count < PlaybackCenter.maxPinnedAudioSlots
    }

    private var addableLiveTabs: [(channel: ChannelDescriptor, stream: TwitchStream)] {
        guard let tabs = chatTabs?.tabs else { return [] }
        return tabs.compactMap { tab in
            guard let channel = tab.channels.first,
                  !playback.isPlayingOrPinned(channel.channelId),
                  let stream = ChannelStatusStore.liveStream(
                      for: channel.channelId,
                      status: channelStatus,
                      follows: followsStore
                  )
            else { return nil }
            return (channel, stream)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let primary = playback.primary {
                        VStack(alignment: .leading, spacing: 8) {
                            sectionHeader("Watching")
                            PrimaryMixerRow(
                                slot: primary,
                                isSoloed: playback.soloSlotID == primary.id,
                                canPin: canPinMore && !primary.controller.nativeFailed,
                                onToggleSolo: { playback.toggleSolo(slotID: primary.id) },
                                onPin: {
                                    withAnimation(.snappy(duration: 0.25)) {
                                        _ = playback.demotePrimaryToPinnedAudio()
                                    }
                                }
                            )
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader("Background Audio (\(playback.pinnedAudio.count)/\(PlaybackCenter.maxPinnedAudioSlots))")

                        if playback.pinnedAudio.isEmpty {
                            Text("No background streams pinned. Add a live channel below or from the channel switcher.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 6)
                        } else {
                            ForEach(playback.pinnedAudio) { slot in
                                PinnedMixerRow(
                                    slot: slot,
                                    isSoloed: playback.soloSlotID == slot.id,
                                    onToggleSolo: { playback.toggleSolo(slotID: slot.id) },
                                    onPromoteToVideo: {
                                        let channel = slot.channel
                                        playback.promotePinnedToPrimary(
                                            channelId: channel.channelId,
                                            audioOnly: false,
                                            quality: slot.lastQuality,
                                            syncGlobalDisplayPreferences: true
                                        )
                                        dismiss()
                                        openChannel?(channel, intent: .explicit)
                                    },
                                    onUnpin: {
                                        withAnimation(.snappy(duration: 0.25)) {
                                            if chatTabs?.visibleChannelId == slot.channel.channelId {
                                                UserDefaults.standard.set(false, forKey: StreamHeaderView.expandedKey)
                                            }
                                            playback.unpinBackgroundAudio(channelId: slot.channel.channelId)
                                        }
                                    }
                                )
                            }
                        }
                    }

                    addFromOpenChatsControl
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .navigationTitle("Audio Mixer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if playback.hasAnyPlayback {
                        Button(playback.isMutedAll ? "Unmute All" : "Mute All") {
                            playback.toggleMuteAll()
                        }
                        .font(.subheadline.weight(.semibold))
                        .tint(playback.isMutedAll ? .red : .accentColor)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var addFromOpenChatsControl: some View {
        if !PlayerSettings.isNativePlaybackEnabled {
            Text("Background audio requires native playback.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if !canPinMore {
            Text("Maximum \(PlaybackCenter.maxPinnedAudioSlots) background streams active. Unpin one to add another.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 2)
        } else if !addableLiveTabs.isEmpty {
            Menu {
                ForEach(addableLiveTabs, id: \.channel.channelId) { entry in
                    Button {
                        withAnimation(.snappy(duration: 0.25)) {
                            _ = playback.pinBackgroundAudio(
                                entry.channel,
                                title: entry.stream.title,
                                profileImageURL: entry.channel.profileImageURL
                                    ?? followsStore?.profileImageURLs[entry.channel.channelId],
                                stream: entry.stream
                            )
                        }
                    } label: {
                        Label(
                            entry.channel.channelDisplayName,
                            systemImage: "headphones"
                        )
                    }
                }
            } label: {
                Label("Add from Open Chats", systemImage: "plus.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
    }
}

// MARK: - Isolated per-slot mixer rows

private struct PrimaryMixerRow: View {
    let slot: PlaybackSlot
    let isSoloed: Bool
    let canPin: Bool
    let onToggleSolo: () -> Void
    let onPin: () -> Void

    private var controller: StreamPlayerController { slot.controller }
    private var supportsVolume: Bool { slot.engineKind == .native }
    private var isEffectivelyMuted: Bool { controller.isMuted || (supportsVolume && controller.volume == 0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                MixerAvatar(url: slot.profileImageURL, size: 34)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(slot.channel.channelDisplayName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(slot.audioOnly && !controller.nativeFailed ? "AUDIO" : "VIDEO")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Color.accentColor.opacity(0.18), in: Capsule())
                    }
                    if !slot.title.isEmpty {
                        Text(slot.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)

                Button(action: onToggleSolo) {
                    Text("Solo")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isSoloed ? .white : .primary)
                        .padding(.horizontal, 8)
                        .frame(height: 28)
                        .background(
                            isSoloed ? Color.accentColor : Color.primary.opacity(0.09),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isSoloed ? "Exit solo for \(slot.channel.channelDisplayName)" : "Solo \(slot.channel.channelDisplayName)")

                Button {
                    controller.toggleMute()
                } label: {
                    Image(systemName: isEffectivelyMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isEffectivelyMuted ? .red : .primary)
                        .frame(width: 30, height: 28)
                        .background(
                            isEffectivelyMuted ? Color.red.opacity(0.16) : Color.primary.opacity(0.09),
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isEffectivelyMuted ? "Unmute \(slot.channel.channelDisplayName)" : "Mute \(slot.channel.channelDisplayName)")

                if canPin {
                    Button(action: onPin) {
                        Label("Pin", systemImage: "headphones")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .frame(height: 28)
                            .background(Color.primary.opacity(0.09), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Pin \(slot.channel.channelDisplayName) to background audio")
                }
            }

            if supportsVolume {
                MixerVolumeSlider(controller: controller, channelName: slot.channel.channelDisplayName)
            } else {
                Text("Volume slider uses Native Video Player")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(11)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5)
        }
        .opacity(isEffectivelyMuted ? 0.72 : 1)
    }
}

private struct PinnedMixerRow: View {
    let slot: PlaybackSlot
    let isSoloed: Bool
    let onToggleSolo: () -> Void
    let onPromoteToVideo: () -> Void
    let onUnpin: () -> Void

    private var controller: StreamPlayerController { slot.controller }
    private var isEffectivelyMuted: Bool { controller.isMuted || controller.volume == 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                MixerAvatar(url: slot.profileImageURL, size: 34)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(controller.isPaused ? Color.secondary.opacity(0.5) : Color.red)
                            .frame(width: 6, height: 6)
                        Text(slot.channel.channelDisplayName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                    }
                    Text(slot.title.isEmpty ? "Background audio" : slot.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Button(action: onToggleSolo) {
                    Text("Solo")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isSoloed ? .white : .primary)
                        .padding(.horizontal, 8)
                        .frame(height: 28)
                        .background(
                            isSoloed ? Color.accentColor : Color.primary.opacity(0.09),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isSoloed ? "Exit solo for \(slot.channel.channelDisplayName)" : "Solo \(slot.channel.channelDisplayName)")

                Button {
                    controller.toggleMute()
                } label: {
                    Image(systemName: isEffectivelyMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isEffectivelyMuted ? .red : .primary)
                        .frame(width: 30, height: 28)
                        .background(
                            isEffectivelyMuted ? Color.red.opacity(0.16) : Color.primary.opacity(0.09),
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isEffectivelyMuted ? "Unmute \(slot.channel.channelDisplayName)" : "Mute \(slot.channel.channelDisplayName)")

                Button(action: onPromoteToVideo) {
                    Image(systemName: "video.fill")
                        .font(.caption.weight(.semibold))
                        .frame(width: 30, height: 28)
                        .background(Color.primary.opacity(0.09), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Watch \(slot.channel.channelDisplayName) video")

                Button(action: onUnpin) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .frame(width: 28, height: 28)
                        .background(Color.primary.opacity(0.09), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Unpin \(slot.channel.channelDisplayName)")
            }

            MixerVolumeSlider(controller: controller, channelName: slot.channel.channelDisplayName)
        }
        .padding(11)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5)
        }
        .opacity(isEffectivelyMuted ? 0.72 : 1)
    }
}

private struct MixerVolumeSlider: View {
    let controller: StreamPlayerController
    let channelName: String

    private var percentage: Int {
        Int((controller.isMuted ? 0 : controller.volume * 100).rounded())
    }

    var body: some View {
        HStack(spacing: 8) {
            Slider(
                value: Binding(
                    get: { Double(controller.isMuted ? 0 : controller.volume) },
                    set: { controller.setVolume(Float($0), programmatic: false) }
                ),
                in: 0...1
            )
            .tint(.accentColor)
            .accessibilityLabel("\(channelName) volume")
            .accessibilityValue("\(percentage) percent")

            Text("\(percentage)%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
    }
}

private struct MixerAvatar: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        LazyImage(request: ImageRequest.avatar(url: url, side: size)) { state in
            if let image = state.image {
                image.resizable().scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .foregroundStyle(.secondary.opacity(0.6))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}
#endif
