import SwiftUI
import NukeUI
import Nuke

/// Makes the chat pager's swipe discoverable: whenever the visible chat
/// changes (or the pager first appears), the neighbouring chats' avatars
/// peek in from the screen edges with a chevron for ~1.6s, then fade.
/// Nothing shows with a single open chat.
///
/// Non-interactive (`allowsHitTesting(false)`) — it's a hint, not a control;
/// the swipe itself and the channel pill remain the ways to switch. Takes
/// the model (not precomputed neighbours) so `activeTabId` changes
/// invalidate only this view, not `ChatPagerScreen`'s pager.
struct PagerEdgeHints: View {
    let chatTabs: ChatTabsModel

    @State private var isVisible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let tabs = chatTabs.tabs
        let currentId = chatTabs.activeTabId ?? tabs.first?.id
        let index = currentId.flatMap { id in tabs.firstIndex { $0.id == id } }
        let previous = index.flatMap { $0 > 0 ? tabs[$0 - 1] : nil }
        let next = index.flatMap { $0 + 1 < tabs.count ? tabs[$0 + 1] : nil }

        HStack {
            if let previous {
                hint(for: previous, leading: true)
            }
            Spacer(minLength: 0)
            if let next {
                hint(for: next, leading: false)
            }
        }
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: currentId) {
            guard tabs.count > 1 else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { isVisible = true }
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(.easeIn(duration: 0.35)) { isVisible = false }
        }
    }

    private func hint(for tab: ChatTab, leading: Bool) -> some View {
        HStack(spacing: 4) {
            if leading { chevron("chevron.compact.left") }
            LazyImage(request: ImageRequest.avatar(url: tab.profileImageURL, side: 26)) { state in
                if let image = state.image {
                    image.resizable().scaledToFill()
                } else {
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 26, height: 26)
            .clipShape(Circle())
            if !leading { chevron("chevron.compact.right") }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .glassEffect(.regular, in: Capsule())
        .padding(leading ? .leading : .trailing, 6)
    }

    private func chevron(_ name: String) -> some View {
        Image(systemName: name)
            .font(.body.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}
