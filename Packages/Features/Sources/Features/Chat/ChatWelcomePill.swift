import SwiftUI

/// "Welcome to soochu's chat room!" — Twitch's join greeting, shown as a
/// transient pinned pill at the top of the transcript instead of a line
/// mixed into (and scrolled away with) the messages.
///
/// Shown once per channel per app session: swiping back to a page you've
/// already seen shouldn't greet you again. `ChatScreen` drives visibility.
struct ChatWelcomePill: View {
    let channelDisplayName: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "hand.wave.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)
            Text("Welcome to \(channelDisplayName)'s chat room!")
                .font(.footnote.weight(.medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: Capsule())
        .accessibilityElement(children: .combine)
    }

    /// Channels already greeted this session.
    @MainActor private static var greeted: Set<String> = []

    /// True the first time it's asked about `channelKey` this session.
    @MainActor static func claimGreeting(for channelKey: String) -> Bool {
        greeted.insert(channelKey).inserted
    }
}
