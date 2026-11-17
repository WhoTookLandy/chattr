import SwiftUI
import Accounts
import TwitchKit
import Core

/// Who's in chat — opened from the viewer count on the video. Twitch only
/// returns the chatter list to the broadcaster and their moderators
/// (`GET /chat/chatters`, scope `moderator:read:chatters`), so everyone
/// else gets a clear explanation instead of a blank sheet.
struct ViewerListSheet: View {
    let channel: ChannelDescriptor
    let account: Account
    let accountStore: AccountStore

    private enum LoadState {
        case loading
        case loaded
        case notModerator
        case missingScope
        case failed
    }

    @State private var state: LoadState = .loading
    @State private var chatters: [TwitchChatter] = []
    @State private var total: Int?
    @State private var cursor: String?
    @State private var isLoadingMore = false
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss
    @Environment(\.channelStatus) private var channelStatus
    @Environment(\.followsStore) private var followsStore

    /// The stream's viewer count, shown even when the list isn't available.
    private var viewerCount: Int? {
        ChannelStatusStore.liveStream(for: channel.channelId, status: channelStatus, follows: followsStore)?.viewerCount
    }

    private var filtered: [TwitchChatter] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return chatters }
        return chatters.filter {
            $0.userLogin.contains(needle) || $0.userName.lowercased().contains(needle)
        }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Viewers")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task { await loadFirstPage() }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            List {
                Section {
                    ForEach(filtered, id: \.userId) { chatter in
                        HStack {
                            Text(chatter.userName)
                                .font(.body)
                            if chatter.userName.lowercased() != chatter.userLogin {
                                Text(chatter.userLogin)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if cursor != nil, query.isEmpty {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .task { await loadMore() }
                    }
                } header: {
                    Text(headerText)
                }
            }
            .searchable(text: $query, prompt: "Search viewers")
        case .notModerator:
            unavailable(
                "Viewer list is for moderators",
                systemImage: "person.2.slash",
                message: "Twitch only shares who's in chat with the broadcaster and their moderators."
            )
        case .missingScope:
            unavailable(
                "Sign in again to see viewers",
                systemImage: "key",
                message: "chattr needs one more Twitch permission to show the viewer list. Remove and re-add your account in Settings → Accounts & Data to grant it."
            )
        case .failed:
            unavailable(
                "Couldn't load viewers",
                systemImage: "exclamationmark.triangle",
                message: "Try again in a moment."
            )
        }
    }

    private var headerText: String {
        let shown = total ?? chatters.count
        if let viewerCount {
            return "\(shown.formatted()) in chat · \(viewerCount.formatted()) watching"
        }
        return "\(shown.formatted()) in chat"
    }

    private func unavailable(_ title: String, systemImage: String, message: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            VStack(spacing: 6) {
                Text(message)
                if let viewerCount {
                    Text("\(viewerCount.formatted()) watching right now.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Loading

    private func fetchPage(after cursor: String?) async throws -> HelixPage<TwitchChatter> {
        let client = accountStore.client(for: account)
        let broadcasterID = channel.channelId
        let moderatorID = account.userId
        return try await accountStore.withTokenRefresh(for: account) {
            try await client.api.fetchChattersPage(
                broadcasterID: broadcasterID,
                moderatorID: moderatorID,
                first: 1000,
                after: cursor
            )
        }
    }

    private func loadFirstPage() async {
        do {
            let page = try await fetchPage(after: nil)
            chatters = page.data.sorted { $0.userLogin < $1.userLogin }
            total = page.total
            cursor = page.pagination?.cursor
            state = .loaded
        } catch let error as HelixError {
            switch error {
            case .forbidden:
                state = .notModerator
            case .unauthorized:
                // Twitch answers 401 for a token without the scope.
                state = .missingScope
            default:
                state = .failed
            }
        } catch {
            state = .failed
        }
    }

    private func loadMore() async {
        guard let after = cursor, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await fetchPage(after: after)
            chatters = (chatters + page.data).sorted { $0.userLogin < $1.userLogin }
            cursor = page.pagination?.cursor
        } catch {
            cursor = nil
        }
    }
}
