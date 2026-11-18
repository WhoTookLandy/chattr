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

    /// The sorted sections, once a build that was still running when the
    /// picker opened has finished (see `EmoteCatalog.resolve(_:)`).
    @State private var built: [EmoteSection]?

    /// The build `sections` stands in for, if it does.
    private var pendingBuild: Int? { sections.first?.pendingBuild }

    /// Every section the picker can show, or `nil` while they are still
    /// being sorted off the main thread.
    private var loadedSections: [EmoteSection]? {
        pendingBuild == nil ? sections : built
    }

    /// Filtered result, or `nil` when no search is active (show everything).
    /// Kept as state rather than a body-computed property so the (debounced)
    /// filter work happens on a search-change trigger, not on every body
    /// re-evaluation.
    @State private var filtered: [EmoteSection]?

    /// In-flight debounce task, cancelled when the query changes again.
    @State private var searchTask: Task<Void, Never>?

    /// Adaptive grid — as many ~40pt emote cells per row as fit.
    private let columns = [GridItem(.adaptive(minimum: 44), spacing: 8)]

    /// What the grid actually renders: the filtered subset when searching,
    /// otherwise the full section list.
    private var displayedSections: [EmoteSection] { filtered ?? loadedSections ?? [] }

    /// Pure filter — pre-lowercased `searchKey` + plain `contains`, dropping
    /// sections that end up empty. Static so the debounce task can call it
    /// without capturing `self`.
    private static func filter(_ sections: [EmoteSection], needle: String) -> [EmoteSection] {
        sections.compactMap { section in
            let matches = section.emotes.filter { $0.searchKey.contains(needle) }
            guard !matches.isEmpty else { return nil }
            return EmoteSection(id: section.id, title: section.title, emotes: matches)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let loadedSections {
                    if loadedSections.isEmpty {
                        ContentUnavailableView(
                            "No Emotes Yet",
                            systemImage: "face.smiling",
                            description: Text("Channel and global emotes load shortly after you open a channel.")
                        )
                    } else if displayedSections.isEmpty {
                        ContentUnavailableView.search(text: search)
                    } else {
                        grid
                    }
                } else {
                    // First open for this emote table: the sections are
                    // being sorted off the main thread (a moment, even for
                    // thousands of emotes).
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .task(id: pendingBuild) {
                guard pendingBuild != nil else { return }
                built = await EmoteCatalog.resolve(sections)
                // A query typed while loading had nothing to filter yet.
                scheduleFilter(for: search)
            }
            .navigationTitle("Emotes")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .searchable(text: $search, prompt: "Search emotes")
            // Debounce: filtering thousands of emotes on every keystroke is
            // what made search feel laggy. Clearing the field resets to the
            // full list immediately (no debounce); a non-empty query waits
            // ~120ms after the last keystroke before filtering, so a fast
            // typist triggers one filter pass instead of one per character.
            .onChange(of: search) { _, raw in
                scheduleFilter(for: raw)
            }
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

    private func scheduleFilter(for raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()
        guard !trimmed.isEmpty else {
            filtered = nil
            return
        }
        let snapshot = loadedSections ?? []
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            filtered = Self.filter(snapshot, needle: trimmed.lowercased())
        }
    }

    @ViewBuilder
    private var grid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16, pinnedViews: [.sectionHeaders]) {
                ForEach(displayedSections) { section in
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
///
/// Always a still. A grid of hundreds of cells would otherwise decode
/// every animation it scrolled past — up to 120 frames each, at a larger
/// size than chat uses — through the cache chat's visible emotes live in.
private struct EmoteCell: View {
    let emote: PickerEmote

    var body: some View {
        EmoteImageView(
            url: emote.imageURL,
            isAnimated: emote.isAnimated,
            width: 40, height: 40,
            accessibilityLabel: emote.name,
            boxSize: CGSize(width: 40, height: 40),
            animate: false
        ) { image in
            image
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        } placeholder: { _ in
            // Placeholder keeps the grid cell from collapsing while the
            // image loads (and on failure).
            RoundedRectangle(cornerRadius: 6).fill(.quaternary)
        }
    }
}
