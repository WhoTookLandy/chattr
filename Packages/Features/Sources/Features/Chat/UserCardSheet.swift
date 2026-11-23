import SwiftUI
import Accounts
import Channels
import ChatModel
import TwitchKit
import Core
import DesignSystem
import NukeUI
import Nuke

/// Which message's author the card is for, with that author's recent
/// messages as they stood when the card was opened.
struct UserCardTarget: Identifiable {
    let line: ChatLine
    /// The author's latest messages in this chat, newest first. Filtered
    /// out of the transcript once, here — a sheet's content closure re-runs
    /// with its presenter's body, and the filter is O(transcript).
    let recentLines: [ChatLine]
    var id: String { line.id }

    /// How many recent messages the card lists.
    static let recentLimit = 50

    init(line: ChatLine, transcript: [ChatLine] = []) {
        self.line = line
        self.recentLines = Self.recentLines(
            byAuthor: line.authorUserId,
            in: transcript,
            limit: Self.recentLimit
        )
    }

    /// The last `limit` chat messages by `authorUserId` in `transcript`
    /// (oldest first), returned newest first. Deleted placeholders and
    /// bubbles don't count.
    static func recentLines(byAuthor authorUserId: String, in transcript: [ChatLine], limit: Int) -> [ChatLine] {
        guard limit > 0 else { return [] }
        var recent: [ChatLine] = []
        for candidate in transcript.reversed()
        where candidate.authorUserId == authorUserId && candidate.kind == .message {
            recent.append(candidate)
            if recent.count == limit { break }
        }
        return recent
    }
}

/// Tap a chat message → this card. A short sheet that leaves chat visible
/// and usable behind it; drag it up for the user's bio and their recent
/// messages in this chat.
struct UserCardSheet: View {
    let line: ChatLine
    let badges: [ChatBadgeEntry]
    let account: Account
    let accountStore: AccountStore
    /// This user's latest messages in this chat, newest first
    /// (`UserCardTarget.recentLines`).
    let recentLines: [ChatLine]
    let rowContent: (ChatLine) -> ChatRow
    let onReply: (() -> Void)?
    let onBlock: (() -> Void)?
    let onReport: ((UserBlockReason) -> Void)?
    /// Non-nil when the viewer moderates this channel AND the target is
    /// neither the viewer nor the broadcaster: shows the one-row
    /// `UserCardModerationBar` (timeouts, ban, warn, unban).
    var moderation: ChatTranscriptModel? = nil

    /// Height of the resting card — enough for the header and actions.
    static let compactHeight: CGFloat = 230

    /// The resting height, grown by the single moderation row when shown —
    /// so the chips are reachable without dragging, and the recent messages
    /// still start right beneath them.
    private var restingHeight: CGFloat {
        moderation == nil ? Self.compactHeight : Self.compactHeight + UserCardModerationBar.height + 16
    }

    @State private var user: TwitchUser?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                actions
                if let moderation {
                    UserCardModerationBar(
                        targetUserId: line.authorUserId,
                        targetDisplayName: line.authorDisplayName,
                        chatModel: moderation
                    )
                    .id(line.authorUserId)
                }
                details
                recentMessages
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 20)
        }
        .scrollBounceBehavior(.basedOnSize)
        .task(id: line.authorUserId) { await loadUser() }
        .presentationDetents([.height(restingHeight), .large])
        .presentationDragIndicator(.visible)
        // Semi-modal: chat stays scrollable behind the resting card.
        .presentationBackgroundInteraction(.enabled(upThrough: .height(restingHeight)))
        .presentationContentInteraction(.resizes)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            LazyImage(request: ImageRequest.avatar(url: user.flatMap { URL(string: $0.profileImageUrl) }, side: 60)) { state in
                if let image = state.image {
                    image.resizable().scaledToFill()
                } else {
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .foregroundStyle(.secondary.opacity(0.5))
                }
            }
            .frame(width: 60, height: 60)
            .clipShape(Circle())
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(line.authorDisplayName)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(nameColor)
                        .lineLimit(1)
                    if user?.broadcasterType == "partner" {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(Color(red: 0x91 / 255, green: 0x46 / 255, blue: 0xFF / 255))
                            .accessibilityLabel("Partner")
                    }
                }
                if line.authorUserLogin.lowercased() != line.authorDisplayName.lowercased() {
                    Text("@\(line.authorUserLogin)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if !badges.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(badges, id: \.url) { entry in
                            BadgeImage(entry: entry, scale: 1.1)
                                .accessibilityLabel(entry.title ?? "Badge")
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var nameColor: Color {
        line.authorColor.isEmpty ? .primary : .twitchUsername(hex: line.authorColor, scheme: colorScheme)
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: 10) {
            if let onReply {
                actionButton("Reply", systemImage: "arrowshape.turn.up.left") {
                    onReply()
                    dismiss()
                }
            }
            actionButton("Twitch", systemImage: "arrow.up.forward.app") {
                if let url = Endpoints.TwitchWeb.channel(login: line.authorUserLogin) {
                    openURL(url)
                }
            }
            if onBlock != nil || onReport != nil {
                Menu {
                    if let onBlock {
                        Button(role: .destructive) {
                            onBlock()
                            dismiss()
                        } label: {
                            Label("Block", systemImage: "hand.raised")
                        }
                    }
                    if let onReport {
                        Menu {
                            Button("Harassment") { onReport(.harassment); dismiss() }
                            Button("Spam") { onReport(.spam); dismiss() }
                        } label: {
                            Label("Report…", systemImage: "exclamationmark.bubble")
                        }
                    }
                } label: {
                    actionLabel("More", systemImage: "ellipsis")
                }
                .accessibilityLabel("More actions for \(line.authorDisplayName)")
            }
        }
    }

    private func actionButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { actionLabel(title, systemImage: systemImage) }
            .buttonStyle(.plain)
    }

    private func actionLabel(_ title: String, systemImage: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
            Text(title)
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, minHeight: 56)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
    }

    // MARK: - Details (revealed by dragging up)

    @ViewBuilder
    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let created = user?.createdAt {
                Label("Joined \(created.formatted(.dateTime.month(.wide).year()))", systemImage: "calendar")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let bio = user?.description, !bio.isEmpty {
                Text(bio)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
            }
        }
    }

    @ViewBuilder
    private var recentMessages: some View {
        if !recentLines.isEmpty {
            // Lazy: the resting card shows none of these rows, and each is a
            // full `ChatRow` (badges, emote images).
            LazyVStack(alignment: .leading, spacing: 6) {
                Text("Recent messages")
                    .font(.headline)
                    .padding(.top, 4)
                ForEach(recentLines) { recent in
                    rowContent(recent)
                }
            }
        }
    }

    // MARK: - Loading

    private func loadUser() async {
        // Clear any prior user's profile immediately when switching targets
        // while the semi-modal sheet stays presented.
        user = nil
        let id = line.authorUserId
        guard !id.isEmpty else { return }
        do {
            let client = accountStore.client(for: account)
            let fetched = try await accountStore.withTokenRefresh(for: account) {
                try await client.api.fetchUser(id: id)
            }
            guard !Task.isCancelled else { return }
            user = fetched
        } catch {
            // The card still works from the message alone.
        }
    }
}
