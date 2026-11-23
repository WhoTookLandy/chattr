#if os(iOS)
import SwiftUI
import Core
import NukeUI
import Nuke

/// Floating player shown while a stream keeps playing outside its chat.
/// Tap → back to the chat; × → stop. Drag it anywhere and it settles in the
/// nearest corner; fling it down from a bottom corner to stop; pinch the
/// video to resize. Audio-only streams get a compact pill instead.
struct MiniPlayerOverlay: View {
    let center: PlaybackCenter
    /// True while Home has auto-hidden the bottom tab bar on scroll down.
    var isTabBarHidden: Bool = false
    let onOpen: (ChannelDescriptor) -> Void

    @State private var dragOffset: CGSize = .zero
    @State private var alignment: Alignment = .bottomTrailing
    @AppStorage(MiniPlayerSize.storageKey) private var size: MiniPlayerSize = .medium
    /// Live pinch factor, folded into `size` when the pinch ends.
    @State private var pinchScale: CGFloat = 1

    private static let area = "miniPlayerArea"

    var body: some View {
        if let channel = center.channel {
            GeometryReader { geo in
                Group {
                    // Native failed → web engine, which can't play hidden:
                    // show the video tile instead of the audio pill.
                    if center.audioOnly, !center.controller.nativeFailed {
                        audioPill(channel)
                    } else {
                        videoTile(channel, maxWidth: geo.size.width - 24)
                            .simultaneousGesture(pinchGesture(maxWidth: geo.size.width - 24))
                    }
                }
                .offset(dragOffset)
                .gesture(dragGesture(in: geo.size))
                .padding(.horizontal, 12)
                // Clear of the tab bar when visible; settle closer to the
                // bottom safe area when Home has auto-hidden it on scroll.
                .padding(.bottom, isTabBarHidden ? 12 : 64)
                .frame(width: geo.size.width, height: geo.size.height, alignment: alignment)
                .animation(.snappy(duration: 0.25), value: isTabBarHidden)
            }
            .coordinateSpace(.named(Self.area))
            .transition(.scale(scale: 0.8).combined(with: .opacity))
            .onAppear {
                center.controller.onTap = { onOpen(channel) }
                center.controller.onSwipeDown = nil
            }
        }
    }

    /// Current tile width: the resting size times any pinch in progress,
    /// kept between the smallest size and the screen.
    private func tileWidth(maxWidth: CGFloat) -> CGFloat {
        let lower = MiniPlayerSize.small.width
        let upper = max(lower, min(maxWidth, MiniPlayerSize.large.width * 1.15))
        return min(max(size.width * pinchScale, lower), upper)
    }

    private func videoTile(_ channel: ChannelDescriptor, maxWidth: CGFloat) -> some View {
        let width = tileWidth(maxWidth: maxWidth)
        return ZStack(alignment: .topTrailing) {
            // The engine view never sees touches here: the web player's
            // scroll view and the native view's own swipe/tap recognizers
            // were swallowing the drag (TestFlight: "why can't I drag it?").
            // Taps and drags are handled in SwiftUI instead.
            PlayerHost(center: center)
                .background(.black)
                .allowsHitTesting(false)
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { onOpen(channel) }
            closeButton
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

    private func audioPill(_ channel: ChannelDescriptor) -> some View {
        HStack(spacing: 10) {
            LazyImage(request: ImageRequest.avatar(url: center.profileImageURL, side: 32)) { state in
                if let image = state.image {
                    image.resizable().scaledToFill()
                } else {
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 32, height: 32)
            .clipShape(Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(channel.channelDisplayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Label("Audio only", systemImage: "headphones")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                center.controller.togglePlay()
            } label: {
                Image(systemName: center.controller.isPaused ? "play.fill" : "pause.fill")
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(center.controller.isPaused ? "Play" : "Pause")
            closeButton
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .glassEffect(.regular.interactive(), in: Capsule())
        .contentShape(Capsule())
        .onTapGesture { onOpen(channel) }
        // The engine must stay attached somewhere to keep playing smoothly.
        .background {
            PlayerHost(center: center)
                .frame(width: 2, height: 2)
                .opacity(0.01)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var closeButton: some View {
        Button {
            withAnimation(.snappy) { center.stop() }
        } label: {
            Image(systemName: "xmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(.black.opacity(0.55), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop playback")
    }

    /// Drag anywhere; on release the tile settles in the corner nearest to
    /// where the finger (plus its momentum) ends up — like system PiP.
    /// A hard fling down from a bottom corner stops playback.
    private func dragGesture(in area: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.area))
            .onChanged { dragOffset = $0.translation }
            .onEnded { value in
                withAnimation(.snappy) {
                    if alignment.vertical == .bottom, value.predictedEndTranslation.height > 160 {
                        center.stop()
                    } else {
                        let end = value.predictedEndLocation
                        alignment = Alignment(
                            horizontal: end.x < area.width / 2 ? .leading : .trailing,
                            vertical: end.y < area.height / 2 ? .top : .bottom
                        )
                    }
                    dragOffset = .zero
                }
            }
    }

    /// Pinch the video to resize; it snaps to the nearest of three sizes,
    /// remembered across launches.
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
