#if os(iOS)
import SwiftUI
import Core
import Nuke
import NukeUI

/// Zero-layout-height Liquid Glass capsule floating in the top-trailing corner
/// of chat (Option 2 in Settings, and always used in landscape).
/// Renders nothing when `playback.pinnedAudio.isEmpty`.
struct PinnedAudioPillView: View {
    let playback: PlaybackCenter
    let onOpenMixer: () -> Void

    private var anyAudible: Bool {
        playback.pinnedAudio.contains { !$0.controller.isMuted && $0.controller.volume > 0 && !$0.controller.isPaused }
    }

    var body: some View {
        if !playback.pinnedAudio.isEmpty {
            Button(action: onOpenMixer) {
                HStack(spacing: 6) {
                    StackedPinnedAvatars(slots: playback.pinnedAudio, size: 20)

                    HStack(spacing: 3) {
                        Image(systemName: "headphones")
                            .font(.system(size: 11, weight: .semibold))
                        Text("\(playback.pinnedAudio.count)")
                            .font(.caption.weight(.bold).monospacedDigit())
                    }
                    .foregroundStyle(.primary)

                    Image(systemName: anyAudible ? "waveform" : "speaker.slash.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(anyAudible ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                        .symbolEffect(.variableColor.iterative.dimInactiveLayers, isActive: anyAudible)
                }
                .padding(.leading, 5)
                .padding(.trailing, 9)
                .frame(height: 30)
                .glassEffect(.regular.interactive(), in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(
                            anyAudible ? Color.accentColor.opacity(0.38) : Color.primary.opacity(0.14),
                            lineWidth: 0.5
                        )
                }
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Audio Mixer", systemImage: "slider.horizontal.3", action: onOpenMixer)
                Button(
                    playback.isMutedAll ? "Unmute All" : "Mute All",
                    systemImage: playback.isMutedAll ? "speaker.wave.2.fill" : "speaker.slash.fill"
                ) {
                    playback.toggleMuteAll()
                }
                Divider()
                Button("Stop Background Audio", systemImage: "xmark", role: .destructive) {
                    withAnimation(.snappy(duration: 0.2)) {
                        playback.stopAllPinnedAudio()
                    }
                }
            }
            .accessibilityLabel("\(playback.pinnedAudio.count) background audio \(playback.pinnedAudio.count == 1 ? "stream" : "streams")")
            .accessibilityHint("Opens audio mixer")
            .transition(.scale(scale: 0.9).combined(with: .opacity))
        }
    }
}

/// Accessible audio menu button on the inline video overlay: Audio Only,
/// Pin to Background Audio, and Audio Mixer (with a live count badge).
struct OverlayAudioMenuButton: View {
    let playback: PlaybackCenter
    let onAudioOnly: () -> Void
    let onPinBackground: () -> Void
    let onOpenMixer: () -> Void

    private var pinnedCount: Int { playback.pinnedAudio.count }
    private var canPin: Bool {
        PlayerSettings.isNativePlaybackEnabled
            && pinnedCount < PlaybackCenter.maxPinnedAudioSlots
            && !playback.controller.nativeFailed
    }

    var body: some View {
        Menu {
            Button("Audio Only", systemImage: "headphones", action: onAudioOnly)
            Button(
                canPin ? "Pin to Background Audio" : "Background Audio Full (\(pinnedCount)/\(PlaybackCenter.maxPinnedAudioSlots))",
                systemImage: "pin",
                action: onPinBackground
            )
            .disabled(!canPin)
            if pinnedCount > 0 {
                Divider()
                Button("Audio Mixer (\(pinnedCount))", systemImage: "slider.horizontal.3", action: onOpenMixer)
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "headphones")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.55), radius: 3)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
                if pinnedCount > 0 {
                    Text("\(pinnedCount)")
                        .font(.system(size: 9, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 15, minHeight: 15)
                        .background(Color.accentColor, in: Capsule())
                        .offset(x: -2, y: 2)
                }
            }
        }
        .accessibilityLabel(pinnedCount > 0 ? "Audio options, \(pinnedCount) background streams" : "Audio options")
    }
}

/// Self-contained floating pinned-audio pill overlay for `ChatScreen`.
///
/// Renders `PinnedAudioPillView` in the top-trailing corner of chat ONLY when:
/// - This page is the active pager tab (so neighbours never observe `pinnedAudio`), AND
/// - Either the page is on the landscape video stage (always uses the floating pill),
///   OR the user selected `.floatingPill` in Settings while inline video is showing.
///
/// Extracted so `ChatScreen.body` never observes `playback`, `chatTabs`, or Settings.
struct ChatFloatingPinnedAudioOverlay: View {
    let channelId: String
    let tabId: UUID?

    @Environment(\.playback) private var playback
    @Environment(\.chatTabs) private var chatTabs
    @Environment(\.followsStore) private var followsStore
    @Environment(\.channelStatus) private var channelStatus
    @Environment(\.landscapeStage) private var landscapeStage

    @AppStorage(StreamHeaderView.expandedKey) private var isExpanded = false
    @AppStorage(PlayerSettings.audioOnlyKey) private var audioOnly = false
    @AppStorage(PlaybackPreferences.backgroundAudioIndicatorKey) private var indicatorStyle: BackgroundAudioIndicatorStyle = .strip

    @State private var showAudioMixer = false

    private var isActive: Bool {
        guard let tabId else { return true }
        return chatTabs?.activeTabId == tabId
    }

    private var showsFloatingPill: Bool {
        guard isActive, let playback else { return false }
        if landscapeStage.isActive {
            return true
        }
        guard indicatorStyle == .floatingPill, isExpanded else { return false }
        let polled = ChannelStatusStore.liveStream(for: channelId, status: channelStatus, follows: followsStore)
        let isLive = (playback.stream(for: channelId, live: polled) ?? polled) != nil
        let condensed = CondensedStreamMode.resolve(
            channelId: channelId,
            isLive: isLive,
            isExpanded: isExpanded,
            audioOnly: audioOnly,
            playback: playback
        )
        return isLive && condensed == nil
    }

    var body: some View {
        Group {
            if showsFloatingPill, let playback {
                PinnedAudioPillView(playback: playback) {
                    showAudioMixer = true
                }
                .padding(.top, 8)
                .padding(.trailing, 10)
            }
        }
        .sheet(isPresented: $showAudioMixer) {
            if let playback {
                AudioMixerSheet(playback: playback)
            }
        }
    }
}

/// Compact overlapping circular avatars shared by `PinnedAudioPillView` and
/// the multi-stream `MiniPlayerOverlay` audio dock.
struct StackedPinnedAvatars: View {
    let slots: [PlaybackSlot]
    let size: CGFloat

    var body: some View {
        HStack(spacing: -size * 0.3) {
            ForEach(slots.prefix(3)) { slot in
                LazyImage(request: ImageRequest.avatar(url: slot.profileImageURL, side: size)) { state in
                    if let image = state.image {
                        image.resizable().scaledToFill()
                    } else {
                        Image(systemName: "person.crop.circle.fill")
                            .resizable()
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay {
                    Circle().strokeBorder(.background, lineWidth: 1.5)
                }
            }
        }
    }
}
#endif
