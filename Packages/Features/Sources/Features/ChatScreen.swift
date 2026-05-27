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
    /// Per-channel badge cache. Reset implicitly when the screen pushes a new
    /// instance — each NavigationLink push creates a fresh `@State` so old
    /// channel badges don't bleed into a different broadcaster's chat.
    @State private var badgeStore = ChatBadgeStore()

    /// Pre-cached global Twitch data (loaded once at app launch by RootView).
    /// We pass its global-badges slice into `badgeStore.load(...)` so the
    /// per-channel load skips the redundant /chat/badges/global fetch.
    @Environment(\.globalCatalog) private var globalCatalog

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
                        ChatRow(
                            message: line,
                            badgeEntries: badgeStore.entries(for: line.badges)
                        )
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
        // Kick off badge fetch in parallel — doesn't block chat from appearing.
        // Each ChatRow looks up its badges synchronously via badgeStore once the
        // fetch completes; until then rows just render without the icon block.
        //
        // Capture the catalog's current globalBadges snapshot before spawning the
        // Task — keeps the closure Sendable-friendly and avoids reading @Environment
        // from a non-main context. If the catalog hasn't loaded yet (or the env
        // value is nil — e.g. previews), the store falls back to fetching global
        // itself, so chat still works.
        let cachedGlobalBadges = globalCatalog?.globalBadges ?? [:]
        Task {
            await badgeStore.load(
                account: account,
                accountStore: accountStore,
                channelId: channelId,
                globalBadges: cachedGlobalBadges
            )
        }

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
