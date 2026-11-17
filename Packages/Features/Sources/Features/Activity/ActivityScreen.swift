import SwiftUI
import Core
import DesignSystem
import NukeUI
import Nuke

/// The Activity tab: @-mentions and highlight-keyword hits from every open
/// chat, newest first (see `ActivityStore`). Tapping an entry jumps to that
/// channel's chat. Viewing the tab clears its badge.
struct ActivityScreen: View {
    let store: ActivityStore

    /// Opens (or re-focuses) the entry's channel chat — AppShell routes it
    /// to the Chats tab with that chat pushed. From the environment rather
    /// than a closure argument, so this view's inputs compare equal when
    /// AppShell's body re-runs (every badge change).
    @Environment(\.openChannel) private var openChannel
    @Environment(\.colorScheme) private var colorScheme
    @State private var isVisible = false

    var body: some View {
        NavigationStack {
            Group {
                if store.entries.isEmpty {
                    ContentUnavailableView {
                        Label("No activity yet", systemImage: "bell")
                    } description: {
                        Text("When someone @-mentions you, or a highlight keyword shows up in an open chat, it lands here.")
                    }
                } else {
                    List {
                        ForEach(store.entries) { entry in
                            Button {
                                openChannel?(entry.channel)
                            } label: {
                                row(entry)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.clear)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Color.chatSurface.ignoresSafeArea())
            .navigationTitle("Activity")
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                if !store.entries.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Clear") { store.clear() }
                    }
                }
            }
            // Clear on appear, and again whenever a new entry arrives while
            // the tab is on screen — so the badge never counts what you're
            // already looking at, but still counts arrivals while you're
            // elsewhere (TabView keeps this view alive off-screen, so the
            // visibility flag gates it).
            .onAppear {
                isVisible = true
                store.markAllRead()
            }
            .onDisappear { isVisible = false }
            .onChange(of: store.entries.first?.id) {
                if isVisible { store.markAllRead() }
            }
        }
    }

    private func row(_ entry: ActivityStore.Entry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            LazyImage(request: ImageRequest.avatar(url: entry.channel.profileImageURL, side: 34)) { state in
                if let image = state.image {
                    image.resizable().scaledToFill()
                } else {
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.secondary.opacity(0.5))
                }
            }
            .frame(width: 34, height: 34)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("#\(entry.channel.channelLoginName)")
                    Text("·")
                    Text(entry.timestamp, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                    if entry.reason == .keyword {
                        Text("· keyword")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

                Text("\(Text(entry.authorDisplayName).fontWeight(.semibold).foregroundStyle(nameColor(entry))): \(entry.text)")
                    .font(.subheadline)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func nameColor(_ entry: ActivityStore.Entry) -> Color {
        entry.authorColor.isEmpty ? .primary : .twitchUsername(hex: entry.authorColor, scheme: colorScheme)
    }
}
