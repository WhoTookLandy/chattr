import Foundation

/// The static, declarative index of every user-facing setting. It drives two
/// things on the Settings root (`ProfileScreen`): the category rows, and the
/// search field that finds a setting by its title or keywords across all
/// categories and jumps to the screen that holds it.
///
/// ## Adding a setting (one line)
///
/// 1. Put the control on the screen that owns it (a category screen such as
///    `VideoDeviceSettingsScreen`, or a feature screen such as
///    `ChatFiltersScreen`).
/// 2. Add one `SettingsEntry` to `SettingsRegistry.entries`, in the block for
///    its category:
///
///    ```swift
///    SettingsEntry("keepScreenAwake", "Keep Screen Awake", keywords: ["sleep", "lock", "idle"], in: .videoAndDevice),
///    ```
///
///    `destination` defaults to the category's own screen. Pass
///    `to: .filters` (etc.) when the control lives on a deeper screen.
/// 3. Only if the setting needs a brand-new screen: add a case to
///    `SettingsDestination`, give it a `title`, and route it in
///    `SettingsDestinationView`. The compiler's exhaustive `switch` there
///    points at the one place to wire it.
///
/// If the new setting is one of the most important things in its category,
/// consider updating that category's `summary` (the one-line subtitle on the
/// root row) — it's curated, not generated, so it stays short.
///
/// ## Why static
///
/// Search runs on every keystroke. Entries are built once (a `static let`),
/// and each one pre-folds its title + keywords into a single lowercase,
/// diacritic-free haystack at init. A keystroke then folds the query once and
/// does plain `String.contains` checks over ~25 precomputed strings: no
/// per-keystroke allocation beyond the result array, no observation, nothing
/// that touches chat views.
///
/// Entries describe settings; they never read or write values. The values
/// themselves stay where they always were (`@AppStorage` keys read narrowly
/// by the views that need them — see `ChatAppearance`'s reactivity note), so
/// this registry adds no observation to the chat transcript.
enum SettingsRegistry {

    // MARK: - Entries

    /// Every searchable setting, grouped by category in the order categories
    /// appear on the root. Within a category, roughly the order the controls
    /// appear on screen (search results keep this order).
    static let entries: [SettingsEntry] = [
        // Appearance — AppearanceSettingsScreen
        SettingsEntry("theme", "Theme", keywords: ["dark mode", "light mode", "system", "colour", "color"], in: .appearance),
        SettingsEntry("textSize", "Text Size", keywords: ["font", "bigger", "smaller", "dynamic type", "zoom"], in: .appearance),
        SettingsEntry("timestamps", "Timestamps", keywords: ["time", "clock", "sent"], in: .appearance),
        SettingsEntry("badges", "Badges", keywords: ["moderator", "subscriber", "vip", "icons"], in: .appearance),
        SettingsEntry("showUsername", "Show Username", keywords: ["localized names", "display name", "login", "japanese", "korean", "chinese"], in: .appearance),
        SettingsEntry("edgeToEdge", "Edge-to-Edge Chat", keywords: ["full screen", "fullscreen", "header", "layout"], in: .appearance),

        // Chat — ChatSettingsScreen and the feature screens it links to
        SettingsEntry("highlights", "Highlights", keywords: ["mentions", "keywords", "notify", "@"], in: .chat, to: .highlights),
        SettingsEntry("highlightSound", "Highlight Sound", keywords: ["sound", "ping", "alert", "notification", "mention"], in: .chat, to: .highlights),
        SettingsEntry("filters", "Filters", keywords: ["hide", "mute", "noise"], in: .chat, to: .filters),
        SettingsEntry("hideCommands", "Hide Commands", keywords: ["!", "commands", "!drops", "!so"], in: .chat, to: .filters),
        SettingsEntry("hideBots", "Hide Known Bots", keywords: ["bots", "nightbot", "fossabot", "streamelements"], in: .chat, to: .filters),
        SettingsEntry("compactBots", "Compact Bot Messages", keywords: ["bots", "smaller", "dim", "banner"], in: .chat, to: .filters),
        SettingsEntry("emotes", "Emotes", keywords: ["emoji", "emoticons"], in: .chat, to: .emotes),
        SettingsEntry("emoteSources", "Third-Party Emotes", keywords: ["7tv", "bttv", "betterttv", "ffz", "frankerfacez", "sources"], in: .chat, to: .emotes),
        SettingsEntry("animatedEmotes", "Animated Emotes", keywords: ["gif", "animation", "battery", "motion"], in: .chat, to: .emotes),
        SettingsEntry("chatHistory", "Chat History", keywords: ["scrollback", "messages", "memory", "buffer"], in: .chat),
        SettingsEntry("resumeLastChat", "Resume Last Chat", keywords: ["launch", "restore", "reopen", "startup"], in: .chat),

        // Video & Device — VideoDeviceSettingsScreen
        SettingsEntry("showVideo", "Show Video in Chat", keywords: ["stream", "player", "watch"], in: .videoAndDevice),
        SettingsEntry("nativePlayer", "Native Video Player", keywords: ["picture in picture", "pip", "avplayer", "fullscreen"], in: .videoAndDevice),
        SettingsEntry("maxQuality", "Max Quality", keywords: ["resolution", "1080p", "720p", "data", "bandwidth"], in: .videoAndDevice),

        // Accounts & Data — AccountsDataSettingsScreen and the screens it links to
        SettingsEntry("accounts", "Accounts", keywords: ["switch account", "add account", "sign in", "log in", "login", "re-authorize"], in: .accountsAndData),
        SettingsEntry("blockedUsers", "Blocked Users", keywords: ["block", "unblock", "privacy", "ignore"], in: .accountsAndData, to: .blockedUsers),
        SettingsEntry("storage", "Storage", keywords: ["cache", "clear", "disk", "space", "images"], in: .accountsAndData, to: .storage),

        // About — AboutSettingsScreen
        SettingsEntry("whatsNew", "What's New", keywords: ["release notes", "changelog", "update"], in: .about, to: .whatsNew),
        SettingsEntry("version", "Version", keywords: ["build", "about"], in: .about),
    ]

    // MARK: - Search

    /// Entries whose title or keywords contain every whitespace-separated
    /// term of `query` (case- and diacritic-insensitive), in registry order.
    /// An empty/blank query returns no results — the root shows its
    /// categories instead.
    static func search(_ query: String) -> [SettingsEntry] {
        let terms = SettingsEntry.fold(query)
            .split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return [] }
        return entries.filter { entry in
            terms.allSatisfy { entry.haystack.contains($0) }
        }
    }
}

// MARK: - Category

/// A top-level group on the Settings root. Each gets one row (icon, title,
/// one-line summary) that pushes its category screen.
enum SettingsCategory: String, CaseIterable, Identifiable, Hashable, Sendable {
    case appearance
    case chat
    case videoAndDevice
    case accountsAndData
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: "Appearance"
        case .chat: "Chat"
        case .videoAndDevice: "Video & Device"
        case .accountsAndData: "Accounts & Data"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .appearance: "paintbrush"
        case .chat: "bubble.left.and.bubble.right"
        case .videoAndDevice: "play.rectangle"
        case .accountsAndData: "person.crop.circle"
        case .about: "info.circle"
        }
    }

    /// The root row's subtitle: what's inside, most-used first. Curated so
    /// it stays one line; keep it to three or four items.
    var summary: String {
        switch self {
        case .appearance: "Theme, text size, timestamps, edge-to-edge"
        case .chat: "Highlights, filters, emotes, history"
        case .videoAndDevice: "Video in chat, native player, quality"
        case .accountsAndData: "Accounts, blocked users, storage"
        case .about: "What's new, version"
        }
    }
}

// MARK: - Destination

/// Where a category row or search result navigates. Category screens are
/// `.category(_)`; feature screens reached through a category get their own
/// case. Routed to views by `SettingsDestinationView`.
enum SettingsDestination: Hashable, Sendable {
    case category(SettingsCategory)
    case highlights
    case filters
    case emotes
    case blockedUsers
    case storage
    case whatsNew

    var title: String {
        switch self {
        case .category(let category): category.title
        case .highlights: "Highlights"
        case .filters: "Filters"
        case .emotes: "Emotes"
        case .blockedUsers: "Blocked Users"
        case .storage: "Storage"
        case .whatsNew: "What's New"
        }
    }
}

// MARK: - Entry

/// One searchable setting. See `SettingsRegistry` for how to add one.
struct SettingsEntry: Identifiable, Sendable {
    /// Stable, unique id (unit-tested). Not persisted anywhere.
    let id: String
    /// Exactly the row title the user sees on the destination screen.
    let title: String
    /// Extra words people might search for: synonyms, sub-options, the
    /// names of things the setting affects. Lowercase is fine; matching
    /// is case-insensitive.
    let keywords: [String]
    let category: SettingsCategory
    let destination: SettingsDestination
    /// Folded `title + keywords`, built once at init for cheap matching.
    let haystack: String

    init(
        _ id: String,
        _ title: String,
        keywords: [String] = [],
        in category: SettingsCategory,
        to destination: SettingsDestination? = nil
    ) {
        self.id = id
        self.title = title
        self.keywords = keywords
        self.category = category
        self.destination = destination ?? .category(category)
        self.haystack = Self.fold(([title] + keywords).joined(separator: " "))
    }

    /// Where the result lives, for the search row's subtitle:
    /// "Chat › Filters" for a deep entry, "Appearance" for a category one.
    /// Skips the second hop when it would just repeat the title.
    var breadcrumb: String {
        switch destination {
        case .category:
            return category.title
        default:
            let leaf = destination.title
            return leaf == title ? category.title : "\(category.title) › \(leaf)"
        }
    }

    /// Lowercase + strip diacritics, so "theme" finds "Thème" and vice versa.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}
