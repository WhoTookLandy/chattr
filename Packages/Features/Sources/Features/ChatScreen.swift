import SwiftUI
import Accounts
import Channels
import TwitchKit
import Core
import os

private let logger = AppLogger.make("Features.ChatScreen")

/// Renders live `channel.chat.message` events from EventSub as inline-emote rows.
///
/// Slice-2 interlude scope: Twitch native emote fragments render as CDN images.
/// Third-party emote providers (7TV/BTTV/FFZ) and animated WebP arrive in later slices.
public struct ChatScreen: View {
    private let account: Account
    private let accountStore: AccountStore
    private let channelId: String
    private let channelLoginName: String
    private let channelDisplayName: String

    @State private var session: ChannelSession?
    @State private var lines: [ChatMessage] = []
    @State private var errorMessage: String?

    public init(
        account: Account,
        accountStore: AccountStore,
        channelId: String,
        channelLoginName: String,
        channelDisplayName: String
    ) {
        self.account = account
        self.accountStore = accountStore
        self.channelId = channelId
        self.channelLoginName = channelLoginName
        self.channelDisplayName = channelDisplayName
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .padding()
                    }
                    ForEach(lines) { line in
                        ChatRow(message: line)
                            .id(line.messageId)
                    }
                }
                .padding(.horizontal)
            }
            .onChange(of: lines.count) { _, _ in
                if let last = lines.last {
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(last.messageId, anchor: .bottom)
                    }
                }
            }
        }
        .navigationTitle("#\(channelLoginName)")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .task { await startSession() }
    }

    @MainActor
    private func startSession() async {
        do {
            let client = accountStore.client(for: account)
            let session = ChannelSession(
                client: client,
                channelId: channelId,
                channelLoginName: channelLoginName,
                accountUserId: account.userId
            )
            try await session.start()
            self.session = session
            logger.info("ChatScreen started session for #\(channelLoginName)")

            // Bridge AsyncStream → @State updates on the main actor.
            Task { [session] in
                for await snapshot in session.lines {
                    await MainActor.run {
                        self.lines = snapshot
                    }
                }
            }
        } catch {
            errorMessage = "Couldn't open chat: \(error.localizedDescription)"
            logger.error("ChatScreen start failed: \(error.localizedDescription)")
        }
    }
}
