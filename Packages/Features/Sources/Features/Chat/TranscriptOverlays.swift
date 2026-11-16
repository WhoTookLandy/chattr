import SwiftUI

/// The floating chrome over the transcript list — the jump-to-bottom pill on
/// the bottom edge, the connection pill and the report confirmation on the
/// top — shared by both list implementations (`ChatListView` on UIKit, the
/// legacy `ScrollView` elsewhere) so they can't drift apart.
///
/// Pure presentation: `ChatTranscript` owns the scroll, unread and
/// connection state and passes the current values in.
struct TranscriptOverlays: ViewModifier {
    /// False while the user reads scrollback — shows the jump pill.
    let isAtBottom: Bool
    /// Messages that arrived while scrolled up ("N new").
    let unreadCount: Int
    let connectionBanner: ConnectionBanner
    let showReportConfirmation: Bool
    /// The jump pill's action: snap to the newest message and resume tailing.
    let onJumpToLatest: () -> Void

    func body(content: Content) -> some View {
        content
            // Jump-to-bottom pill, just above the compose bar, whenever the
            // user has scrolled off the live edge.
            .overlay(alignment: .bottom) {
                if !isAtBottom {
                    JumpToBottomPill(unreadCount: unreadCount, action: onJumpToLatest)
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.2), value: isAtBottom)
            // Transient "Reconnecting… / Live again" indicator.
            .overlay(alignment: .top) {
                ConnectionPill(banner: connectionBanner)
                    .padding(.top, 8)
                    .animation(.snappy, value: connectionBanner)
            }
            .overlay(alignment: .top) {
                ReportConfirmationPill(isShown: showReportConfirmation)
                    .padding(.top, 8)
                    .animation(.snappy, value: showReportConfirmation)
            }
    }
}
