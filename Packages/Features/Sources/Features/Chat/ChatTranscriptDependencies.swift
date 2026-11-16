import Core

/// The side effects `ChatTranscriptModel` reaches outside itself for —
/// UserDefaults-backed settings, the draft store, the speaker — injected so
/// tests can drive the model without touching any of them. `.live` wires
/// the production statics.
@MainActor
struct ChatTranscriptDependencies {
    /// The chat-filter toggles, read once per attach.
    var chatFilters: @MainActor () -> ChatViewerPolicy.Filters
    /// Clears a channel's persisted compose draft once a send commits.
    var clearDraft: @MainActor (ChannelDescriptor.ID) -> Void
    /// Whether highlighted live messages play a sound. Read lazily — only
    /// for an actual highlighted message from someone else (rare).
    var isHighlightSoundEnabled: @MainActor () -> Bool
    /// Plays the (throttled) highlight sound.
    var playHighlightSound: @MainActor () -> Void

    static var live: ChatTranscriptDependencies {
        ChatTranscriptDependencies(
            chatFilters: {
                ChatViewerPolicy.Filters(
                    hideCommands: ChatFilterSettings.hideCommands(),
                    hideBots: ChatFilterSettings.hideBots()
                )
            },
            clearDraft: { DraftStorage.clear(forChannel: $0) },
            isHighlightSoundEnabled: { HighlightSettings.soundEnabled() },
            playHighlightSound: { HighlightSoundPlayer.shared.play() }
        )
    }
}
