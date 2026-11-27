#if os(iOS)
import SwiftUI
import Core
import NukeUI
import Nuke

/// Floating player shown while streams keep playing outside chat.
///
/// Renders independently:
/// - **Primary video tile** (`center.showsPrimaryVideoTile`): corner-snapped,
///   draggable, pinch-resizable PiP tile. Tap → back to chat; × / fling → `stopPrimary()`.
/// - **Unified audio dock** (`center.audioDockSlots`): full-width Liquid Glass
///   capsule above the tab/search bar covering primary audio-only and/or up to 3
///   pinned background audio streams. Swipe down or × → `stopAudioDockStreams()`.
///   Tap → back to chat (single primary audio-only) or opens `AudioMixerSheet`
///   (when pinned background audio is active).
struct MiniPlayerOverlay: View {
    let center: PlaybackCenter
    /// True while Home has auto-hidden the bottom tab bar on scroll down.
    var isTabBarHidden: Bool = false
    let onOpen: (ChannelDescriptor) -> Void

    @State private var videoDragOffset: CGSize = .zero
    @State private var dockDragOffset: CGSize = .zero
    @State private var alignment: Alignment = .bottomTrailing
    @AppStorage(MiniPlayerSize.storageKey) private var size: MiniPlayerSize = .medium
    @State private var pinchScale: CGFloat = 1
    @State private var showAudioMixer = false

    private static let area = "miniPlayerArea"

    private var showsVideoTile: Bool { center.showsPrimaryVideoTile }
    private var dockSlots: [PlaybackSlot] { center.audioDockSlots }
    private var showsAudioDock: Bool { !dockSlots.isEmpty }
    private var baseBottomPadding: CGFloat { isTabBarHidden ? 12 : 64 }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if showsVideoTile, let channel = center.channel {
                    videoTile(channel, maxWidth: geo.size.width - 24)
                        .simultaneousGesture(pinchGesture(maxWidth: geo.size.width - 24))
                        .offset(videoDragOffset)
                        .gesture(dragGesture(in: geo.size))
                        .padding(.horizontal, 12)
                        // Lift the video tile above the bottom audio dock whenever
                        // both are on screen simultaneously so they never overlap.
                        .padding(.bottom, showsAudioDock ? baseBottomPadding + 58 : baseBottomPadding)
                        .frame(width: geo.size.width, height: geo.size.height, alignment: alignment)
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                }

                if showsAudioDock {
                    audioDock(slots: dockSlots)
                        .frame(maxWidth: 520)
                        .offset(y: max(-14, dockDragOffset.height))
                        .gesture(audioDismissGesture)
                        .padding(.horizontal, 12)
                        .padding(.bottom, baseBottomPadding)
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.25), value: isTabBarHidden)
            .animation(.snappy(duration: 0.25), value: showsAudioDock)
            .animation(.snappy(duration: 0.25), value: showsVideoTile)
        }
        .coordinateSpace(.named(Self.area))
        .onAppear { wirePrimaryTap() }
        .onChange(of: center.channel?.channelId) { _, _ in wirePrimaryTap() }
        .sheet(isPresented: $showAudioMixer) {
            AudioMixerSheet(playback: center)
        }
    }

    private func wirePrimaryTap() {
        center.onPrimaryTap = { [weak center] in
            if let channel = center?.channel { onOpen(channel) }
        }
        center.onPrimarySwipeDown = nil
    }

    // MARK: - Video Tile

    private func tileWidth(maxWidth: CGFloat) -> CGFloat {
        let lower = MiniPlayerSize.small.width
        let upper = max(lower, min(maxWidth, MiniPlayerSize.large.width * 1.15))
        return min(max(size.width * pinchScale, lower), upper)
    }

    private func videoTile(_ channel: ChannelDescriptor, maxWidth: CGFloat) -> some View {
        let width = tileWidth(maxWidth: maxWidth)
        return ZStack(alignment: .topTrailing) {
            PlayerHost(center: center)
                .background(.black)
                .allowsHitTesting(false)
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { onOpen(channel) }
            closeButton(label: "Stop video playback") {
                withAnimation(.snappy) { center.stopPrimary() }
            }
            .padding(6)
        }
        .frame(width: width, height: width * 9 / 16)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(channel.channelDisplayName) mini player")
        .accessibilityAction(named: "Open chat") { onOpen(channel) }
    }

    // MARK: - Unified Audio Dock

    private func audioDock(slots: [PlaybackSlot]) -> some View {
        let isSingle = slots.count == 1
        let primaryOnly = isSingle && center.pinnedAudio.isEmpty && center.primary?.id == slots[0].id
        let anyPlaying = slots.contains { !$0.controller.isPaused }

        return HStack(spacing: 10) {
            if isSingle, let first = slots.first {
                LazyImage(request: ImageRequest.avatar(url: first.profileImageURL, side: 34)) { state in
                    if let image = state.image {
                        image.resizable().scaledToFill()
                    } else {
                        Image(systemName: "person.crop.circle.fill")
                            .resizable()
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 34, height: 34)
                .clipShape(Circle())
            } else {
                StackedPinnedAvatars(slots: slots, size: 30)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(dockTitle(slots: slots))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: "headphones")
                        .font(.caption2.weight(.semibold))
                    Text(dockSubtitle(slots: slots, anyPlaying: anyPlaying))
                        .font(.caption)
                        .lineLimit(1)
                }
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 6)

            Button {
                center.togglePlayPauseAudioDock()
            } label: {
                Image(systemName: anyPlaying ? "pause.fill" : "play.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(anyPlaying ? "Pause audio" : "Play audio")

            closeButton(label: "Stop audio playback") {
                withAnimation(.snappy) { center.stopAudioDockStreams() }
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
        .glassEffect(.regular.interactive(), in: Capsule())
        .contentShape(Capsule())
        .onTapGesture {
            if primaryOnly, let channel = slots.first?.channel {
                onOpen(channel)
            } else {
                showAudioMixer = true
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(dockAccessibilityLabel(slots: slots))
        .accessibilityAction(named: primaryOnly ? "Open chat" : "Open audio mixer") {
            if primaryOnly, let channel = slots.first?.channel {
                onOpen(channel)
            } else {
                showAudioMixer = true
            }
        }
        // Keep the primary audio-only engine attached when primary is in the dock.
        .background {
            if center.primary?.audioOnly == true, center.primary?.controller.nativeFailed != true {
                PlayerHost(center: center)
                    .frame(width: 2, height: 2)
                    .opacity(0.01)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    private func dockTitle(slots: [PlaybackSlot]) -> String {
        guard let first = slots.first else { return "" }
        if slots.count == 1 {
            return first.channel.channelDisplayName
        }
        return "\(first.channel.channelDisplayName) + \(slots.count - 1) more"
    }

    private func dockSubtitle(slots: [PlaybackSlot], anyPlaying: Bool) -> String {
        if !anyPlaying {
            return slots.count == 1 ? "Audio paused" : "\(slots.count) audio streams paused"
        }
        if slots.count == 1, let first = slots.first {
            let trimmed = first.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = center.pinnedAudio.contains(where: { $0.id == first.id }) ? "Background audio" : "Audio only"
            return trimmed.isEmpty ? prefix : "\(prefix) · \(trimmed)"
        }
        return "\(slots.count) audio streams · Tap for mixer"
    }

    private func dockAccessibilityLabel(slots: [PlaybackSlot]) -> String {
        if slots.count == 1, let first = slots.first {
            return "\(first.channel.channelDisplayName) audio player"
        }
        return "\(slots.count) background audio streams"
    }

    private func closeButton(label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(.black.opacity(0.55), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: - Gestures

    private var audioDismissGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.area))
            .onChanged { dockDragOffset = $0.translation }
            .onEnded { value in
                withAnimation(.snappy) {
                    if value.translation.height > 64 || value.predictedEndTranslation.height > 140 {
                        center.stopAudioDockStreams()
                    }
                    dockDragOffset = .zero
                }
            }
    }

    private func dragGesture(in area: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.area))
            .onChanged { videoDragOffset = $0.translation }
            .onEnded { value in
                withAnimation(.snappy) {
                    if alignment.vertical == .bottom, value.predictedEndTranslation.height > 160 {
                        center.stopPrimary()
                    } else {
                        let end = value.predictedEndLocation
                        alignment = Alignment(
                            horizontal: end.x < area.width / 2 ? .leading : .trailing,
                            vertical: end.y < area.height / 2 ? .top : .bottom
                        )
                    }
                    videoDragOffset = .zero
                }
            }
    }

    private func pinchGesture(maxWidth: CGFloat) -> some Gesture {
        MagnifyGesture()
            .onChanged { pinchScale = $0.magnification }
            .onEnded { value in
                let lower = MiniPlayerSize.small.width
                let upper = max(lower, min(maxWidth, MiniPlayerSize.large.width * 1.15))
                let target = min(max(size.width * value.magnification, lower), upper)
                withAnimation(.snappy) {
                    size = MiniPlayerSize.nearest(to: target)
                    pinchScale = 1
                }
            }
    }
}
#endif
