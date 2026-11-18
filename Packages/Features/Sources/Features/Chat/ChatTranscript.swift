import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import ChatModel
import Channels

/// The transcript region: empty/connecting state, the scrolling message
/// list, and the floating pills that ride on it. The row factory is injected
/// (`rowContent`) so this view stays ignorant of the row callbacks.
///
/// ## Why this is a separate view (observation scoping)
///
/// `@Observable` registers dependencies per view BODY that reads a
/// property. This body reads `chatModel.changeVersion`, which moves on every
/// coalesced model flush (up to ~once per frame during raids) — so whichever
/// body reads it re-evaluates at flush rate. When that body was
/// `ChatScreen.body`, each update re-ran the whole screen: compose-bar
/// closure construction, sheet/alert wiring, registry lookups. Isolating
/// every per-flush read (and the scroll-rate @State) here confines that
/// invalidation to this subtree.
///
/// To verify after touching this boundary: add `let _ = Self._printChanges()`
/// to ChatScreen.body in a debug build and open a busy channel — ChatScreen
/// should stay silent while messages flow; only ChatTranscript ticks.
struct ChatTranscript: View {
    /// Observed HERE, not in ChatScreen — see the doc comment above.
    let chatModel: ChatTranscriptModel
    let channelLoginName: String
    /// The pager tab this transcript belongs to; nil outside the pager.
    /// Off-screen pager neighbours stay mounted (see `PagerWindow`) and
    /// throttle their list updates — see `isVisible`.
    let tabId: UUID?
    /// Registry-owned per-account connection store; drives the
    /// "Reconnecting… / Live again" pill.
    let connectionStatus: ConnectionStatusStore?
    /// Row factory — closes over ChatScreen's callbacks (retry, reply,
    /// block, report). Runs from the cell provider, outside any body.
    let rowContent: (ChatLine) -> ChatRow
    /// What `rowContent` reads besides the line (badges, mod status). A
    /// change makes the list reconfigure rows already on screen — see
    /// `ChatRowInputs`.
    let rowInputs: ChatRowInputs
    /// Link handler for the rows (clip links open in-app). Must be a STABLE
    /// value (`ClipLinkRouter.openURLAction`): the list stores it once and
    /// installs it in every hosted cell.
    let openURL: OpenURLAction
    /// A message was tapped (opens the user card). Taps on links inside a
    /// message still go to the link.
    var onLineTapped: (ChatLine) -> Void = { _ in }
    /// Parent-owned: written by the report flow's row callbacks (built in
    /// ChatScreen), read by the confirmation pill overlay here.
    @Binding var showReportConfirmation: Bool

    /// Chat appearance preferences — this view consumes `edgeToEdge`.
    @Environment(\.chatAppearance) private var appearance

    /// Block list for the signed-in account. Pushed into
    /// `chatModel.blockedIds` reactively by the onChange/task in
    /// `chatScrollView`.
    @Environment(\.blockStore) private var blockStore

    @Environment(\.chatTabs) private var chatTabs

    /// False for a mounted pager neighbour that isn't the visible page. Read
    /// here (this body already re-runs per flush), so a swipe re-evaluates
    /// the transcripts rather than the chat pages around them.
    private var isVisible: Bool {
        guard let tabId else { return true }
        return chatTabs?.activeTabId == tabId
    }

    /// Currently-scrolled message id. Used by the legacy list's
    /// auto-scroll-to-bottom via `.scrollPosition(id:)`. Writing to this
    /// binding scrolls the view; it also updates as the user scrolls.
    @State private var scrolledMessageId: String?

    /// True when the scroll is at (or near) the bottom — i.e. the user is
    /// "tailing" live chat. Reported by the list from real scroll geometry.
    /// Gates auto-scroll on new messages and controls the jump-to-bottom
    /// pill's visibility (pill shows when false).
    @State private var isAtBottom = true

    /// Count of messages that arrived while the user was scrolled up
    /// (not tailing). Shown in the jump-to-bottom pill ("3 new
    /// messages") so the user knows how much they're missing. On UIKit the
    /// list controller writes it (it holds those messages back and knows
    /// exactly how many); the legacy path tallies `lines.count` deltas.
    @State private var unreadWhileScrolledUp = 0

    /// Incremented to ask the UIKit chat list to re-pin to the newest message
    /// — by the jump-to-bottom pill, and by each of the user's own sends.
    /// The collection view acts on each change.
    @State private var scrollToBottomToken = 0

    /// Current connection pill, derived from connection-state transitions via
    /// `ConnectionBanner.next`. Driven by the `.onChange` in `chatScrollView`.
    @State private var connectionBanner: ConnectionBanner = .hidden

    /// Cancels the in-flight "Live again" auto-dismiss when state changes again.
    @State private var liveAgainDismiss: Task<Void, Never>?

    var body: some View {
        Group {
            // `isEmpty` (not `lines.isEmpty`): the `lines` getter materializes
            // the full visible window once the ring wraps, and this body
            // re-runs per flush — while `isEmpty` is a stored flag that only
            // invalidates when it flips. See TranscriptStore.isEmpty's doc
            // comment.
            if chatModel.isEmpty {
                // Distinguish "attaching" (sessions not yet subscribed) from
                // "attached but quiet" (subscriptions live, but no messages
                // have arrived yet). Without explicit state UI a quiet channel
                // looks identical to a broken connection.
                EmptyOrConnectingState(
                    isAttached: chatModel.attachState == .attached,
                    channelLoginName: channelLoginName
                )
            } else {
                chatScrollView
            }
        }
        // Keep the model's block filter in sync with the active account's
        // BlockStore. Attached OUTSIDE the empty/non-empty branch on purpose:
        // `isEmpty` counts VISIBLE rows, so blocking every chatter on screen
        // flips to the empty state — and an observer living on the list
        // branch would be torn down with it, leaving a later unblock unable
        // to bring the hidden rows back. `blockStore` is @Observable, so
        // reading `.blockedIds` here re-fires this onChange whenever a
        // block/unblock mutates the set.
        .onChange(of: blockStore?.blockedIds ?? []) { _, ids in
            chatModel.blockedIds = ids
        }
        // Seed once on appear; .onChange above handles every subsequent
        // mutation. (A `.task(id: blockedIds)` re-hashed the whole Set on
        // every block/unblock and restarted the task — redundant.)
        .task {
            chatModel.blockedIds = blockStore?.blockedIds ?? []
        }
        #if canImport(UIKit)
        // Backgrounded (the stream may play on as audio or Picture in
        // Picture, with the chat socket up): stop feeding a transcript nobody
        // can see, and catch up on the way back — see
        // `ChatTranscriptModel.setLiveUpdatesPaused`. The same notifications
        // suspend the list (`ChatListTailing.isSuspended`); attached
        // out here so the empty state is covered too. Becoming active is a
        // second chance to resume, and a no-op when already resumed.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            chatModel.setLiveUpdatesPaused(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            chatModel.setLiveUpdatesPaused(false)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            chatModel.setLiveUpdatesPaused(false)
        }
        // The pause is stored on the model but driven from this view, and
        // the model outlives it: `ChatScreen` swaps the transcript for its
        // error view when a session fails to start. If that happened in the
        // background, nothing here heard the app return — without this, the
        // transcript that mounts on Retry would stay parked (primed, but
        // never live) until the next trip to the background.
        .onAppear {
            if UIApplication.shared.applicationState != .background {
                chatModel.setLiveUpdatesPaused(false)
            }
        }
        #endif
    }

    /// The list (either implementation) plus everything both share: the
    /// floating pills and the connection-banner reducer.
    @ViewBuilder
    private var chatScrollView: some View {
        messageList
            .modifier(TranscriptOverlays(
                isAtBottom: isAtBottom,
                unreadCount: unreadWhileScrolledUp,
                connectionBanner: connectionBanner,
                showReportConfirmation: showReportConfirmation,
                onJumpToLatest: jumpToLatest
            ))
            // Drive the connection pill from connection-state transitions.
            // `previous`/`current` are both `ConnectionState?` (the observed
            // expression is one optional); `previous` passes straight through
            // — the reducer treats nil as "no prior state → no Live-again
            // flash."
            .onChange(of: connectionStatus?.state) { previous, current in
                guard let current else { return }
                connectionBanner = ConnectionBanner.next(previous: previous, current: current)
                liveAgainDismiss?.cancel()
                if connectionBanner == .liveAgain {
                    liveAgainDismiss = Task { @MainActor in
                        try? await Task.sleep(for: .seconds(2))
                        guard !Task.isCancelled else { return }
                        if connectionBanner == .liveAgain { connectionBanner = .hidden }
                    }
                }
            }
            // Sending re-pins to the live edge so the user sees their own
            // message, like any chat app — while scrolled up it would
            // otherwise sit in the held-back backlog until they scrolled down.
            // Same path as the jump pill: on UIKit the token re-pins and
            // flushes the backlog (the new row included) in one apply.
            .onChange(of: chatModel.outgoingSendCount) { _, _ in
                jumpToLatest()
            }
    }

    /// Selects between the UICollectionView bridge (iOS) and the legacy
    /// SwiftUI ScrollView (macOS / non-UIKit). The UIKit path is the
    /// production list; the legacy path is the known-good fallback.
    @ViewBuilder
    private var messageList: some View {
        #if canImport(UIKit)
        // The ZStack is the safe-area-respecting anchor for the floating
        // pills while the list itself may bleed past the top edge:
        // `ignoresSafeArea` expands only the ChatListView, so with
        // Edge-to-Edge Chat on, messages scroll underneath the toolbar glass
        // but the connection/jump pills keep their positions inside the
        // visible safe region.
        ZStack {
            ChatListView(
                // Pass the publish VERSION (an Int), not the lines array — that's
                // what keeps this body off the full-array dependency. It only
                // triggers the update; the controller pulls every change since
                // its own last version (or, rarely, a snapshot) via the
                // closures, inside its own update pass.
                changeVersion: chatModel.changeVersion,
                changes: { chatModel.changes(since: $0) },
                snapshot: { chatModel.transcriptSnapshot() },
                rowContent: { line in rowContent(line) },
                rowInputs: rowInputs,
                openURL: openURL,
                isAtBottom: $isAtBottom,
                // The controller owns the unread tally: it is the one holding
                // messages back while the user reads scrollback, so it counts
                // exactly the appends it hasn't shown — across every replayed
                // batch, not just the latest publish — and zeroes the count
                // when it flushes them (re-pin or pill tap).
                unreadCount: $unreadWhileScrolledUp,
                // "N new" can't exceed what a jump to the live edge reveals.
                unreadLimit: chatModel.lineCap,
                scrollToBottomToken: scrollToBottomToken,
                extendsToTop: appearance.edgeToEdge,
                isVisible: isVisible,
                onLineTapped: onLineTapped
            )
            .ignoresSafeArea(edges: appearance.edgeToEdge ? .top : [])
        }
        #else
        legacyScrollView
        #endif
    }

    /// Jump the transcript to the newest message. On UIKit the collection view
    /// owns scrolling (token bump); on other platforms the legacy ScrollView
    /// scrolls via `scrolledMessageId`.
    private func jumpToLatest() {
        #if canImport(UIKit)
        scrollToBottomToken += 1
        #else
        if let last = chatModel.lines.last { scrolledMessageId = last.id }
        #endif
    }

    /// The non-UIKit scrolling chat content. Only mounted once we have at
    /// least one message — keeps the empty-state cleanly separated and avoids
    /// feeding an empty LazyVStack into `.scrollPosition` (which would no-op
    /// until rows arrive but log-spams about a missing target).
    ///
    /// **Scroll edge effect**: `.hard` style is the right pick here because
    /// our parent (`ChatPagerScreen`) renders a pinned glass tab strip
    /// directly above this scroll. Per the Liquid Glass guidance, "use
    /// `.hard` style for pinned accessory views" — that's exactly what the
    /// tab strip is. The hard variant dissolves scrolling content into the
    /// background just under the strip, giving a crisp visual shelf without
    /// an explicit Divider.
    @ViewBuilder
    private var legacyScrollView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(chatModel.lines) { line in
                    // Delegates to the injected `rowContent` factory so
                    // block/report callbacks, badge lookup, and all other
                    // row construction stay in one place (same as the UIKit
                    // collection-view cell provider above).
                    rowContent(line)
                        .environment(\.openURL, openURL)
                        .id(line.id)
                }
            }
            // `.scrollTargetLayout` tells the enclosing ScrollView to treat
            // this LazyVStack's children's `.id(...)` values as anchor points
            // for `.scrollPosition(id:)`. Without it, the position binding
            // has nothing to attach to.
            .scrollTargetLayout()
            .padding(.horizontal)
        }
        // Declarative replacement for `ScrollViewReader { proxy.scrollTo(...) }`.
        // Writing to `scrolledMessageId` scrolls; the binding also updates as
        // the user scrolls manually.
        .scrollPosition(id: $scrolledMessageId, anchor: .bottom)
        // Start at the bottom (most recent message) on fresh channel join.
        //
        // `.defaultScrollAnchor(.bottom)` alone doesn't reliably win
        // against `.scrollPosition(id:)` — the combination is finicky and
        // the scroll often starts at the TOP, which then reads as
        // "not at bottom" and pops the jump-to-latest pill immediately.
        //
        // Instead we drive the initial scroll explicitly: on first appear
        // (this view only mounts once lines are non-empty, so the backfill
        // is already present), write the last message's id to
        // `scrolledMessageId`. With `anchor: .bottom` that pins the newest
        // message to the viewport bottom. `isAtBottom` is seeded true so
        // the pill never flashes during the initial settle.
        .onAppear {
            scrolledMessageId = chatModel.lines.last?.id
            isAtBottom = true
        }
        // Scroll-edge dissolution under the pinned tab strip — see the doc
        // comment above. `.top` because that's the edge meeting the chrome.
        .scrollEdgeEffectStyle(.hard, for: .top)
        // Pull-to-dismiss-keyboard: dragging the chat content downward
        // dismisses the keyboard alongside the gesture. Matches Messages /
        // most chat apps.
        .scrollDismissesKeyboard(.interactively)
        // Track whether we're at (near) the bottom using REAL scroll
        // geometry. More robust than comparing scrolledMessageId to
        // lines.last — that breaks when the last message is taller than
        // the viewport. The transform returns a Bool; `action` fires only
        // when the Bool flips, so this isn't a per-frame cost during a
        // tailing scroll.
        //
        // "Near the bottom" within 44pt absorbs the small offset jitter
        // during rapid appends and means the pill doesn't flicker on at
        // the exact bottom edge.
        .onScrollGeometryChange(for: Bool.self) { geo in
            let distanceFromBottom = geo.contentSize.height
                - geo.contentOffset.y
                - geo.containerSize.height
                + geo.contentInsets.bottom
            return distanceFromBottom <= 44
        } action: { _, atBottom in
            isAtBottom = atBottom
        }
        // "tail -f" semantics, gated on the geometry-derived `isAtBottom`:
        //   - At bottom → auto-snap to the new last message + reset unread.
        //   - Scrolled up → don't snap; tally the new message into the
        //     unread count so the pill can show "N new."
        //
        // No animation on the snap — under burst traffic (50-200 msg/sec
        // during raids) queued animations stutter; instant snap is more
        // legible and at low throughput the missing animation is invisible.
        .onChange(of: chatModel.lines.count) { oldCount, newCount in
            if isAtBottom {
                if let last = chatModel.lines.last {
                    scrolledMessageId = last.id
                }
                unreadWhileScrolledUp = 0
            } else if newCount > oldCount {
                unreadWhileScrolledUp += (newCount - oldCount)
            }
        }
        // Returning to the bottom (manual scroll down, or via the pill)
        // clears the unread tally.
        .onChange(of: isAtBottom) { _, atBottom in
            if atBottom { unreadWhileScrolledUp = 0 }
        }
    }
}
