/// Row-construction inputs that live OUTSIDE `ChatLine` — what
/// `ChatScreen.chatRow(for:)` reads besides the line itself when a cell is
/// configured: the channel's badge table (`ChatBadgeStore.entries`, loaded
/// once, asynchronously) and whether the account can moderate here (drives
/// the row's Delete Message affordance).
///
/// The list configures a cell once and keeps it until the line changes, so a
/// row built before badges loaded — or before mod status was learned — would
/// stay badge-less / Delete-less until it happened to be recycled.
/// `ChatScreen` computes this token in its body (so it's observed); when it
/// changes, `ChatListView` reconfigures every row it holds.
struct ChatRowInputs: Hashable {
    /// Size of the badge table — 0 until `ChatBadgeStore.load` lands.
    var badgeEntryCount: Int
    /// `ChatTranscriptModel.currentUserCanModerate`.
    var canModerate: Bool
}
