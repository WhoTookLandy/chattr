/// How a chat was opened, as far as its video goes. Carried from the call
/// site through `ChatTabsModel.open` / `present` to `onWillPresent`, where
/// AppShell decides whether Settings → Video & Device → When a Chat Opens applies.
public enum ChatOpenIntent: Sendable, Equatable {
    /// A plain tap (a row, a link, the back stack): the preference decides
    /// whether the video opens.
    case implicit
    /// The user already chose — the preview menu's Watch, Listen or Chat
    /// Only — and set the video state themselves. The preference must not
    /// override it.
    case explicit
}
