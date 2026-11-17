import SwiftUI
import DesignSystem
#if os(iOS)
import UIKit
#endif

/// Signed-out "just looking" mode: a channel's stream (Twitch's web player
/// needs no account) and its chat, read anonymously. No sending, badges or
/// emote images — a sign-in prompt sits where the compose bar would be.
struct GuestChannelView: View {
    let login: String
    let onSignIn: () -> Void

    @State private var chat: AnonymousChatReader
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

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
        .onAppear { chat.start() }
        .onDisappear { chat.stop() }
    }

    // MARK: - Player

    private var player: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            #if os(iOS)
            GuestPlayerView(login: login)
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

    // MARK: - Chat

    private var chatList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                switch chat.status {
                case .connecting where chat.messages.isEmpty:
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Joining #\(login)…")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 12)
                case .failed where chat.messages.isEmpty:
                    Text("Couldn't connect to chat.")
                        .foregroundStyle(.secondary)
                        .padding(.top, 12)
                default:
                    EmptyView()
                }
                ForEach(chat.messages) { message in
                    messageText(message)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        // Stick to the newest message, like a real chat.
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
    }

    private func messageText(_ message: AnonymousChatReader.Message) -> some View {
        let nameColor: Color = message.color.map { .twitchUsername(hex: $0, scheme: colorScheme) } ?? .primary
        let name = Text(message.author).fontWeight(.semibold).foregroundStyle(nameColor)
        let text = Text(message.text).foregroundStyle(message.isAction ? nameColor : .primary)
        return Text("\(name)\(message.isAction ? " " : ": ")\(text)")
            .font(.body)
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

    @MainActor
    final class Coordinator {
        let controller = StreamPlayerController()
        var engine: WebStreamEngine?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        let engine = WebStreamEngine(login: login, controller: context.coordinator.controller)
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
