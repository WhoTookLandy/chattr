import SwiftUI

/// The Highlights feature's single settings home: the keyword list AND
/// the sound toggle. Reachable from You → Chat → Highlights. (The sound
/// toggle used to live inline on the Profile screen, a different surface
/// from the keywords it modifies — one feature, one page now.)
///
/// A message that contains any of these keywords (case-insensitive
/// substring) gets the highlighted row treatment AND — if the sound
/// toggle is on — plays the highlight sound. Self-mentions
/// (`@yourlogin`) are always highlighted regardless of this list; the
/// keywords are additive.
///
/// ## State model
///
/// `@State keywords` is the screen's working copy, seeded from
/// `HighlightSettings.keywords()` on init. Every mutation (add /
/// delete) updates the @State (instant UI) and immediately persists
/// the full list via `HighlightSettings.setKeywords`. No "Save"
/// button — edits apply live, matching the rest of the app's settings
/// (theme, sound toggle).
///
/// Changing keywords here takes effect the next time a chat attaches
/// (channel reopen / app relaunch) — already-open chats keep the list
/// they attached with. The footer notes this.
struct HighlightKeywordsScreen: View {

    @State private var keywords: [String] = HighlightSettings.keywords()
    @State private var newKeyword: String = ""
    @FocusState private var addFieldFocused: Bool

    /// Bound straight to the persisted key via @AppStorage. Defaults to `true`
    /// — matching `HighlightSettings.soundEnabled()`, which reads the same key
    /// (unset → on) for `HighlightSoundPlayer`. The projected `$soundEnabled`
    /// binding replaces the previous @State mirror + closure `Binding` +
    /// manual `setSoundEnabled` write-through. (`keywords` stays @State below:
    /// @AppStorage can't hold a `[String]`, so that list keeps its
    /// load-once-then-persist-on-edit shape.)
    @AppStorage(HighlightSettings.soundEnabledKey) private var soundEnabled = true

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $soundEnabled) {
                    Label("Highlight Sound", systemImage: "speaker.wave.2.fill")
                }
            } footer: {
                Text("Play a sound when a message @-mentions you or matches a keyword.")
            }

            Section {
                // Inline add row — text field + a plus button. Submitting
                // the field (return key) also adds, so the user can rattle
                // off several keywords without reaching for the button.
                HStack {
                    TextField("Add a keyword", text: $newKeyword)
                        .focused($addFieldFocused)
                        .submitLabel(.done)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .onSubmit { addKeyword() }
                    Button {
                        addKeyword()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .disabled(trimmedNew.isEmpty)
                }
            } footer: {
                Text("Case-insensitive. A message containing any keyword is highlighted.")
            }

            if keywords.isEmpty {
                Section {
                    // ContentUnavailableView inside a Form section reads as
                    // a friendly empty state without leaving the settings
                    // context.
                    ContentUnavailableView(
                        "No Keywords",
                        systemImage: "text.magnifyingglass",
                        description: Text("Add words you want to be notified about — your name, a game, a giveaway keyword.")
                    )
                }
            } else {
                Section {
                    ForEach(keywords, id: \.self) { keyword in
                        Text(keyword)
                    }
                    .onDelete(perform: deleteKeywords)
                } header: {
                    Text("Keywords")
                } footer: {
                    Text("Changes apply the next time you open a channel.")
                }
            }
        }
        .navigationTitle("Highlights")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// Trimmed version of the in-progress keyword — used for the
    /// add-button disabled state and for the dedup check.
    private var trimmedNew: String {
        newKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Append the in-progress keyword if it's non-empty and not already
    /// present (case-insensitive). Persists + clears the field + keeps
    /// focus so the user can keep adding.
    private func addKeyword() {
        let candidate = trimmedNew
        guard !candidate.isEmpty else { return }
        // Case-insensitive dedup — "Raid" and "raid" are the same keyword
        // since matching is case-insensitive anyway.
        guard !keywords.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) else {
            newKeyword = ""
            return
        }
        keywords.append(candidate)
        HighlightSettings.setKeywords(keywords)
        newKeyword = ""
        addFieldFocused = true
    }

    /// Swipe-to-delete handler. Removes at the offsets and persists.
    private func deleteKeywords(at offsets: IndexSet) {
        keywords.remove(atOffsets: offsets)
        HighlightSettings.setKeywords(keywords)
    }
}
