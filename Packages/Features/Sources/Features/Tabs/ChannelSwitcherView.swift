import SwiftUI

/// Lightweight switcher over the user's OPEN chats — the horizontal swipe
/// order made explicit and editable. Distinct from Follows (the full browse
/// experience): this lists only what's already open. Reorder here defines
/// the swipe order; ✕ closes a chat; tapping a row activates it and dismisses.
struct ChannelSwitcherView: View {
    @Bindable var model: ChatTabsModel
    /// Invoked by the footer button — the parent dismisses this sheet and
    /// presents the Follows browse sheet.
    let onBrowseFollows: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Open chats") {
                    ForEach(model.tabs) { tab in
                        Button {
                            model.activeTabId = tab.id
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Text(tab.displayName)
                                    .foregroundStyle(.primary)
                                Spacer(minLength: 8)
                                if tab.id == model.activeTabId {
                                    Image(systemName: "checkmark")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                    .onMove { source, destination in
                        model.move(fromOffsets: source, toOffset: destination)
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            model.close(tabId: model.tabs[index].id)
                        }
                    }
                }
            }
            .navigationTitle("Channels")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button(action: onBrowseFollows) {
                    Label("Browse Follows to add a chat", systemImage: "square.grid.2x2")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.glass)
                .padding()
            }
        }
        .presentationDetents([.medium, .large])
    }
}
