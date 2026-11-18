import SwiftUI

/// Which chat pages the pager keeps mounted: the page it has settled on plus
/// one neighbour on each side.
///
/// ## Why pre-mount neighbours
///
/// A `LazyHStack` pager mounts a page only as it scrolls into view — i.e.
/// in the middle of the swipe gesture. Mounting a chat is the expensive part
/// of a swipe: a fresh `ChatTranscriptModel` attaches to its session, primes
/// up to the Chat History cap of lines, and the UIKit list self-sizes a
/// screenful of SwiftUI rows. Doing that while the finger is moving is the
/// hitch at the start of a swipe. Keeping the neighbours mounted means the
/// page being swiped in is already attached and laid out; the next
/// neighbour mounts once the scroll has come to rest, off-screen.
///
/// ## Why the window recenters only when the scroll is idle
///
/// `activeTabId` can change mid-gesture (`.scrollPosition(id:)` writes it as
/// the target page changes). Recentering then would mount the next page and
/// unmount the far one while the finger is still down — the very hitch this
/// avoids. So user-driven scrolling freezes the window; it catches up when
/// the scroll settles. Programmatic jumps (quick switcher) recenter at once,
/// so the destination page is mounted by the time the scroll lands.
///
/// Off-screen neighbours stay live but their lists apply updates at a
/// throttled rate (see `ChatListViewController.isVisible`), so a busy
/// neighbour doesn't cost a full-rate transcript.
@MainActor
@Observable
final class PagerWindow {
    /// The page the window is centered on. Nil before the first settle —
    /// pages then center on `activeTabId` (or the first tab).
    var centerId: UUID?

    /// True while the user is dragging or the page is snapping after a
    /// release. Written from the pager's scroll-phase callback.
    var isUserScrolling = false

    /// Pages within this distance of the center are mounted.
    static let radius = 1

    /// Whether the page for `tabId` should be mounted.
    func isMounted(_ tabId: UUID, in chatTabs: ChatTabsModel) -> Bool {
        let tabs = chatTabs.tabs
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return false }
        func position(of id: UUID?) -> Int? {
            guard let id else { return nil }
            return tabs.firstIndex { $0.id == id }
        }
        // Center on the settled page; if that tab has since closed (or
        // nothing has settled yet), on the active one, then the first. Never
        // "everything" — with many tabs open that would attach them all.
        //
        // `??` evaluates its right side only when needed, so `activeTabId` is
        // read (and observed by every page slot) only without a usable
        // center: `.scrollPosition(id:)` writes it mid-swipe.
        let centerIndex = position(of: centerId) ?? position(of: chatTabs.activeTabId) ?? 0
        return abs(index - centerIndex) <= Self.radius
    }
}
