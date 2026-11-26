import SwiftUI
import Accounts
import Channels
import DesignSystem
import EmoteSources
import Nuke
import NukeUI
import TwitchKit
#if canImport(AppKit)
import AppKit
#endif

/// Emote picker sheet — Apple iOS 26 Liquid Glass half/full sheet showing every
/// usable emote for the current channel:
///   1. Recently used emotes in this channel
///   2. This channel's unlocked Twitch emotes (sub / bits / follower)
///   3. This channel's 7TV, BetterTTV, and FrankerFaceZ emotes
///   4. Every other channel the user is subscribed to (with channel avatars)
///   5. Unlocked Twitch specials (Prime, Turbo, Hype Train, Rewards…)
///   6. Twitch Global + third-party globals
///
/// ## Interaction
///
/// - Opens at `.medium` detent so live chat stays visible above; drag up for
///   `.large`.
/// - Tapping an emote inserts its token into the composer and keeps the picker
///   open so you can stack multiple emotes; when a draft is present, a compact
///   bottom bar previews it with undo-last-token and Send.
/// - Long-pressing any emote opens a live animated preview card with its exact
///   name, source/channel label, Insert, and Copy Name.
/// - Live-reactive: observes `GlobalCatalog`, `UserEmoteStore`,
///   `ChannelTwitchEmotesStore`, and `EmoteIndex` so sections appear as soon as
///   they finish loading without closing and reopening the sheet.
struct EmotePickerView: View {
    let channelId: String
    let channelLoginName: String
    let channelDisplayName: String
    let account: Account?
    let accountStore: AccountStore?
    let emoteIndex: EmoteIndex?
    let channelTwitchEmotes: ChannelTwitchEmotesStore?
    let recentEmotes: [PickerEmote]
    let draftText: String
    let canSend: Bool
    let onSelect: (PickerEmote) -> Void
    let onRemoveLastToken: () -> Void
    let onSend: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.globalCatalog) private var globalCatalog
    @Environment(\.userEmoteStore) private var userEmoteStore
    @Environment(\.followsStore) private var followsStore

    @State private var search = ""
    @FocusState private var searchFocused: Bool

    /// Assembled sections (built off-main on cache miss, instant on O(1) cache hit).
    @State private var loadedSections: [EmoteSection] = []
    @State private var hasBuiltOnce = false

    /// Debounced search results (`nil` when not searching).
    @State private var filtered: [EmoteSection]?
    @State private var searchTask: Task<Void, Never>?

    /// Quick-jump category rail state.
    @State private var activeSectionId: String?
    @State private var scrollTarget: EmoteGridView.ScrollTarget?
    @State private var scrollTargetToken = 0

    /// Long-press inspector popover target.
    @State private var inspectedEmote: PickerEmote?

    /// Bumped when `emoteIndex` finishes loading/reloading so sections refresh.
    @State private var emoteIndexTick = 0
    @State private var isRefreshing = false

    private var isSearching: Bool {
        !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var displayedSections: [EmoteSection] {
        filtered ?? loadedSections
    }

    /// Composite trigger for rebuilding sections whenever any underlying emote
    /// source updates while the picker is open.
    private struct RebuildKey: Equatable {
        let channelId: String
        let channelAvatarURL: URL?
        let thirdPartyGeneration: Int
        let twitchGlobalVersion: Int
        let userEmotesVersion: Int
        let channelTwitchVersion: Int
        let isFollowing: Bool
        let recentEmotes: [PickerEmote]
        let tick: Int
    }

    private var rebuildKey: RebuildKey {
        RebuildKey(
            channelId: channelId,
            channelAvatarURL: followsStore?.profileImageURLs[channelId]
                ?? userEmoteStore?.owners[channelId]?.profileImageURL,
            thirdPartyGeneration: emoteIndex?.generation ?? 0,
            twitchGlobalVersion: globalCatalog?.emoteVersion ?? 0,
            userEmotesVersion: userEmoteStore?.version ?? 0,
            channelTwitchVersion: channelTwitchEmotes?.version ?? 0,
            isFollowing: followsStore?.followedChannelIds.contains(channelId) ?? false,
            recentEmotes: recentEmotes,
            tick: emoteIndexTick
        )
    }

    private func makeBuildInput() -> EmoteCatalog.BuildInput {
        let versioned = emoteIndex?.snapshotWithGeneration()
        let avatarURL = followsStore?.profileImageURLs[channelId]
            ?? userEmoteStore?.owners[channelId]?.profileImageURL
        return EmoteCatalog.BuildInput(
            channelId: channelId,
            channelDisplayName: channelDisplayName,
            channelAvatarURL: avatarURL,
            recentEmotes: recentEmotes,
            thirdParty: versioned?.emotes ?? [:],
            thirdPartyGeneration: versioned?.generation ?? 0,
            twitchGlobal: globalCatalog?.globalEmotes ?? [:],
            twitchGlobalVersion: globalCatalog?.emoteVersion ?? 0,
            userEmotes: userEmoteStore?.emotes ?? [],
            userEmoteOwners: userEmoteStore?.owners ?? [:],
            userEmotesVersion: userEmoteStore?.version ?? 0,
            channelTwitchEmotes: channelTwitchEmotes?.emotes ?? [],
            channelTwitchVersion: channelTwitchEmotes?.version ?? 0,
            isFollowingChannel: followsStore?.followedChannelIds.contains(channelId) ?? false,
            isBroadcaster: account?.userId == channelId && !channelId.isEmpty
        )
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                    .padding(.bottom, 8)

                if !isSearching && !loadedSections.isEmpty {
                    categoryRail
                        .padding(.bottom, 6)
                }

                if userEmoteStore?.needsReauthForScope == true && !isSearching {
                    missingScopeBanner
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                }

                Divider()
                    .opacity(0.4)

                contentArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    draftBar
                }
            }

            if let emote = inspectedEmote {
                inspectorOverlay(for: emote)
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
            }
        }
        .animation(.snappy(duration: 0.18), value: inspectedEmote?.id)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .onAppear {
            // Instant O(1) cache hit on the very first frame — no spinner flash.
            let input = makeBuildInput()
            if let cached = EmoteCatalog.cachedSections(for: input) {
                loadedSections = cached
                hasBuiltOnce = true
                if activeSectionId == nil {
                    activeSectionId = cached.first?.id
                }
            }
        }
        .task(id: rebuildKey) {
            await rebuildSections()
        }
        // Ensure any still-loading sources finish and bump the picker live.
        .task(id: channelId) {
            await ensureSourcesLoaded()
        }
        .onChange(of: search) { _, raw in
            scheduleFilter(for: raw)
        }
    }

    // MARK: - Top Bar (Search + Refresh & Close Glass Orbs)

    private var topBar: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)

                    TextField("Search emotes", text: $search)
                        .textFieldStyle(.plain)
                        .font(.callout)
                        .focused($searchFocused)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        .submitLabel(.search)

                    if !search.isEmpty {
                        Button {
                            search = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.subheadline)
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
                .glassEffect(.regular, in: Capsule())

                Button {
                    Task { await refreshAll() }
                } label: {
                    Group {
                        if isRefreshing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
                    .glassEffect(.regular.interactive(), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(isRefreshing)
                .accessibilityLabel("Refresh emotes")

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                        .contentShape(Circle())
                        .glassEffect(.regular.interactive(), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
        }
    }

    // MARK: - Quick-Jump Category & Subscribed Channel Rail

    private var categoryRail: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(loadedSections.enumerated()), id: \.element.id) { index, section in
                        if index > 0 && loadedSections[index - 1].railGroup != section.railGroup {
                            Capsule()
                                .fill(Color.primary.opacity(0.14))
                                .frame(width: 1.5, height: 18)
                                .padding(.horizontal, 2)
                        }
                        railPill(for: section)
                            .id(section.id)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 2)
            }
            .onChange(of: activeSectionId) { _, newId in
                guard let newId else { return }
                withAnimation(.snappy(duration: 0.22)) {
                    proxy.scrollTo(newId, anchor: .center)
                }
            }
        }
    }

    private func railPill(for section: EmoteSection) -> some View {
        let isActive = activeSectionId == section.id
        return Button {
            scrollTargetToken &+= 1
            activeSectionId = section.id
            scrollTarget = EmoteGridView.ScrollTarget(sectionId: section.id, token: scrollTargetToken)
        } label: {
            railContent(for: section, isActive: isActive)
                .frame(height: 32)
                .padding(.horizontal, section.avatarURL != nil ? 4 : 9)
                .background {
                    if isActive {
                        Capsule()
                            .fill(Color.accentColor.opacity(0.18))
                            .overlay(
                                Capsule()
                                    .strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1)
                            )
                    } else {
                        Capsule()
                            .fill(Color.primary.opacity(0.05))
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    @ViewBuilder
    private func railContent(for section: EmoteSection, isActive: Bool) -> some View {
        switch section.kind {
        case .recent:
            Image(systemName: "clock.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(isActive ? Color.accentColor : .secondary)

        case .currentChannelTwitch, .subscribedChannel:
            if let avatarURL = section.avatarURL {
                ZStack(alignment: .bottomTrailing) {
                    LazyImage(request: ImageRequest.avatar(url: avatarURL, side: 24)) { state in
                        if let image = state.image {
                            image.resizable().scaledToFill()
                        } else {
                            Circle()
                                .fill(Color.twitchPurple.opacity(0.2))
                                .overlay {
                                    Text(String(section.title.prefix(1)).uppercased())
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(Color.twitchPurple)
                                }
                        }
                    }
                    .frame(width: 24, height: 24)
                    .clipShape(Circle())

                    if case .currentChannelTwitch = section.kind {
                        Circle()
                            .fill(Color.twitchPurple)
                            .frame(width: 9, height: 9)
                            .overlay(
                                Image(systemName: "star.fill")
                                    .font(.system(size: 5, weight: .bold))
                                    .foregroundStyle(.white)
                            )
                            .offset(x: 1, y: 1)
                    }
                }
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.twitchPurple)
                    Text(section.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isActive ? .primary : .secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 4)
            }

        case .channelThirdParty(let source):
            Text(EmoteCatalog.sourceLabel(source))
                .font(.caption.weight(.bold))
                .foregroundStyle(isActive ? Self.sourceColor(source) : .secondary)

        case .twitchUnlocked:
            Image(systemName: "sparkles")
                .font(.caption.weight(.semibold))
                .foregroundStyle(isActive ? Color.twitchPurple : .secondary)

        case .twitchGlobal:
            HStack(spacing: 3) {
                Image(systemName: "globe")
                    .font(.caption2.weight(.semibold))
                Text("Twitch")
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(isActive ? Color.twitchPurple : .secondary)

        case .globalThirdParty(let source):
            HStack(spacing: 3) {
                Image(systemName: "globe")
                    .font(.system(size: 9, weight: .semibold))
                Text(EmoteCatalog.sourceLabel(source))
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(isActive ? Self.sourceColor(source) : .secondary)
        }
    }

    // MARK: - Main Grid / Empty / Loading States

    @ViewBuilder
    private var contentArea: some View {
        if !hasBuiltOnce && loadedSections.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if loadedSections.isEmpty {
            ContentUnavailableView(
                "No Emotes Yet",
                systemImage: "face.smiling",
                description: Text("Channel and global emotes load shortly after you open a channel.")
            )
        } else if displayedSections.isEmpty {
            ContentUnavailableView.search(text: search)
        } else {
            EmoteGridView(
                sections: displayedSections,
                scrollTarget: scrollTarget,
                onSelect: { emote in
                    onSelect(emote)
                },
                onInspect: { emote in
                    inspectedEmote = emote
                },
                onActiveSectionChanged: { sectionId in
                    if activeSectionId != sectionId {
                        activeSectionId = sectionId
                    }
                }
            )
        }
    }

    // MARK: - Missing Scope Notice

    private var missingScopeBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.twitchPurple)
            Text("Sign in again in Settings to load your subscriber emotes.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.twitchPurple.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Bottom Draft Preview Bar

    private var draftBar: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.4)
            HStack(spacing: 8) {
                Text(draftText)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    onRemoveLastToken()
                } label: {
                    Image(systemName: "delete.left")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 34)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete last token")

                Button {
                    onSend()
                    dismiss()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(
                            canSend ? Color.twitchPurple : Color.secondary.opacity(0.4),
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("Send message")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
        }
    }

    // MARK: - Long-Press Emote Inspector Overlay

    private func inspectorOverlay(for emote: PickerEmote) -> some View {
        ZStack {
            Color.black.opacity(0.32)
                .ignoresSafeArea()
                .onTapGesture {
                    inspectedEmote = nil
                }

            VStack(spacing: 14) {
                // Live animated preview when available!
                let previewURL = emote.animatedURL ?? emote.imageURL
                let previewIsAnimated = emote.animatedURL != nil || emote.isAnimated
                EmoteImageView(
                    url: previewURL,
                    isAnimated: previewIsAnimated,
                    width: 84,
                    height: 84,
                    accessibilityLabel: emote.name,
                    boxSize: CGSize(width: 84, height: 84),
                    animate: true
                ) { image in
                    image
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                } placeholder: { _ in
                    RoundedRectangle(cornerRadius: 12).fill(.quaternary)
                }

                VStack(spacing: 4) {
                    Text(emote.name)
                        .font(.headline)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    if let source = emote.sourceLabel, !source.isEmpty {
                        Text(source)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        #if os(iOS)
                        UIPasteboard.general.string = emote.name
                        #elseif canImport(AppKit)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(emote.name, forType: .string)
                        #endif
                        inspectedEmote = nil
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        onSelect(emote)
                        inspectedEmote = nil
                    } label: {
                        Label("Insert", systemImage: "plus")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(Color.twitchPurple, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
            .frame(maxWidth: 260)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(0.22), radius: 24, y: 12)
        }
    }

    // MARK: - Async Build, Search & Refresh

    private func rebuildSections() async {
        let input = makeBuildInput()
        if let cached = EmoteCatalog.cachedSections(for: input) {
            loadedSections = cached
            hasBuiltOnce = true
            syncActiveSection(for: cached)
            reapplySearchIfNeeded()
            return
        }

        let built = await Task.detached(priority: .userInitiated) {
            EmoteCatalog.buildSections(from: input)
        }.value
        guard !Task.isCancelled else { return }
        loadedSections = built
        hasBuiltOnce = true
        syncActiveSection(for: built)
        reapplySearchIfNeeded()
    }

    private func syncActiveSection(for sections: [EmoteSection]) {
        if let current = activeSectionId, sections.contains(where: { $0.id == current }) {
            return
        }
        activeSectionId = sections.first?.id
    }

    private func ensureSourcesLoaded() async {
        // Kick any source that hasn't loaded yet (all idempotent / coalesced).
        // MainActor Tasks (not `async let`) because `Account` is a non-Sendable
        // SwiftData `@Model` and `async let` trips Swift 6's sending check.
        let userTask = Task { @MainActor in
            guard let account, let accountStore, let userEmoteStore else { return }
            await userEmoteStore.load(
                account: account,
                accountStore: accountStore,
                followsStore: followsStore
            )
        }
        let channelTwitchTask = Task { @MainActor in
            guard let account, let accountStore, let channelTwitchEmotes, !channelId.isEmpty else { return }
            await channelTwitchEmotes.load(
                account: account,
                accountStore: accountStore,
                channelId: channelId
            )
        }
        let thirdPartyTask = Task { @MainActor in
            guard let emoteIndex, !channelId.isEmpty else { return }
            let before = emoteIndex.generation
            await emoteIndex.load(broadcasterId: channelId, broadcasterLogin: channelLoginName)
            if emoteIndex.generation != before {
                emoteIndexTick &+= 1
            }
        }
        await withTaskCancellationHandler {
            await userTask.value
            await channelTwitchTask.value
            await thirdPartyTask.value
        } onCancel: {
            userTask.cancel()
            channelTwitchTask.cancel()
            thirdPartyTask.cancel()
        }
    }

    private func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let globalTask = Task { @MainActor in
            guard let account, let accountStore, let globalCatalog, !globalCatalog.hasLoaded else { return }
            await globalCatalog.load(account: account, accountStore: accountStore)
        }
        let userTask = Task { @MainActor in
            guard let account, let accountStore, let userEmoteStore else { return }
            await userEmoteStore.load(
                account: account,
                accountStore: accountStore,
                followsStore: followsStore,
                force: true
            )
        }
        let channelTwitchTask = Task { @MainActor in
            guard let account, let accountStore, let channelTwitchEmotes, !channelId.isEmpty else { return }
            await channelTwitchEmotes.load(
                account: account,
                accountStore: accountStore,
                channelId: channelId,
                force: true
            )
        }
        let thirdPartyTask = Task { @MainActor in
            guard let emoteIndex, !channelId.isEmpty else { return }
            let before = emoteIndex.generation
            _ = await emoteIndex.reload(broadcasterId: channelId, broadcasterLogin: channelLoginName)
            if emoteIndex.generation != before {
                emoteIndexTick &+= 1
            }
        }
        await withTaskCancellationHandler {
            await globalTask.value
            await userTask.value
            await channelTwitchTask.value
            await thirdPartyTask.value
        } onCancel: {
            globalTask.cancel()
            userTask.cancel()
            channelTwitchTask.cancel()
            thirdPartyTask.cancel()
        }
    }

    private func reapplySearchIfNeeded() {
        searchTask?.cancel()
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            filtered = nil
            return
        }
        filtered = EmoteCatalog.filter(loadedSections, needle: trimmed.lowercased())
    }

    private func scheduleFilter(for raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()
        guard !trimmed.isEmpty else {
            filtered = nil
            return
        }
        let snapshot = loadedSections
        let needle = trimmed.lowercased()
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) {
                EmoteCatalog.filter(snapshot, needle: needle)
            }.value
            guard !Task.isCancelled else { return }
            filtered = result
        }
    }

    private static func sourceColor(_ source: Emote.Source) -> Color {
        switch source {
        case .sevenTV: return Color(red: 0x29 / 255, green: 0xB6 / 255, blue: 0xF6 / 255)
        case .bttv:    return Color(red: 0xD5 / 255, green: 0x00 / 255, blue: 0x1C / 255)
        case .ffz:     return Color(red: 0x76 / 255, green: 0x76 / 255, blue: 0xFF / 255)
        }
    }
}

/// One emote cell in SwiftUI surfaces (quick recent-emote row in `ComposeBar`,
/// macOS fallback grid): always renders a still image.
struct EmoteCell: View {
    let emote: PickerEmote
    var size: CGFloat = 40

    var body: some View {
        EmoteImageView(
            url: emote.imageURL,
            isAnimated: emote.isAnimated,
            width: size, height: size,
            accessibilityLabel: emote.name,
            boxSize: CGSize(width: size, height: size),
            animate: false
        ) { image in
            image
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        } placeholder: { _ in
            RoundedRectangle(cornerRadius: 6).fill(.quaternary)
        }
    }
}
