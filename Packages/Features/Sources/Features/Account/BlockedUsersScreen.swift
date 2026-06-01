import SwiftUI

/// Manage the active account's blocked users. The only place to unblock —
/// blocked users' messages are hidden in chat, so there's no row to long-press.
struct BlockedUsersScreen: View {
    @Environment(\.blockStore) private var blockStore

    var body: some View {
        Group {
            if let blockStore, !blockStore.blocked.isEmpty {
                List {
                    ForEach(blockStore.blocked) { user in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(user.displayName).font(.body)
                                Text("@\(user.login)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Unblock") {
                                Task { await blockStore.unblock(userId: user.id) }
                            }
                            .buttonStyle(.bordered)
                            .tint(.secondary)
                        }
                    }
                }
            } else {
                ContentUnavailableView(
                    "No Blocked Users",
                    systemImage: "hand.raised",
                    description: Text("Block someone from a chat message's long-press menu and they'll appear here.")
                )
            }
        }
        .navigationTitle("Blocked Users")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
