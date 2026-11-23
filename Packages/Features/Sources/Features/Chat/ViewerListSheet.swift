import SwiftUI
import Accounts
import TwitchKit
import Core
import os

private let logger = AppLogger.make("Features.ViewerListSheet")

/// Who's in chat — opened from the viewer count on the video. Twitch only
/// returns the chatter list to the broadcaster and their moderators
/// (`GET /chat/chatters`, scope `moderator:read:chatters`), so everyone
/// else gets a clear explanation instead of a blank sheet.
struct ViewerListSheet: View {
    /// Page size requested per `fetchChattersPage` call. TwitchKit 0.3.4's
    /// shared `HelixQuery.appendPagination` validates `1...100` client-side
    /// and throws `HelixError.badRequest` for values above 100, so keep this
    /// within that bound and rely on cursor pagination for larger chats.
    static let pageSize = 100

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
                    if let nextCursor = cursor {
                        if query.isEmpty {
                            HStack {
                                Spacer()
                                ProgressView()
                                Spacer()
                            }
                            .task(id: nextCursor) { await loadMore() }
                        } else {
                            Button {
                                Task { await loadMore() }
                            } label: {
                                HStack(spacing: 8) {
                                    if isLoadingMore {
                                        ProgressView()
                                            .controlSize(.small)
                                    }
                                    Text(loadMoreSearchLabel)
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .disabled(isLoadingMore)
                        }
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
            ) {
                state = .loading
                Task { await loadFirstPage() }
            }
        }
    }

    private var headerText: String {
        let shown = total ?? chatters.count
        if let viewerCount {
            return "\(shown.formatted()) in chat · \(viewerCount.formatted()) watching"
        }
        return "\(shown.formatted()) in chat"
    }

    private var loadMoreSearchLabel: String {
        if let total {
            return "Load more viewers (\(chatters.count.formatted()) of \(total.formatted()) loaded)"
        }
        return "Load more viewers (\(chatters.count.formatted()) loaded)"
    }

    private func unavailable(
        _ title: String,
        systemImage: String,
        message: String,
        retry: (() -> Void)? = nil
    ) -> some View {
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
        } actions: {
            if let retry {
                Button("Try Again", action: retry)
                    .buttonStyle(.bordered)
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
                first: Self.pageSize,
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
                logger.warning("Viewer list load failed for #\(channel.channelLoginName, privacy: .public): \(String(describing: error), privacy: .public)")
                state = .failed
            }
        } catch {
            logger.warning("Viewer list load failed for #\(channel.channelLoginName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            state = .failed
        }
    }

    private func loadMore() async {
        guard let after = cursor, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await fetchPage(after: after)
            var seen = Set(chatters.map(\.userId))
            var merged = chatters
            for chatter in page.data where seen.insert(chatter.userId).inserted {
                merged.append(chatter)
            }
            chatters = merged.sorted { $0.userLogin < $1.userLogin }
            cursor = page.pagination?.cursor
        } catch is CancellationError {
            // Scrolled away or started searching — keep `cursor` so pagination
            // resumes when the footer re-appears.
        } catch let urlError as URLError where urlError.code == .cancelled {
            // URLSession cancellation on view tear-down/search — keep `cursor`.
        } catch {
            logger.warning("Viewer list pagination failed for #\(channel.channelLoginName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            cursor = nil
        }
    }
}
