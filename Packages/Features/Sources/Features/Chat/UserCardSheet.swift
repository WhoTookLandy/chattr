import SwiftUI
import Accounts
import Channels
import ChatModel
import TwitchKit
import Core
import DesignSystem
import NukeUI
import Nuke

/// Which message's author the card is for.
struct UserCardTarget: Identifiable {
    let line: ChatLine
    var id: String { line.id }
}

/// Tap a chat message → this card. A short sheet that leaves chat visible
/// and usable behind it; drag it up for the user's bio and their recent
/// messages in this chat.
struct UserCardSheet: View {
    let line: ChatLine
    let badges: [ChatBadgeEntry]
    let account: Account
    let accountStore: AccountStore
    /// This user's messages in this chat, oldest first.
    let recentLines: [ChatLine]
    let rowContent: (ChatLine) -> ChatRow
    let onReply: (() -> Void)?
    let onBlock: (() -> Void)?
    let onReport: ((UserBlockReason) -> Void)?

    /// Height of the resting card — enough for the header and actions.
    static let compactHeight: CGFloat = 230

    @State private var user: TwitchUser?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                actions
                details
                recentMessages
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 20)
        }
        .scrollBounceBehavior(.basedOnSize)
        .task(id: line.authorUserId) { await loadUser() }
        .presentationDetents([.height(Self.compactHeight), .large])
        .presentationDragIndicator(.visible)
        // Semi-modal: chat stays scrollable behind the resting card.
        .presentationBackgroundInteraction(.enabled(upThrough: .height(Self.compactHeight)))
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
                if let url = URL(string: "https://www.twitch.tv/\(line.authorUserLogin)") {
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
            VStack(alignment: .leading, spacing: 6) {
                Text("Recent messages")
                    .font(.headline)
                    .padding(.top, 4)
                ForEach(recentLines.suffix(50).reversed()) { recent in
                    rowContent(recent)
                }
            }
        }
    }

    // MARK: - Loading

    private func loadUser() async {
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
