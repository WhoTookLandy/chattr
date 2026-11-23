import SwiftUI
import ChatModel
import DesignSystem
#if os(iOS)
import UIKit
#endif

/// Signed-out "just looking" mode: a channel's stream (Twitch's web player
/// needs no account) and its chat, read anonymously, with Twitch and
/// third-party emotes. No sending and no badges — a sign-in prompt sits
/// where the compose bar would be.
struct GuestChannelView: View {
    let login: String
    let onSignIn: () -> Void

    @State private var chat: AnonymousChatReader
    #if os(iOS)
    @State private var playerController = StreamPlayerController()
    @State private var showPlayerControls = false
    @State private var controlsHideTask: Task<Void, Never>?
    @State private var pausedForBackground = false
    #endif
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    init(login: String, onSignIn: @escaping () -> Void) {
        self.login = login
        self.onSignIn = onSignIn
        _chat = State(initialValue: AnonymousChatReader(channel: login))
    }

    var body: some View {
        VStack(spacing: 0) {
            player
            chatList
            signInBar
        }
        .background(Color.chatSurface.ignoresSafeArea())
        .onAppear {
            chat.start()
            #if os(iOS)
            playerController.onTap = { togglePlayerControls() }
            #endif
        }
        .onDisappear {
            chat.stop()
            #if os(iOS)
            controlsHideTask?.cancel()
            controlsHideTask = nil
            #endif
        }
        #if os(iOS)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                if !playerController.isPaused {
                    pausedForBackground = true
                    playerController.pause()
                }
            case .active:
                if pausedForBackground {
                    pausedForBackground = false
                    playerController.resume()
                }
            default:
                break
            }
        }
        #endif
    }

    // MARK: - Player

    private var player: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            #if os(iOS)
            GuestPlayerView(login: login, controller: playerController)
            if showPlayerControls {
                HStack(spacing: 24) {
                    Button {
                        playerController.togglePlay()
                        scheduleControlsAutoHide()
                    } label: {
                        Image(systemName: playerController.isPaused ? "play.fill" : "pause.fill")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 48, height: 48)
                            .background(.black.opacity(0.55), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(playerController.isPaused ? "Play" : "Pause")

                    Button {
                        playerController.toggleMute()
                        scheduleControlsAutoHide()
                    } label: {
                        Image(systemName: playerController.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(.black.opacity(0.55), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(playerController.isMuted ? "Unmute" : "Mute")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            }
            #endif
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.55), radius: 3)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                Spacer()
                Text(login)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .padding(.trailing, 10)
            }
            .padding(.top, 2)
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .background { Color.black.ignoresSafeArea(edges: .top) }
    }

    #if os(iOS)
    private func togglePlayerControls() {
        withAnimation(.easeInOut(duration: 0.2)) {
            showPlayerControls.toggle()
        }
        if showPlayerControls {
            scheduleControlsAutoHide()
        } else {
            controlsHideTask?.cancel()
            controlsHideTask = nil
        }
    }

    private func scheduleControlsAutoHide() {
        controlsHideTask?.cancel()
        controlsHideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                showPlayerControls = false
            }
        }
    }
    #endif

    // MARK: - Chat

    private var chatList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                switch chat.status {
                case .connecting where chat.lines.isEmpty:
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Joining #\(login)…")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 12)
                default:
                    EmptyView()
                }
                ForEach(chat.lines) { line in
                    // The same row view as signed-in chat: inline emotes,
                    // name colors, text-size settings. No badges here. The
                    // line was built once, when the message arrived.
                    ChatRow(line: line, badgeEntries: [])
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        // Stick to the newest message, like a real chat.
        .defaultScrollAnchor(.bottom)
        // Connection dropped: say so even when old messages are showing
        // (the reader retries on its own with backoff).
        .overlay(alignment: .top) {
            if chat.status == .reconnecting {
                Label("Reconnecting to chat…", systemImage: "wifi.exclamationmark")
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 8)
                    .transition(.opacity)
            }
        }
        .animation(.snappy, value: chat.status)
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: - Sign-in bar

    private var signInBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Read-only")
                    .font(.subheadline.weight(.semibold))
                Text("Sign in to chat, follow and get mentions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                dismiss()
                onSignIn()
            } label: {
                Text("Sign in")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(height: 36)
                    .background(Color.twitchPurple, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}

#if os(iOS)
/// The Twitch web player for a guest — same engine the signed-in header
/// uses, owned by this view (no PlaybackCenter / mini player for guests).
private struct GuestPlayerView: UIViewRepresentable {
    let login: String
    let controller: StreamPlayerController

    @MainActor
    final class Coordinator {
        var engine: WebStreamEngine?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        let engine = WebStreamEngine(login: login, controller: controller)
        context.coordinator.engine = engine
        engine.view.frame = container.bounds
        engine.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(engine.view)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.engine?.teardown()
        coordinator.engine = nil
    }
}
#endif

extension Color {
    /// Twitch brand purple (#9146FF).
    static let twitchPurple = Color(red: 0x91 / 255, green: 0x46 / 255, blue: 0xFF / 255)
}
