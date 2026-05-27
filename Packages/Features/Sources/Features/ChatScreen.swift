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

    /// Currently-scrolled message id. Used by the auto-scroll-to-bottom logic
    /// via `.scrollPosition(id:)`. Writing to this binding scrolls the view;
    /// the binding also updates as the user scrolls manually (iOS 17+ API).
    @State private var scrolledMessageId: String?

    /// Pre-cached global Twitch data (loaded once at app launch by RootView).
    /// We pass its global-badges slice into `badgeStore.load(...)` so the
    /// per-channel load skips the redundant /chat/badges/global fetch.
    @Environment(\.globalCatalog) private var globalCatalog

    /// App-wide session registry — `ChatScreen` *must* go through this to
    /// fetch a session rather than constructing one directly. The registry
    /// caches sessions by (userId, channelId), so re-entering a channel
    /// returns the existing already-subscribed session instead of trying to
    /// re-subscribe (Twitch rejects re-subscribe with "already subscribed").
    @Environment(\.channelSessionRegistry) private var channelSessionRegistry

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
            // `.scrollTargetLayout` tells the enclosing ScrollView to treat
            // this LazyVStack's children's `.id(...)` values as anchor points
            // for `.scrollPosition(id:)`. Without it, the position binding
            // has nothing to attach to.
            .scrollTargetLayout()
            .padding(.horizontal)
        }
        // Declarative replacement for `ScrollViewReader { proxy.scrollTo(...) }`
        // (iOS 17+). Writing to `scrolledMessageId` scrolls; the binding also
        // updates as the user scrolls manually so we could read it later for
        // "snap to bottom only when already at bottom" UX without changing
        // this auto-scroll-on-new-message behavior.
        .scrollPosition(id: $scrolledMessageId, anchor: .bottom)
        .onChange(of: lines.count) { _, _ in
            guard let last = lines.last else { return }
            withAnimation(.easeOut(duration: 0.1)) {
                scrolledMessageId = last.messageId
            }
        }
        .navigationTitle("#\(channelLoginName)")
        // `.toolbarTitleDisplayMode` is cross-platform (iOS 17 / macOS 14+)
        // unlike the older iOS-only `.navigationBarTitleDisplayMode`. No
        // `#if os(iOS)` guard needed for SPM macOS host compilation.
        .toolbarTitleDisplayMode(.inline)
        // Two structured tasks. Both are bound to this view's lifetime —
        // SwiftUI cancels them on tear-down (incl. when ChatTabsScreen swaps
        // the active channel via `.id(...)`).
        //
        // Splitting badge-load into its own .task means the session connect
        // and the badge fetch run in parallel, AND we don't leak an
        // unstructured Task per channel switch (the previous code spawned
        // `Task { await badgeStore.load(...) }` inside startSession, which
        // outlived the view).
        .task { await startSession() }
        .task {
            let cachedGlobalBadges = globalCatalog?.globalBadges ?? [:]
            await badgeStore.load(
                account: account,
                accountStore: accountStore,
                channelId: channelId,
                globalBadges: cachedGlobalBadges
            )
        }
    }

    @MainActor
    private func startSession() async {
        // Badge load runs in a sibling .task modifier (see body) — gives us
        // structured-cancellation parity with this session-start task.
        guard let registry = channelSessionRegistry else {
            errorMessage = "Couldn't open chat: missing session registry"
            logger.error("ChatScreen has no registry in environment — was RootView injected?")
            return
        }

        do {
            // Registry returns the cached session if one exists for this
            // (userId, channelId), or constructs + starts a new one. Either
            // way the session is already-running by the time we get it.
            let session = try await registry.session(
                account: account,
                channelId: channelId,
                channelLoginName: channelLoginName
            )
            self.session = session
            logger.info("ChatScreen got session for #\(channelLoginName) (cached or new)")

            // Bridge AsyncStream → @State updates on the main actor.
            //
            // Note: this loop runs *inside* the .task body (no nested Task).
            // That means when ChatScreen unmounts or its `.id(channelId)`
            // changes, the .task is cancelled and this for-await exits cleanly
            // — no leaked Task that keeps consuming session.lines forever.
            //
            // Caveat: AsyncStream is single-consumer. When we re-enter a
            // channel, we start a fresh iteration on the same stream — relying
            // on each yield carrying the full ring buffer, so the next yield
            // delivers the current state. If we ever see stale chat on
            // re-entry, the fix is a `currentSnapshot()` actor method that
            // primes `lines` before starting the for-await.
            for await snapshot in session.lines {
                self.lines = snapshot
            }
        } catch is CancellationError {
            // Expected on view tear-down / channel-tab switch. The .id(channelId)
            // modifier in ChatTabsScreen forces a fresh ChatScreen instance per
            // channel; the outgoing instance's `try await registry.session(...)`
            // gets cancelled in flight. Silently exit — don't show a red error.
            logger.info("ChatScreen session-start cancelled for #\(channelLoginName)")
        } catch {
            errorMessage = "Couldn't open chat: \(error.localizedDescription)"
            logger.error("ChatScreen failed to acquire session: \(error.localizedDescription)")
        }
    }
}
