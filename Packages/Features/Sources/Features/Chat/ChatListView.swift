#if canImport(UIKit)
import SwiftUI
import UIKit
import ChatModel

/// SwiftUI bridge to a recycling `UICollectionView` chat transcript. Hosts the
/// existing `ChatRow` verbatim via `UIHostingConfiguration`, so all of ChatRow's
/// SwiftUI behavior (context menu, highlighted backplate, bubble rows) is
/// preserved while the collection view provides cell recycling and native
/// scroll anchoring.
///
/// Non-inverted (natural orientation) — see the design spec for why the
/// inverted-transform approach was rejected (it degrades the per-row context
/// menu previews).
struct ChatListView: UIViewControllerRepresentable {
    /// `ChatTranscriptModel.changeVersion` — a TRIGGER only. Passing the `Int`
    /// (not the `[ChatLine]`) keeps the parent body off the full-array
    /// dependency while still making SwiftUI call `updateUIViewController`
    /// once per model flush. The controller never trusts the value's
    /// arithmetic (SwiftUI may coalesce several flushes into one update); it
    /// pulls everything since its own last version via `changes`.
    let changeVersion: Int
    /// The model's `changes(since:)` — every published change after a
    /// version, or `.overrun`. A closure, not a stored array, so reading it
    /// doesn't register a body dependency.
    let changes: (Int) -> ChatChangeLog.Delta
    /// The model's `transcriptSnapshot()` — the first-mount / log-overrun /
    /// abandoned-backlog fallback. Only invoked when replay can't be used.
    let snapshot: () -> (version: Int, lines: [ChatLine])
    /// Builds a row for one line — the badge lookup and the four per-line
    /// callbacks are assembled by `ChatScreen`, keeping this component
    /// ignorant of the model layer.
    let rowContent: (ChatLine) -> ChatRow
    /// Inputs `rowContent` reads besides the line (badges loaded, can
    /// moderate). When it changes, every row already in the list is
    /// reconfigured — otherwise rows built before badges loaded or mod
    /// status arrived stay stale until recycled.
    let rowInputs: ChatRowInputs
    /// Link handler installed in every row. Cells are hosted by
    /// `UIHostingConfiguration` — separate SwiftUI roots that don't inherit
    /// the `openURL` the chat screen sets above this representable. Taken
    /// once, in `makeUIViewController`: the caller passes a stable action
    /// (`ClipLinkRouter.openURLAction`), so there is nothing to refresh.
    let openURL: OpenURLAction
    /// UIKit → SwiftUI: true when tailing the live edge. Drives the pill.
    @Binding var isAtBottom: Bool
    /// UIKit → SwiftUI: messages that arrived while the list was unpinned and
    /// are held back off screen. Drives the pill's "N new".
    @Binding var unreadCount: Int
    /// Ceiling for `unreadCount` — the transcript's retained-line cap. More
    /// than that many arrivals while reading means the oldest have already
    /// been trimmed, so "N new" stops at what a jump to the bottom can show.
    var unreadLimit: Int = .max
    /// SwiftUI → UIKit: incremented (by the jump-to-bottom pill, and on each
    /// of the user's own sends) to request a re-pin to the newest message.
    let scrollToBottomToken: Int
    /// True when the user's Edge-to-Edge Chat setting extends the
    /// transcript under the toolbar pills. Switches the top scroll-edge
    /// effect: `.hard` cutoff when the list stops at the safe-area edge,
    /// system-default soft dissolve when content runs underneath glass.
    var extendsToTop: Bool = false
    /// False for a mounted-but-off-screen pager neighbour: the list keeps
    /// up at a throttled rate instead of applying every flush, and catches
    /// up at once when it becomes the visible page.
    var isVisible: Bool = true
    /// Channel login for diagnostic logging & snapshots.
    var channelLoginName: String = ""
    /// A message row was tapped (with the keyboard down — a tap while
    /// typing just dismisses the keyboard).
    var onLineTapped: (ChatLine) -> Void = { _ in }

    func makeUIViewController(context: Context) -> ChatListViewController {
        let vc = ChatListViewController()
        vc.channelLoginName = channelLoginName
        vc.rowContent = rowContent
        vc.openURLAction = openURL
        vc.onLineTapped = onLineTapped
        vc.onAtBottomChanged = { atBottom in
            // Avoid mutating SwiftUI state during the UIKit layout pass.
            // Task { @MainActor } defers past the current synchronous
            // execution like DispatchQueue.main.async did, but stays in the
            // Swift concurrency model (main actor executor, not a raw GCD
            // enqueue) — one scheduling world instead of two.
            Task { @MainActor in isAtBottom = atBottom }
        }
        vc.onUnreadCountChanged = { count in
            // Same deferral as above — this can fire from inside a SwiftUI
            // update pass or a scroll callback.
            Task { @MainActor in unreadCount = count }
        }
        return vc
    }

    func updateUIViewController(_ vc: ChatListViewController, context: Context) {
        // rowContent captures fresh per-body closures each update — refresh it
        // so cells built after this call use current state.
        vc.channelLoginName = channelLoginName
        vc.rowContent = rowContent
        vc.extendsToTop = extendsToTop
        vc.onLineTapped = onLineTapped
        vc.unreadLimit = unreadLimit
        vc.isVisible = isVisible
        vc.update(
            changes: changes,
            snapshot: snapshot,
            rowInputs: rowInputs,
            scrollToBottomToken: scrollToBottomToken
        )
    }

    static func dismantleUIViewController(_ vc: ChatListViewController, coordinator: ()) {
        guard !vc.channelLoginName.isEmpty else { return }
        ChatDiagnostics.shared.removeListGeometry(
            channelLogin: vc.channelLoginName,
            ownerId: vc.diagnosticsOwnerId
        )
    }
}
#endif
