import SwiftUI

/// You → About → What's New. Hand-maintained release notes, newest
/// first. Add an entry per release — keep notes user-facing ("what can
/// I do now") rather than commit-log-shaped.
struct WhatsNewScreen: View {

    struct Release: Identifiable {
        let version: String
        let title: String
        let notes: [String]
        var id: String { version }
    }

    /// Newest first. The top entry may describe the in-development
    /// build; stamp it with the marketing version when cutting a release.
    static let releases: [Release] = [
        Release(
            version: "1.0",
            title: "A real home",
            notes: [
                "New tab bar: Home, Chats, Search and You.",
                "Home shows who's live the moment you open the app.",
                "Chats are now a list — open one and it goes full screen.",
                "Search any channel right from the tab bar.",
                "Emotes: turn 7TV, BetterTTV and FrankerFaceZ on or off.",
                "Filters: hide !commands and known chat bots.",
                "Choose whether chattr resumes your last chat on launch.",
            ]
        ),
    ]

    var body: some View {
        List {
            ForEach(Self.releases) { release in
                Section {
                    ForEach(release.notes, id: \.self) { note in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 5))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                            Text(note)
                        }
                    }
                } header: {
                    Text("\(release.version) — \(release.title)")
                }
            }
        }
        .navigationTitle("What's New")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
