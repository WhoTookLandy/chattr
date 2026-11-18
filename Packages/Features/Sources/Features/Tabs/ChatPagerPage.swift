import SwiftUI
import DesignSystem

/// One page slot in the pager: the chat when inside the mounted window, the
/// bare chat surface otherwise. Its own view so a window move re-evaluates
/// only the page slots, not the pager.
struct ChatPagerPage<Content: View>: View {
    let tabId: UUID
    let chatTabs: ChatTabsModel
    let window: PagerWindow
    @ViewBuilder let content: () -> Content

    var body: some View {
        if window.isMounted(tabId, in: chatTabs) {
            content()
        } else {
            // Same surface the chat paints, so a page that is still outside
            // the window (a fast multi-page fling) reads as loading chat,
            // not a hole.
            Color.chatSurface
        }
    }
}
