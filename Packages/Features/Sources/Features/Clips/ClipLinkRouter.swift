import SwiftUI
import ChatModel

/// Routes Twitch clip links tapped in chat to the in-app clip player
/// instead of Safari. Every other link falls through to the system.
///
/// `ChatScreen` keeps one in `@State` and installs `openURLAction` as the
/// `openURL` environment value. The action is built ONCE (in `init`) so the
/// environment value never changes: a fresh `OpenURLAction` per
/// `ChatScreen` body pass would look like a new value to every link `Text`
/// in every chat cell.
@MainActor
@Observable
final class ClipLinkRouter {
    /// The clip whose player sheet is showing.
    var presented: ClipLinkTarget?

    @ObservationIgnored private(set) var openURLAction = OpenURLAction { _ in .systemAction }

    init() {
        let box = RouterBox()
        openURLAction = OpenURLAction { url in
            // Link taps are delivered on the main thread. (Bool out, so the
            // isolated hop doesn't depend on `Result` being Sendable.)
            let handled = MainActor.assumeIsolated {
                box.router?.handle(url) ?? false
            }
            return handled ? .handled : .systemAction
        }
        box.router = self
    }

    /// True when `url` was a clip and its sheet is now presented.
    private func handle(_ url: URL) -> Bool {
        guard let slug = TwitchClipLink.slug(in: url) else { return false }
        presented = ClipLinkTarget(slug: slug, sourceURL: url)
        return true
    }

    /// Weak back-reference so the action (held by the environment) doesn't
    /// keep the router alive.
    @MainActor
    private final class RouterBox {
        weak var router: ClipLinkRouter?
    }
}

/// A clip to play, identified by its slug.
struct ClipLinkTarget: Identifiable, Hashable {
    let slug: String
    /// The link as it appeared in chat — what "Open in Twitch" opens.
    let sourceURL: URL

    var id: String { slug }
}
