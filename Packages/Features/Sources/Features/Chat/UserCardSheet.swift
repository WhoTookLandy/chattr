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

/// Tap a username in chat → this Apple iOS 26 Liquid Glass profile sheet.
///
/// Resting detent leaves live chat scrollable behind it with instant identity,
/// readable badge pills, high-frequency actions (Reply, Mention, Channel), and
/// floating `⋯` / `×` sheet orbs. Drag up for inset-grouped About facts, live
/// stream status, and this chatter's recent messages with the tapped line
/// highlighted.
struct UserCardSheet: View {
    let line: ChatLine
    let badges: [ChatBadgeEntry]
    var channelId: String = ""
    var channelLoginName: String = ""
    let account: Account
    let accountStore: AccountStore
    /// This user's latest messages in this chat, newest first
    /// (`UserCardTarget.recentLines`).
    let recentLines: [ChatLine]
    let rowContent: (ChatLine) -> ChatRow
    let onReply: (() -> Void)?
    var onMention: ((String) -> Void)? = nil
    let onBlock: (() -> Void)?
    let onReport: ((UserBlockReason) -> Void)?
    /// Non-nil when the viewer moderates this channel AND the target is
    /// neither the viewer nor the broadcaster: shows the inset-grouped
    /// `UserCardModerationBar` (status banner, timeouts, warn, ban, unban).
    var moderation: ChatTranscriptModel? = nil

    /// Base height of the resting card (header + actions + swipe cue).
    static let compactHeight: CGFloat = 236

    /// Resting height grows cleanly for the badge pill strip and moderation
    /// drawer so primary controls stay reachable without dragging up.
    private var restingHeight: CGFloat {
        var height = Self.compactHeight
        if !badges.isEmpty { height += 38 }
        if moderation != nil { height += UserCardModerationBar.height + 14 }
        return height
    }

    private static let timestampFormat = Date.VerbatimFormatStyle(
        format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
        locale: .autoupdatingCurrent,
        timeZone: .autoupdatingCurrent,
        calendar: .autoupdatingCurrent
    )

    @State private var user: TwitchUser?
    @State private var hasLoadedUser = false
    @State private var fetchedLiveStream: TwitchStream?
    @State private var copiedTrigger = 0
    @State private var showCopiedConfirmation = false
    @State private var copiedDismissTask: Task<Void, Never>?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @Environment(\.openChannel) private var openChannel
    @Environment(\.channelStatus) private var channelStatus
    @Environment(\.followsStore) private var followsStore
    @Environment(\.dismiss) private var dismiss

    /// Live stream from local stores immediately, enriched by the Helix lookup.
    private var liveStream: TwitchStream? {
        fetchedLiveStream ?? ChannelStatusStore.liveStream(
            for: line.authorUserId,
            status: channelStatus,
            follows: followsStore
        )
    }

    private var canOpenChannelInApp: Bool {
        openChannel != nil && !line.authorUserId.isEmpty && line.authorUserId != channelId
    }

    private var mentionInsertionName: String {
        MentionAutocomplete.Candidate(
            login: line.authorUserLogin.lowercased(),
            displayName: line.authorDisplayName,
            color: line.authorColor
        ).insertionName
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if !badges.isEmpty {
                    badgePills
                }
                actions
                if let moderation {
                    UserCardModerationBar(
                        targetUserId: line.authorUserId,
                        targetDisplayName: line.authorDisplayName,
                        chatModel: moderation
                    )
                    .id(line.authorUserId)
                }
                swipeCue
                aboutSection
                recentMessagesSection
            }
            .padding(.horizontal, 18)
            .padding(.top, 20)
            .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .overlay(alignment: .topTrailing) {
            sheetOrbs
                .padding(.top, 14)
                .padding(.trailing, 16)
        }
        .appSensoryFeedback(.success, trigger: copiedTrigger)
        .task(id: line.authorUserId) { await loadUser() }
        .onDisappear { copiedDismissTask?.cancel() }
        .presentationDetents([.height(restingHeight), .large])
        .presentationDragIndicator(.visible)
        // Semi-modal: chat stays scrollable behind the resting card.
        .presentationBackgroundInteraction(.enabled(upThrough: .height(restingHeight)))
        .presentationContentInteraction(.resizes)
    }

    // MARK: - Top-Right Glass Orbs

    private var sheetOrbs: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                Menu {
                    Button {
                        copyUsername()
                    } label: {
                        Label("Copy Username", systemImage: "doc.on.doc")
                    }
                    Button {
                        openTwitchWeb()
                    } label: {
                        Label("Open on Twitch", systemImage: "arrow.up.forward.app")
                    }
                    if onBlock != nil || onReport != nil {
                        Divider()
                    }
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
                    Image(systemName: "ellipsis")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 32, height: 32)
                        .contentShape(Circle())
                        .glassEffect(.regular.interactive(), in: Circle())
                }
                .accessibilityLabel("More actions for \(line.authorDisplayName)")

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Circle())
                        .glassEffect(.regular.interactive(), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            avatarView

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(line.authorDisplayName)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(nameColor)
                        .lineLimit(1)
                    if user?.broadcasterType == "partner" {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.subheadline)
                            .foregroundStyle(Color(red: 0x91 / 255, green: 0x46 / 255, blue: 0xFF / 255))
                            .accessibilityLabel("Partner")
                    }
                }
                // Clear the top-right floating orbs on the top line only.
                .padding(.trailing, 76)

                if showCopiedConfirmation {
                    Label("Copied @\(line.authorUserLogin)", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.green)
                        .lineLimit(1)
                        .transition(.opacity)
                } else {
                    let subtitle = Self.compactSubtitle(
                        displayName: line.authorDisplayName,
                        login: line.authorUserLogin,
                        joinedAt: user?.createdAt,
                        recentCount: recentLines.count
                    )
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .animation(.snappy(duration: 0.2), value: showCopiedConfirmation)
    }

    @ViewBuilder
    private var avatarView: some View {
        let isLive = liveStream != nil
        let core = ZStack(alignment: .bottom) {
            LazyImage(request: ImageRequest.avatar(url: user.flatMap { URL(string: $0.profileImageUrl) }, side: 56)) { state in
                if let image = state.image {
                    image.resizable().scaledToFill()
                } else {
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .foregroundStyle(.secondary.opacity(0.5))
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(Circle())
            .overlay(
                Circle()
                    .strokeBorder(
                        isLive ? Color.red : Color.primary.opacity(0.14),
                        lineWidth: isLive ? 2.25 : 0.75
                    )
            )

            if isLive {
                Text("LIVE")
                    .font(.system(size: 8.5, weight: .heavy))
                    .tracking(0.4)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Color.red, in: Capsule())
                    .offset(y: 4)
            }
        }
        .padding(.bottom, isLive ? 3 : 0)
        .accessibilityHidden(true)

        if canOpenChannelInApp {
            Button(action: openAuthorChannel) { core }
                .buttonStyle(.plain)
        } else {
            core
        }
    }

    private var nameColor: Color {
        line.authorColor.isEmpty ? .primary : .twitchUsername(hex: line.authorColor, scheme: colorScheme)
    }

    /// Single-line metadata summary shown immediately above the fold.
    nonisolated static func compactSubtitle(
        displayName: String,
        login: String,
        joinedAt: Date?,
        recentCount: Int
    ) -> String {
        var parts: [String] = []
        if !login.isEmpty && login.lowercased() != displayName.lowercased() {
            parts.append("@\(login)")
        }
        if let joinedAt {
            parts.append("Joined \(joinedAt.formatted(.dateTime.year()))")
        }
        if recentCount > 0 {
            parts.append("\(recentCount) \(recentCount == 1 ? "msg" : "msgs")")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Readable Badge Pills

    private var badgePills: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(badges, id: \.url) { entry in
                    HStack(spacing: 5) {
                        BadgeImage(entry: entry, scale: 0.85)
                        if let title = entry.title, !title.isEmpty {
                            Text(title)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.leading, 6)
                    .padding(.trailing, (entry.title?.isEmpty == false) ? 9 : 6)
                    .padding(.vertical, 4)
                    .background(groupedFill, in: Capsule())
                    .overlay(Capsule().strokeBorder(groupedBorder, lineWidth: 0.5))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(entry.title ?? "Badge")
                }
            }
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }

    // MARK: - Primary Actions

    private var actions: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                if let onReply {
                    actionButton("Reply", systemImage: "arrowshape.turn.up.left", prominent: true) {
                        onReply()
                        dismiss()
                    }
                }
                if let onMention {
                    actionButton("Mention", systemImage: "at") {
                        onMention(mentionInsertionName)
                        dismiss()
                    }
                }
                if canOpenChannelInApp {
                    actionButton(
                        liveStream != nil ? "Watch" : "Channel",
                        systemImage: liveStream != nil ? "play.rectangle.fill" : "tv"
                    ) {
                        openAuthorChannel()
                    }
                } else {
                    actionButton("Twitch", systemImage: "arrow.up.forward.app") {
                        openTwitchWeb()
                    }
                }
            }
        }
    }

    private func actionButton(
        _ title: String,
        systemImage: String,
        prominent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
                Text(title)
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(prominent ? Color.accentColor : Color.primary)
            .frame(maxWidth: .infinity, minHeight: 54)
            .glassEffect(
                prominent
                    ? .regular.tint(Color.accentColor.opacity(0.22)).interactive()
                    : .regular.interactive(),
                in: .rect(cornerRadius: 14, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var swipeCue: some View {
        HStack(spacing: 5) {
            Image(systemName: "chevron.compact.up")
                .font(.caption2.weight(.semibold))
            Text(recentLines.isEmpty
                 ? "Swipe up for profile details"
                 : "Swipe up for bio & \(recentLines.count) recent \(recentLines.count == 1 ? "message" : "messages")")
                .font(.caption)
        }
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity)
        .padding(.top, 2)
    }

    // MARK: - Expanded Details (Inset-Grouped Apple Cards)

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                statCell(title: "Joined Twitch") {
                    if let created = user?.createdAt {
                        Text(created.formatted(.dateTime.month(.abbreviated).year()))
                    } else if hasLoadedUser {
                        Text("—")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Mar 2020")
                            .redacted(reason: .placeholder)
                    }
                }

                Divider()
                    .frame(height: 36)

                statCell(title: "In This Chat") {
                    Text("\(recentLines.count) \(recentLines.count == 1 ? "message" : "messages")")
                }
            }

            if let stream = liveStream {
                Divider()
                liveStreamRow(stream)
            }

            if let bio = user?.description, !bio.isEmpty {
                Divider()
                Text(bio)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(14)
            }
        }
        .background(groupedFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(groupedBorder, lineWidth: 0.5)
        )
    }

    private func statCell<Value: View>(title: String, @ViewBuilder value: () -> Value) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            value()
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private func liveStreamRow(_ stream: TwitchStream) -> some View {
        let content = HStack(spacing: 10) {
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(stream.title.isEmpty ? "Live now" : stream.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                let meta = stream.gameName.isEmpty
                    ? "\(StreamFormatting.viewers(stream.viewerCount)) watching"
                    : "\(stream.gameName) · \(StreamFormatting.viewers(stream.viewerCount)) watching"
                Text(meta)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if canOpenChannelInApp {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())

        if canOpenChannelInApp {
            Button(action: openAuthorChannel) { content }
                .buttonStyle(.plain)
        } else {
            content
        }
    }

    @ViewBuilder
    private var recentMessagesSection: some View {
        if !recentLines.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(channelLoginName.isEmpty ? "Recent Messages" : "Recent in #\(channelLoginName)")
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(recentLines.count)")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(colorScheme == .dark ? 0.09 : 0.06), in: Capsule())
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                // Lazy: the resting card sits above this section, and each
                // row is a full `ChatRow` (badges, emote images, context menu).
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(recentLines) { recent in
                        let isTapped = recent.id == line.id
                        Divider()
                        VStack(alignment: .leading, spacing: 4) {
                            if isTapped {
                                HStack {
                                    Text("Tapped message")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(Color.accentColor)
                                    Spacer()
                                    Text(recent.timestamp, format: Self.timestampFormat)
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            rowContent(recent)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(isTapped ? Color.accentColor.opacity(colorScheme == .dark ? 0.14 : 0.09) : Color.clear)
                        .overlay(alignment: .leading) {
                            if isTapped {
                                Rectangle()
                                    .fill(Color.accentColor)
                                    .frame(width: 3)
                            }
                        }
                    }
                }
            }
            .background(groupedFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(groupedBorder, lineWidth: 0.5)
            )
        }
    }

    // MARK: - Actions & Loading

    private func openAuthorChannel() {
        guard canOpenChannelInApp else { return }
        openChannel?(ChannelDescriptor(
            platform: .twitch,
            channelId: line.authorUserId,
            channelLoginName: line.authorUserLogin,
            channelDisplayName: line.authorDisplayName,
            profileImageURL: user.flatMap { URL(string: $0.profileImageUrl) }
        ))
        dismiss()
    }

    private func openTwitchWeb() {
        if let url = Endpoints.TwitchWeb.channel(login: line.authorUserLogin) {
            openURL(url)
        }
    }

    private func copyUsername() {
        DeveloperSettings.copyToClipboard(line.authorUserLogin)
        copiedTrigger &+= 1
        showCopiedConfirmation = true
        copiedDismissTask?.cancel()
        copiedDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            showCopiedConfirmation = false
        }
    }

    private func loadUser() async {
        // Clear any prior user's profile immediately when switching targets
        // while the semi-modal sheet stays presented.
        user = nil
        fetchedLiveStream = nil
        hasLoadedUser = false
        let id = line.authorUserId
        guard !id.isEmpty else {
            hasLoadedUser = true
            return
        }

        let accountUserId = account.userId
        let client = accountStore.client(for: account)
        let store = accountStore
        async let fetchedUser: TwitchUser? = try? await store.withTokenRefresh(forUserId: accountUserId) {
            try await client.api.fetchUser(id: id)
        }
        async let fetchedStream: TwitchStream? = try? await store.withTokenRefresh(forUserId: accountUserId) {
            try await client.api.fetchStreamsPage(userIDs: [id], first: 1).data.first
        }

        let (resolvedUser, resolvedStream) = await (fetchedUser, fetchedStream)
        guard !Task.isCancelled else { return }
        user = resolvedUser
        fetchedLiveStream = resolvedStream
        hasLoadedUser = true
    }

    private var groupedFill: Color {
        Color.primary.opacity(colorScheme == .dark ? 0.055 : 0.04)
    }

    private var groupedBorder: Color {
        Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.08)
    }
}
