import SwiftUI
import NukeUI

/// Emote picker sheet — a searchable, sectioned grid of every emote
/// available in the current channel (channel 7TV/BTTV/FFZ + Twitch
/// global + third-party globals). Presented from the compose bar's
/// emote button.
///
/// ## Interaction
///
/// Tapping an emote inserts its name into the composer and KEEPS the
/// picker open, so the user can stack several emotes in one message —
/// the standard emote-picker pattern (Discord/Slack). "Done" closes it.
///
/// The selected name is appended via the `onSelect` callback; the
/// compose bar owns the actual text mutation.
struct EmotePickerView: View {
    let sections: [EmoteSection]
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    /// Adaptive grid — as many ~40pt emote cells per row as fit.
    private let columns = [GridItem(.adaptive(minimum: 44), spacing: 8)]

    /// Filter every section by the search text, dropping sections that
    /// end up empty. Case-insensitive substring on the emote name.
    private var visibleSections: [EmoteSection] {
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return sections }
        return sections.compactMap { section in
            let matches = section.emotes.filter {
                $0.name.localizedCaseInsensitiveContains(trimmed)
            }
            guard !matches.isEmpty else { return nil }
            return EmoteSection(id: section.id, title: section.title, emotes: matches)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if sections.isEmpty {
                    ContentUnavailableView(
                        "No Emotes Yet",
                        systemImage: "face.smiling",
                        description: Text("Channel and global emotes load shortly after you open a channel.")
                    )
                } else if visibleSections.isEmpty {
                    ContentUnavailableView.search(text: search)
                } else {
                    grid
                }
            }
            .navigationTitle("Emotes")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .searchable(text: $search, prompt: "Search emotes")
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .autocorrectionDisabled()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var grid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16, pinnedViews: [.sectionHeaders]) {
                ForEach(visibleSections) { section in
                    Section {
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(section.emotes) { emote in
                                Button {
                                    onSelect(emote.name)
                                } label: {
                                    EmoteCell(emote: emote)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } header: {
                        Text(section.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                            // Opaque-ish background so pinned headers don't
                            // show emotes scrolling through them.
                            .background(.bar)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }
}

/// One emote cell in the grid: the image, with the name as the
/// accessibility label + a long-press tooltip via `.help` (macOS).
private struct EmoteCell: View {
    let emote: PickerEmote

    var body: some View {
        LazyImage(url: emote.imageURL) { state in
            if let image = state.image {
                image
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                // Placeholder keeps the grid cell from collapsing while
                // the image loads.
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
            }
        }
        .frame(width: 40, height: 40)
        .accessibilityLabel(emote.name)
    }
}
