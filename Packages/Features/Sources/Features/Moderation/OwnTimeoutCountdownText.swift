import SwiftUI

/// The banner's "you can chat again in 9:42" line for a timeout of known
/// length.
///
/// The live countdown (`Text(timerInterval:)`, redrawn by the system every
/// second) runs only while this page is the visible pager page AND the
/// scene is active. Pre-mounted neighbours and a backgrounded app show the
/// static end time instead, so they spend nothing per second.
///
/// A leaf of its own so the active-page and scene-phase reads invalidate
/// only this line (and only while a timeout is running) — never the banner
/// around it or `ChatScreen`. Rendering never decides expiry:
/// `OwnChatRestrictionState` lifts the timeout at its deadline whether or
/// not anything is on screen.
struct OwnTimeoutCountdownText: View {
    let until: Date
    /// The pager tab; nil outside the pager (always the visible page).
    let tabId: UUID?

    @Environment(\.chatTabs) private var chatTabs
    @Environment(\.scenePhase) private var scenePhase

    private var isLive: Bool {
        guard scenePhase == .active else { return false }
        guard let tabId else { return true }
        return chatTabs?.activeTabId == tabId
    }

    var body: some View {
        let now = Date.now
        if isLive, until > now {
            Text("You're timed out here. You can chat again in \(Text(timerInterval: now...until, countsDown: true).monospacedDigit().bold()).")
        } else {
            Text("You're timed out here until \(Text(until.formatted(date: .omitted, time: .shortened)).bold()).")
        }
    }
}
