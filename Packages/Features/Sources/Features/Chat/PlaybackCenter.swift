import SwiftUI
import Core
#if os(iOS)
import UIKit
import WebKit
import NukeUI
import Nuke
#endif

#if os(iOS)

// MARK: - Engines

/// One live player instance — web (`TwitchWebPlayer`) or native
/// (`NativePlayer`). Owned by `PlaybackCenter`, never by a view, so the
/// stream keeps playing while its surface moves between the chat header and
/// the mini player.
@MainActor
protocol StreamEngine: AnyObject {
    var view: UIView { get }
    func teardown()
}

@MainActor
final class WebStreamEngine: StreamEngine {
    let view: UIView
    private let webView: WKWebView
    private let coordinator: TwitchWebPlayer.Coordinator

    init(login: String, controller: StreamPlayerController) {
        coordinator = TwitchWebPlayer.Coordinator(controller: controller)
        webView = TwitchWebPlayer.makeWebView(login: login, muted: controller.startsMuted, coordinator: coordinator)
        view = webView
        controller.webView = webView
    }

    func teardown() {
        coordinator.controller.webView = nil
        TwitchWebPlayer.teardown(webView)
    }
}

@MainActor
final class NativeStreamEngine: StreamEngine {
    let view: UIView
    private let playerView = NativePlayer.PlayerLayerView()
    private let coordinator: NativePlayer.Coordinator

    init(login: String, audioOnly: Bool, quality: PlayerQuality, controller: StreamPlayerController) {
        coordinator = NativePlayer.Coordinator(controller: controller)
        view = playerView
        playerView.backgroundColor = .clear
        playerView.playerLayer.videoGravity = .resizeAspect

        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(NativePlayer.Coordinator.tapped))
        let swipe = UISwipeGestureRecognizer(target: coordinator, action: #selector(NativePlayer.Coordinator.swipedDown))
        swipe.direction = .down
        tap.require(toFail: swipe)
        playerView.addGestureRecognizer(swipe)
        playerView.addGestureRecognizer(tap)

        controller.hostView = playerView
        coordinator.load(login: login, audioOnly: audioOnly, quality: quality, into: playerView)
    }

    func teardown() {
        coordinator.teardown()
        playerView.playerLayer.player = nil
        playerView.removeFromSuperview()
    }
}

// MARK: - Playback center

/// The app's single stream player. The chat header asks it to play the
/// visible channel; when the chat is closed it keeps playing and the
/// `MiniPlayerOverlay` shows it until the user returns or dismisses it.
///
/// The engine's view is shown by whichever `PlayerHost` claimed it most
/// recently (`hostStack`): the chat header while the chat is on screen, the
/// mini player otherwise.
@MainActor
@Observable
final class PlaybackCenter {
    /// What's playing — nil when nothing is.
    private(set) var channel: ChannelDescriptor?
    /// Snapshot for the mini player (the chat header's stores aren't
    /// around once the chat is gone).
    private(set) var title: String = ""
    private(set) var profileImageURL: URL?
    private(set) var audioOnly = false

    /// The host currently showing the video (last to claim).
    private(set) var activeHostID: UUID?
    @ObservationIgnored private var hostStack: [UUID] = []

    let controller = StreamPlayerController()
    @ObservationIgnored private(set) var engine: StreamEngine?
    @ObservationIgnored private var engineKey: String?

    @ObservationIgnored private var lastQuality: PlayerQuality = .auto

    /// Set when a chat opens under "Autoplay on Wi-Fi": the next new
    /// stream starts muted. Consumed by the next engine build.
    @ObservationIgnored var startNextStreamMuted = false
    /// Leaving the app → PiP or pause (see `PlaybackLifecycleObserver`).
    @ObservationIgnored private var lifecycle: PlaybackLifecycleObserver?

    var isPlaying: Bool { channel != nil }

    init() {
        controller.onNativeFailure = { [weak self] in
            guard let self else { return }
            self.fallBackToWeb(quality: self.lastQuality)
        }
        lifecycle = PlaybackLifecycleObserver(center: self)
    }

    /// Play `channel` (or keep playing it if it already is). Rebuilds the
    /// engine only when the channel or engine-shaping settings change.
    func play(
        _ channel: ChannelDescriptor,
        title: String,
        profileImageURL: URL?,
        native: Bool,
        audioOnly: Bool,
        quality: PlayerQuality
    ) {
        // Guarded: the header calls `play` for the already-playing stream
        // whenever its playback key changes, and an unconditional write
        // re-notifies every reader (the mini player) with identical values.
        if self.title != title { self.title = title }
        if self.profileImageURL != profileImageURL { self.profileImageURL = profileImageURL }
        // The user just asked to listen: audio-only surfaces have no mute
        // control, so a muted video (Wi-Fi autoplay) must not stay muted.
        let entersAudioOnly = audioOnly && !self.audioOnly
        if self.audioOnly != audioOnly { self.audioOnly = audioOnly }
        lastQuality = quality

        // A native failure for this channel sticks — fall back to web.
        let sameChannel = self.channel?.channelId == channel.channelId
        let useNative = native && !(sameChannel && controller.nativeFailed)
        let key = "\(channel.channelLoginName)|\(useNative)|\(useNative && audioOnly)"
        guard key != engineKey else {
            controller.applyQuality(quality)
            return
        }

        engine?.teardown()
        if !sameChannel { controller.nativeFailed = false }
        // A rebuild of the same stream (engine fallback) keeps its mute
        // state — `isMuted` carries the requested mute even if the old
        // engine never got as far as an AVPlayer (see `reset()`). Switching
        // to audio-only unmutes. A new stream starts muted only for autoplay.
        if sameChannel {
            controller.startsMuted = controller.isMuted && !entersAudioOnly
        } else {
            controller.startsMuted = startNextStreamMuted
        }
        startNextStreamMuted = false
        controller.reset()
        self.channel = channel
        engineKey = key
        engine = useNative
            ? NativeStreamEngine(login: channel.channelLoginName, audioOnly: audioOnly, quality: quality, controller: controller)
            : WebStreamEngine(login: channel.channelLoginName, controller: controller)
        // Re-render hosts so the new engine view gets attached.
        activeHostID = hostStack.last
        hostRevision += 1
    }

    /// Native engine gave up — rebuild the same channel on the web engine.
    func fallBackToWeb(quality: PlayerQuality) {
        guard let channel else { return }
        controller.nativeFailed = true
        play(channel, title: title, profileImageURL: profileImageURL,
             native: false, audioOnly: audioOnly, quality: quality)
    }

    func stop() {
        engine?.teardown()
        engine = nil
        engineKey = nil
        channel = nil
        controller.startsMuted = false
        controller.holdsForBackground = false
        controller.reset()
        controller.nativeFailed = false
        hostRevision += 1
    }

    func isPlaying(_ channelId: String) -> Bool {
        channel?.channelId == channelId
    }

    // MARK: Hosts

    /// Bumped when the engine changes so hosts re-attach.
    private(set) var hostRevision = 0

    func claim(_ hostID: UUID) {
        hostStack.removeAll { $0 == hostID }
        hostStack.append(hostID)
        if activeHostID != hostID { activeHostID = hostID }
    }

    func release(_ hostID: UUID) {
        hostStack.removeAll { $0 == hostID }
        if activeHostID == hostID { activeHostID = hostStack.last }
    }
}

private struct PlaybackCenterKey: EnvironmentKey {
    static let defaultValue: PlaybackCenter? = nil
}

extension EnvironmentValues {
    var playback: PlaybackCenter? {
        get { self[PlaybackCenterKey.self] }
        set { self[PlaybackCenterKey.self] = newValue }
    }
}

// MARK: - Host

/// A slot the engine's video can be shown in. Several can exist at once
/// (the chat header and the mini player during a pop); only the active one
/// (`PlaybackCenter.activeHostID`) holds the view.
struct PlayerHost: View {
    let center: PlaybackCenter
    @State private var id = UUID()

    var body: some View {
        PlayerHostRepresentable(
            center: center,
            isActive: center.activeHostID == id,
            revision: center.hostRevision
        )
        .onAppear { center.claim(id) }
        .onDisappear { center.release(id) }
    }
}

private struct PlayerHostRepresentable: UIViewRepresentable {
    let center: PlaybackCenter
    let isActive: Bool
    let revision: Int

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .clear
        container.clipsToBounds = true
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        guard isActive, let engineView = center.engine?.view else { return }
        if engineView.superview !== container {
            engineView.removeFromSuperview()
            engineView.frame = container.bounds
            engineView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(engineView)
        }
    }
}

// MARK: - Mini player

/// The video tile's resting widths (16:9). Pinching snaps to the nearest.
enum MiniPlayerSize: String, CaseIterable {
    case small, medium, large

    static let storageKey = "chattr.miniPlayer.size"

    var width: CGFloat {
        switch self {
        case .small: 160
        case .medium: 208
        case .large: 288
        }
    }

    /// The size whose width is closest to `width`.
    static func nearest(to width: CGFloat) -> MiniPlayerSize {
        allCases.min { abs($0.width - width) < abs($1.width - width) } ?? .medium
    }
}

/// Floating player shown while a stream keeps playing outside its chat.
/// Tap → back to the chat; × → stop. Drag it anywhere and it settles in the
/// nearest corner; fling it down from a bottom corner to stop; pinch the
/// video to resize. Audio-only streams get a compact pill instead.
struct MiniPlayerOverlay: View {
    let center: PlaybackCenter
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
                // Clear of the tab bar.
                .padding(.bottom, 64)
                .frame(width: geo.size.width, height: geo.size.height, alignment: alignment)
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
