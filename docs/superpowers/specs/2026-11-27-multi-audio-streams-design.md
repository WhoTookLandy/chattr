# Multi-Audio Background Streams — Design

**Date:** 2026-11-27
**Status:** Approved (Opus 5.5 + Sol 6.1 High notes folded in)
**Scope:** Playing up to 3 pinned audio-only Twitch streams in the background while watching another channel's video (or browsing chats/Home), with per-stream mixing, seamless promotion/demotion, unified audio-session arbitration, and Liquid Glass UI controls.

---

## 1. Context & Problem

`chattr` is a multi-chat Twitch client, but its playback stack is built around **one global player** that follows the active chat tab:

- `PlaybackCenter` owns a single `channel`, `engine`, and `StreamPlayerController`. Playing another channel tears down the previous engine.
- `StreamHeaderView` and `StreamPlaybackPolicy` read two global `@AppStorage` flags (`expandedKey`, `audioOnlyKey`), so swiping tabs either replaces the active stream or stops it if the destination chat is offline or collapsed.
- `PlaybackAudioSession`, `PlaybackLifecycleObserver`, `StreamNowPlaying`, and `HomeFeedPreviewController` assume at most one stream in `PlaybackCenter`.

Common multi-chat workflows break under that model:
1. Watching Streamer A's gameplay/video while listening to Streamer B's watch party or commentary in background audio.
2. Keeping 1–3 squad/collab streams audible in the background while swiping across chats (including offline chats).
3. Adjusting relative loudness or quickly soloing one stream when multiple people talk at once.

---

## 2. Goals & Non-Goals

### Goals
- **1 Primary ("Stage") Stream + up to 3 Pinned Background Audio Streams.**
- **Zero visual footprint and zero behavioral regression** when `pinnedAudio.isEmpty` — single-stream playback works identically to today.
- **Explicit pinning only:** swiping tabs never silently leaves old streams playing in the background.
- **Works with both primary engines:** `WebStreamEngine` (default) and `NativeStreamEngine` can play primary video while headless native `AVPlayer` instances play pinned background audio.
- **Seamless in-place promote/demote on the native path:** promoting a pinned background stream to primary video (or demoting a native primary video to background audio) reuses the running `NativeStreamEngine` and cached playlist via `NativeStreamPlayer.Coordinator.setAudioOnly`. (Demoting a `WebStreamEngine` primary rebuilds onto a native `audio_only` engine with a brief handoff.)
- **Per-stream mixing:** independent volume sliders (`0–100%`) on every native slot, deterministic mute/unmute on every slot (including web primary), 1-tap Solo, and Mute All.
- **Configurable in-video indicator:** Slim Chip Strip by default (Option 1) in portrait, Floating Glass Pill (Option 2) selectable in Settings → Video & Device (and always used in landscape).

### Non-Goals (this pass)
- Multiple simultaneous **video** players (multiview grid).
- Background audio via `WKWebView` (pinned audio is strictly native `AVPlayer` and gated by `PlayerSettings.isNativePlaybackEnabled`).
- Persisting and auto-resuming pinned background streams across cold app launches.
- Separate iOS Lock Screen cards per stream (iOS limits each app to one `MPNowPlayingInfoCenter` item).

---

## 3. Architecture & State Invariants

Following `docs/conventions.md` (~500 LOC file split threshold), `PlaybackCenter` is split cleanly across sibling files in `Packages/Features/Sources/Features/Chat/`:
- `PlaybackSlot.swift` — per-stream playback unit
- `PlaybackCenter.swift` — core state, primary play/stop, hosts, per-channel observation flags
- `PlaybackCenter+Pinned.swift` — pin, unpin, promote, demote, solo, mute-all, offline reconciliation
- `PlaybackCenter+AudioSession.swift` — aggregate audio-session arbitration, interruptions, route changes, media-services reset, multi-stream Now Playing
- `PlaybackCenter+Holds.swift` — per-slot & aggregate holds

### 3.1 `PlaybackSlot` and `PlaybackCenter` ownership

`PlaybackSlot` (`@MainActor @Observable final class`):
- `let id: UUID`
- `var channel: ChannelDescriptor`
- `var title: String`
- `var profileImageURL: URL?`
- `var audioOnly: Bool`
- `var allowsPictureInPicture: Bool` (`true` for primary, `false` for pinned)
- `var engineKind: StreamEngineKind?` (**observed** — drives `supportsVolumeControl` in SwiftUI without observing `@ObservationIgnored avPlayer`)
- `private(set) var lingeringStream: TwitchStream?` (**observed** — preserves existing live-to-offline softening in `StreamHeaderView`, `ChatHeaderBar`, and `LandscapeStageLayout`)
- `let controller: StreamPlayerController`
- `@ObservationIgnored var engine: (any StreamEngine)?`
- `@ObservationIgnored var engineKey: String?`
- `@ObservationIgnored var firstOfflineReadingAt: Date?`
- `@ObservationIgnored var lastLiveStream: TwitchStream?`
- `@ObservationIgnored var pauseUnloadTask: Task<Void, Never>?`
- `@ObservationIgnored var lastQuality: PlayerQuality`
- `@ObservationIgnored var lastNative: Bool`
- `@ObservationIgnored var promotedToNative = false` (keeps a promoted native slot on `NativeStreamEngine` even when global `Native Video Player` preference is off, until channel change or native failure)
- `@ObservationIgnored var generation: Int = 0`
- `@ObservationIgnored var currentHolds: [PlaybackHoldReason: SlotHold] = [:]`
- `@ObservationIgnored var resumesAfterInterruption = false`

`PlaybackCenter` (`@MainActor @Observable final class`):
- `static let maxPinnedAudioSlots = 3`
- `private(set) var primary: PlaybackSlot?`
- `private(set) var pinnedAudio: [PlaybackSlot] = []`
- `private(set) var soloSlotID: UUID?`
- `private(set) var isMutedAll = false`
- `@ObservationIgnored private var ignoreNextPiPClose = false`
- `private let idleController = StreamPlayerController()` (returned by `controller` when `primary == nil` so previews/existing single-stream callers stay non-nil)

#### Explicit playback predicates & `isPlaying` audit
- `var hasPrimary: Bool { primary != nil }` (and `var isPlaying: Bool { hasPrimary }` kept for primary-scoped checks: `HomeContent.hasActiveVideoMiniPlayer`, `StreamHeaderView`, `StreamPlaybackPolicy`, existing tests).
- `var hasAnyPlayback: Bool { primary != nil || !pinnedAudio.isEmpty }` — used by every surface or controller that reacts to **any** active stream:
  - `MiniPlayerHost.showsMiniPlayer`
  - `HomeFeedPreviewController` (takes `.feedPreview` hold whenever `hasAnyPlayback`)
  - `PlaybackLifecycleObserver.didEnterBackground` (iterates `primary` + `pinnedAudio` whenever `hasAnyPlayback`)
  - `PlaybackCenter.holdPlayback(_:)` (acquires holds whenever `hasAnyPlayback`)
  - `SearchCategoryStreamsScreen.bottomClearance` (`hasAnyPlayback ? 96 : 24`)
  - `AddChannelView.bottomClearance` (`hasAnyPlayback ? 96 : 24`)
- `func isPlaying(_ channelId: String) -> Bool` — true only when `primary?.channel.channelId == channelId`.
- `func isPinnedAudio(_ channelId: String) -> Bool` — true when `pinnedAudio` contains `channelId`.
- `func isPlayingOrPinned(_ channelId: String) -> Bool` — true if in `primary` or `pinnedAudio` (used by `ChatOpenVideoPolicy` so opening a pinned channel's chat never triggers Wi-Fi autoplay or duplicate playback).

### 3.2 Stable Center-Owned Callbacks (No Stale Closures on Slot Swap)

Because promoting a pinned slot replaces `primary` (and its `StreamPlayerController`), **UI and app-level callbacks never attach directly to a slot's `controller`**:
- `PlaybackCenter` owns:
  - `var onRestoreFromPictureInPicture: (() -> Void)?` — wired once by `AppShell.wirePictureInPicture()`.
  - `var onPictureInPictureClosed: (() -> Void)?` — wired once by `AppShell.wirePictureInPicture()`.
  - `var onPrimaryTap: (() -> Void)?` — wired by `StreamHeaderView`, `LandscapeStreamStage`, or `MiniPlayerOverlay`.
  - `var onPrimarySwipeDown: (() -> Void)?` — wired by `StreamHeaderView` or `LandscapeStreamStage` (cleared by `MiniPlayerOverlay`).
- Whenever `PlaybackCenter` creates a `PlaybackSlot`, `wireSlotCallbacks(_ slot: PlaybackSlot)` binds every `slot.controller` callback **keyed by `slot.id`**, checking whether `slot.id == primary?.id` vs `pinnedAudio`:
  - `onNativeFailure`: primary → `nativeEngineGaveUp(slotID:)` (fallback to web or stop if background audio-only); pinned → `pinnedSlotFailed(slotID:)` (tears down & removes only that pinned slot).
  - `staysOnNativeEngine`: primary → `primaryStaysOnNativeEngine`; pinned → `false` (bounded retries via `PlaybackRecovery.maxRetries`, then gives up cleanly rather than spinning forever).
  - `onStreamEnded`: primary → `stopPrimary()`; pinned → `unpinBackgroundAudio(channelId:)` (never stops primary!).
  - `onPictureInPictureActiveChange`: acts only if `slot.id == primary?.id`.
  - `onPausedChange`: reschedules that slot's `pauseUnloadTask`, refreshes Now Playing, reconciles audio session & background holds.
  - `onResumeRequested`: restores THAT slot's unloaded engine (`restoreUnloadedEngine(slotID:)`), whether primary or pinned.
  - `onAudioStateChange`: triggered by mute/volume changes; calls `reconcileAudioSession()`, `refreshNowPlaying()`, and `reconcileBackgroundHold(for: slotID)`.
  - `onRestoreFromPictureInPicture` / `onPictureInPictureClosed`: forwards to `PlaybackCenter`'s closure only if `slot.id == primary?.id` and `!ignoreNextPiPClose`.
  - `onTap` / `onSwipeDown`: forwards to `onPrimaryTap` / `onPrimarySwipeDown` only if `slot.id == primary?.id` (automatic no-op if demoted).

### 3.3 Explicit Stop Operations

Three distinct operations with explicit caller contracts:
1. **`stopPrimary()`** (also aliased by `stop()` for backwards compatibility with single-stream tests/callers): tears down `primary` only, clears primary holds & PiP flags, leaves `pinnedAudio` untouched, reconciles audio session & Now Playing. Used by `StreamPlaybackPolicy`, `StreamHeaderView`, `ChatHeaderBar` Stop Stream, `MiniPlayerOverlay` video tile × / fling, and `AppShell` PiP-closed.
2. **`unpinBackgroundAudio(channelId:)` / `stopAllPinnedAudio()` / `stopAudioDockStreams()`**: tears down one or all `pinnedAudio` slots, exits solo cleanly (restoring remaining slots' mute states if the soloed slot was removed), reconciles audio session & Now Playing. `stopAudioDockStreams()` stops all `pinnedAudio` slots **and** calls `stopPrimary()` iff `primary` is represented in the unified audio dock (`primary.audioOnly && !primary.controller.nativeFailed`), preserving any separate primary video tile. Used by chip ×, mixer ×, and `MiniPlayerOverlay` audio dock × / swipe-down.
3. **`stopAll()`**: tears down `primary` AND all `pinnedAudio`, clears all holds/tasks, clears `soloSlotID` and `isMutedAll`, clears Now Playing, and deactivates `PlaybackAudioSession` client state. Used by `AppShell.onDisappear` (sign-out / account switch).

### 3.4 Pin, Demote, Promote & Swipe-to-Pinned Transitions

**Strict invariant:** A channel may exist in **at most one** slot (`primary` XOR `pinnedAudio`).

| Transition | Preconditions & Rules |
|---|---|
| **`pinBackgroundAudio(_ channel, title:, profileImageURL:, stream:)`** | Requires `PlayerSettings.isNativePlaybackEnabled`. If `channel` is already in `pinnedAudio`: no-op. If `channel` is in `primary`: calls `demotePrimaryToPinnedAudio()` (refuses with `.atCapacity` if `pinnedAudio.count >= maxPinnedAudioSlots`, or `.nativeFailed` if `primary.controller.nativeFailed`). Otherwise if `pinnedAudio.count >= maxPinnedAudioSlots`: returns `.atCapacity` (UI shows inline cap feedback). Otherwise creates a headless native `audioOnly` `PlaybackSlot` (`allowsPictureInPicture: false`, `lastLiveStream = stream`), inherits any active `.clip` / `.feedPreview` hold, applies current Solo/Mute-All state (see 3.6), and appends to `pinnedAudio`. |
| **`demotePrimaryToPinnedAudio()`** | Requires `primary != nil`, `PlayerSettings.isNativePlaybackEnabled`, `!primary.controller.nativeFailed`, and `pinnedAudio.count < maxPinnedAudioSlots`. If `primary` is currently in PiP, sets `ignoreNextPiPClose = true`, stops PiP, and tears down its `AVPictureInPictureController`. Detaches `engine.view.removeFromSuperview()`, clears `primary = nil`, bumps `hostRevision += 1`. If `primary.engine?.kind == .native`, reuses the `PlaybackSlot` directly: sets `allowsPictureInPicture = false`, `audioOnly = true`, `promotedToNative = false`, calls `engine.setInteractive(false)` (detaches gestures, `hostView`, and PiP), unmutes programmatically if muted (unless `isMutedAll` or another slot is soloed), calls `engine.setAudioOnly(true, quality:)` for a gapless warm swap, and appends to `pinnedAudio`. If `primary.engine?.kind == .web`, tears down the web engine and builds a fresh headless native `audioOnly` slot in `pinnedAudio` (brief handoff) that inherits active center holds and Solo/Mute All state via the same helper as `pinBackgroundAudio`. Does **not** clear global `isExpanded`, so swiping next to another live channel immediately opens its video while this channel stays pinned. |
| **`promotePinnedToPrimary(channelId:, quality:)`** | Removes slot from `pinnedAudio`. Tears down any existing `primary` (`stopPrimary()` — never silently auto-pins the old primary). Writes `UserDefaults` `StreamHeaderView.expandedKey = true` and `PlayerSettings.audioOnlyKey = false` atomically so `StreamHeaderView` / `StreamPlaybackPolicy` agree immediately. Installs the slot as `primary` with `allowsPictureInPicture = true`, `audioOnly = false`, `lastNative = true`, `promotedToNative = true` (keeps it on `NativeStreamEngine` even when global `Native Video Player` preference is off), `lastQuality = quality`, calls `engine.setInteractive(true)` (restoring tap/swipe gestures, `controller.hostView`, and PiP eligibility), bumps `hostRevision += 1` so `PlayerHost` attaches its `view`, and calls `engine.setAudioOnly(false, quality:)` (warm swap into video). If the pinned slot was unloaded after a long pause (`engine == nil`), restores it directly in video mode. |
| **Swiping to a chat whose channel is in `pinnedAudio`** | `StreamPlaybackPolicy` checks `playing == .pinnedAudio` **before** checking `isExpanded && liveStream`. If an existing primary stream is in system PiP (`isPrimaryInPiP`), returns `.leaveAlone` (preserves PiP). Otherwise returns `.stopPrimary` (stops any previous primary video so nothing decodes invisibly off-screen or holds the screen awake). The pinned channel stays in `pinnedAudio` uninterrupted; `StreamHeaderView` collapses to 0pt and `ChatHeaderBar` stays visible in `.pinnedAudio` condensed mode with a 1-tap **Show Video** button (`promotePinnedToPrimary`) that works even when global `isExpanded` is already `true`. |
| **Explicit "Watch" from `ChannelPreviewMenu` on a pinned channel** | Calls `promotePinnedToPrimary` before opening the chat tab so the user lands directly on video without duplicating the engine. |

### 3.5 PiP Prohibition for Pinned Slots & Headless `NativeStreamEngine`

- Extend `StreamEngineRequest.native`:
  ```swift
  case native(login: String, audioOnly: Bool, quality: PlayerQuality, allowsPictureInPicture: Bool = true)
  ```
- When `allowsPictureInPicture == false`:
  - `NativeStreamEngine` skips gesture recognizers and `controller.hostView` assignment.
  - `NativePlayer.Coordinator.start` and `tryCommitStandby` do **not** create an `AVPictureInPictureController`.
- Add `setInteractive(_ interactive: Bool)` on `StreamEngine` / `NativeStreamEngine` / `NativePlayer.Coordinator`:
  - `false` (on demote): removes tap/swipe gestures, clears `controller.hostView`, stops any active PiP, and nils out `controller.pictureInPicture` + sets `canPictureInPicture = false`.
  - `true` (on promote): installs tap/swipe gestures, sets `controller.hostView = playerView`, and enables PiP creation on the incoming video swap (or immediately on `playerView.playerLayer`).

### 3.6 Volume, Deterministic Web Mute, Solo & Mute All

#### Volume & Web Mute
- `StreamPlayerController` adds:
  - `var volume: Float = 1.0` (observed, clamped `0.0...1.0`)
  - `func setVolume(_ volume: Float)` — sets `volume`, applies to `avPlayer?.volume`, clears `isMuted` if `volume > 0`, notifies `onAudioStateChange`.
  - `var isEffectivelyAudible: Bool { !isMuted && volume > 0 && !isPaused && !isHeld }`
- Every point in `NativePlayer.Coordinator` that creates or commits an `AVPlayer` (`start()` at line 295, `tryCommitStandby()` at line 604, and `mediaServicesWereReset()` rebuild) copies `player.volume = controller.volume`.
- Add `setMuted(muted)` to `TwitchWebPlayer.bridgeScript` (`window.chattrPlayer.setMuted = function(m) { var v = video(); if (v) { v.muted = !!m; report(); } }`) and update `StreamPlayerController.setMuted(_:)` to invoke `setMuted(true/false)` on `webView` when `avPlayer == nil` (mirroring `isMuted` immediately so UI and Solo/Mute All stay deterministic even while the page loads, and applying `startsMuted` on `noteEngineReady`).

#### Solo & Mute All Precedence (Single Snapshot Owner)
Only one global audio-focus mode may own a mute snapshot at a time (`AudioFocusMode: .none | .solo(slotID: UUID, savedMutes: [UUID: Bool]) | .mutedAll(savedMutes: [UUID: Bool])`):

| Action | Transition |
|---|---|
| **Tap Solo on slot X** (from `.none`) | Snapshot `isMuted` of all slots → enter `.solo(X, savedMutes)` → mute all slots ≠ X, unmute X (if X's volume was `0`, bump to `1.0`). |
| **Tap Solo on slot X** (already `.solo(X, _)`) | Restore `savedMutes` for every still-existing slot → `.none`. |
| **Tap Solo on slot Y** (while `.solo(X, savedMutes)`) | Keep original `savedMutes` → switch to `.solo(Y, savedMutes)` → mute all slots ≠ Y, unmute Y. |
| **Tap Solo on slot X** (while `.mutedAll(savedMutes)`) | Keep original `savedMutes` → switch to `.solo(X, savedMutes)` → unmute X only. |
| **Tap Mute All** (from `.none` or `.solo(_, savedMutes)`) | If `.none`, snapshot current mutes; if `.solo`, keep original `savedMutes` → enter `.mutedAll(savedMutes)` → mute every slot. |
| **Tap Mute All** (while `.mutedAll(savedMutes)`) | Restore `savedMutes` → `.none`. |
| **Manual unmute / volume > 0 on any slot** | Only user-initiated calls (programmatic mutes/volume bumps from Solo, Mute All, and new-slot initialization pass `programmatic: true` and do not trigger this exit) exit `.solo` or `.mutedAll` to `.none` immediately, keeping every slot's current mute state plus the user's manual unmute. |
| **New slot pinned or primary changed while in `.solo` / `.mutedAll`** | Starts muted (so it doesn't blast over the soloed stream or break Mute All) and records `savedMutes[newID] = false` so exiting Solo/Mute All unmutes it naturally. |
| **Soloed slot unpinned / stopped / fails** | Automatically restores `savedMutes` for all remaining slots and clears to `.none`. |

### 3.7 Unified `PlaybackAudioSession` Arbitration (Including Home Previews & WebKit)

`PlaybackAudioSession` becomes the single arbiter over registered `Sendable` client snapshots (still executing all `AVAudioSession` IPC serially off-main on its dedicated queue, with an injectable driver protocol for unit testing):

- **Clients:**
  - `.playback` — written by `PlaybackCenter.reconcileAudioSession()`
  - `.homePreview` — written by `HomeFeedPreviewController` (replacing its direct `activate` / `setMuted` / `deactivate` calls and its `playbackCenter?.isPlaying != true` guard!)
- **Client snapshot (`Sendable`):**
  - `hasActiveNative: Bool` (any native `AVPlayer` loaded or loading — paused or held slots still count as active while their `AVPlayer` exists; unloaded slots with `engine == nil` do not)
  - `hasAudibleNative: Bool` (any native slot with `isEffectivelyAudible == true`)
  - `hasAudibleWeb: Bool` (primary is `.web`, `!isMuted`, `!isPaused`, `!isHeld`)

#### Complete Aggregate Decision Table

| `hasActiveNative` (any client) | `hasAudibleNative` (any client) | `hasAudibleWeb` | Session action | Category / Options | Rationale |
|---|---|---|---|---|---|
| `false` | `false` | any | `deactivate(.notifyOthersOnDeactivation)` | — | No native players active; hand audio back to other apps. |
| `true` | `false` | any | Active | `.playback`, `.moviePlayback`, `[.mixWithOthers]` | All native streams are muted/vol=0/paused/held; never interrupts Spotify/podcasts or WebKit. |
| `true` | `true` | `false` | Active | `.playback`, `.moviePlayback`, `[]` (exclusive) | Native stream(s) audible with no unmuted web video (includes **all backgrounded states**); owns Lock Screen / Control Center Now Playing. |
| `true` | `true` | `true` | Active | `.playback`, `.moviePlayback`, `[.mixWithOthers]` | Unmuted `WKWebView` (foreground, or continuing in background system PiP) + audible native pinned audio coexist without fighting out-of-process WebKit. When the app backgrounds without WebKit PiP, `.background` hold pauses the web primary → `hasAudibleWeb` becomes `false` → session automatically transitions to exclusive `[]` so Lock Screen Now Playing takes over. While WebKit PiP is active in background, Lock Screen Now Playing yields to WebKit PiP and resumes automatically once PiP ends or pauses. |

- **`HighlightSoundPlayer` coexistence:** `HighlightSoundPlayer` intentionally stays outside this arbiter (it only sets `.ambient` when `AVAudioSession.sharedInstance().category != .playback`). Because `PlaybackAudioSession` always compares against the live `AVAudioSession.sharedInstance().category` rather than trusting a cached value, any external category change is immediately re-asserted on the next activation.

- **Pre-play activation:** `NativePlayer.Coordinator` calls an injected `onPrepareAudioSession: @MainActor () async -> Void` closure (provided by `PlaybackCenter`) before creating its `AVPlayer`, ensuring the category is configured through the single arbiter.
- **Re-asserting after WebKit state reports:** When `WebStreamEngine` posts play/pause/mute transitions, `PlaybackCenter` triggers `reconcileAudioSession()` so WebKit cannot leave the session in the wrong category.
- **Phase 1 on-device verification gate:** Verify unmuted `WebStreamEngine` + native pinned `AVPlayer` mixing on a physical iOS 26 device (and screen-lock transition). **Documented fallback if WebKit fights `.mixWithOthers`:** when pinning audio while a web primary is unmuted, either auto-mute the web primary (with a brief toast) or promote primary to native if `PlayerSettings.isNativePlaybackEnabled`.

### 3.8 Holds, Interruptions, Route Changes, Media Reset & Now Playing

1. **Per-slot holds & aggregate `PlaybackHold` token (`PlaybackCenter+Holds.swift`):**
   - `PlaybackHold` carries `id: UUID`, `reason: PlaybackHoldReason`, and `slotGenerations: [UUID: Int]`.
   - `PlaybackCenter` tracks active hold reasons (`activeCenterHolds: [PlaybackHoldReason: PlaybackHold]`) so slots added mid-hold (e.g., during `.clip` or `.feedPreview`) inherit the hold cleanly.
   - **`.clip` & `.feedPreview`:** hold **all** slots (`primary` + `pinnedAudio`), recording each slot's own `resumesOnRelease(slot.controller)` (preserving manual pauses!).
   - **`.background` (`PlaybackLifecycleObserver`):**
     - `primary`: same rules as today (video without PiP is held; unmuted native audio-only continues).
     - `pinnedAudio`: unmuted (`!isMuted && volume > 0`) continues in background; muted or volume-0 pinned slots are held so they don't burn battery/data silently.
     - Reconciled dynamically on mute/volume/Solo/unmute changes while `lifecycle.isInBackground == true`.
   - Release checks each slot's current `generation == slotGenerations[slot.id]`, ignoring unpinned/replaced slots without affecting surviving ones. Promote/demote preserves `slot.generation` (same as same-channel rebuild).
2. **Centralized system audio notifications (`PlaybackCenter+AudioSession.swift`):**
   - Remove per-coordinator `interruptionNotification`, `routeChangeNotification`, and `mediaServicesWereResetNotification` observers from `NativePlayer.Coordinator`; move them into `PlaybackCenter` once:
     - **Interruption `.began`:** record `slot.resumesAfterInterruption = slot.wasPlayingJustNow` (preserving the 2-second `pausedAt` grace window per slot).
     - **Interruption `.ended` (`.shouldResume`):** re-activate `PlaybackAudioSession` **once** (`force: true`), then resume every slot where `resumesAfterInterruption && slot.controller.startsPlaying`.
     - **Route change `.oldDeviceUnavailable` (headphones unplugged):** for every active native slot, if `!isMuted && volume > 0`, set `wantsPlayback = false` and pause; if muted/volume-0 and `wasPlayingJustNow`, keep playing.
     - **`mediaServicesWereResetNotification`:** call `PlaybackAudioSession.shared.invalidate()` **once**, then tell each active native slot to rebuild its player (preserving `volume`, `isMuted`, and `wantsPlayback`).
3. **Lock Screen / Control Center (`StreamNowPlaying.swift`):**
   - Remote command handlers resolve current eligible slots dynamically through `PlaybackCenter` (never capturing a stale `StreamPlayerController`).
   - Eligible slots: all `pinnedAudio` slots + `primary` (if `primary.audioOnly && primary.engineKind == .native`).
   - **0 eligible:** `clear()`.
   - **1 eligible:** identical to today (`title`, `channelDisplayName`).
   - **2+ eligible:** title = `"\(first.channel.channelDisplayName) + \(count - 1) more"`, artist = `"chattr · \(count) live streams"`, `playbackRate = anyPlaying ? 1.0 : 0.0`.
   - **Mixed-state remote commands:**
     - `playCommand` → plays **all** eligible slots (sets `wantsPlayback = true` and resumes any paused/unloaded slot).
     - `pauseCommand` → pauses **all** eligible slots (`wantsPlayback = false`).
     - `togglePlayPauseCommand` → if *any* eligible slot is playing, pauses all; if *all* are paused, plays all (never inverts mixed slots!).
4. **Offline polling & cleanup for pinned channels:**
   - Extend `ChatsScreen` / `AppShell`'s foreground status polling set to `openChannelIds ∪ pinnedChannelIds`, and pass the same union to `ChannelStatusStore.retainStreamState(forOpenChannels:)` so a channel pinned from Home (with no open chat tab) is neither pruned nor unpolled.
   - `ChannelStatusStore` updates invoke `PlaybackCenter.reconcilePinnedStatuses(statuses:follows:)`:
     - Uses each pinned slot's `lastLiveStream` (seeded at pin time) and two distinct `fetchedAt` timestamps (`offlineReadingConfirmed(at:)`). Missing entries or failed network refreshes are **never** treated as offline.
     - In background (polling paused), `AVPlayerItemDidPlayToEndTime` and `StreamPlaylistError.offline` immediately unpin the ended stream.
5. **Bandwidth & thermal note:**
   - With Twitch's `audio_only` rendition, 3 pinned streams total ~400–480 kbps. If Twitch omits `audio_only` and a channel falls back to `hiddenVideoPeakBitRate` (`400_000` bps), worst-case 3 fallback slots is ~1.2 Mbps; `PlaybackLimits.deviceIsConstrained` remains applied to every slot.

---

## 4. Observation Scoping & UI Performance

To protect `ChatScreen` / `ChatListView`'s 60+ fps firehose budget and avoid invalidating pre-mounted pager neighbours:

1. **Per-channel `ChannelPinnedAudioFlag`** (same refcounted pattern as `ChannelPictureInPictureFlag` in `PlaybackCenter.swift:142-231`):
   - `PlaybackCenter.pinnedAudioFlag(for channelId:)` / `retainPinnedAudioFlag(for:)` / `releasePinnedAudioFlag(for:)`.
   - `PlaybackCenter.stream(for:live:)` checks `primary` only (never scanning `pinnedAudio`) so pre-mounted headers do not register an observation dependency on `pinnedAudio`.
- A pin or unpin writes **at most one** channel flag — `StreamHeaderView`, `LandscapeStageLayout`, `ChatHeaderBar`, `OpenChatRow`, and `ChannelPreviewMenu` observe only their own channel's flag, never `playback.pinnedAudio`.
2. **Scoped `pinnedAudio` readers:**
   - Only `PinnedAudioStripView`, `PinnedAudioPillView`, `AudioMixerSheet`, `MiniPlayerOverlay`, and `MiniPlayerHost` observe `playback.pinnedAudio`.
   - `ChatScreen.body`, `ChatTranscript`, and `ChatPagerScreen` never read `pinnedAudio`, `primary`, or any slot's `volume`/`isMuted`.
   - Dragging a volume slider in `AudioMixerSheet` mutates only `slot.controller.volume`, re-rendering that single mixer row.

---

## 5. UI & Interaction Design

All multi-audio controls use iOS 26 Liquid Glass on the control/navigation layer only (`.regular` glass, `GlassEffectContainer` for adjacent glass controls; never glass on chat rows). All multi-audio chrome collapses to **0pt / hidden** when `pinnedAudio.isEmpty`.

### 5.1 Visibility Matrix Across App States

| App / Chat State | Video Surface | Pinned Audio Indicator | MiniPlayer Overlay |
|---|---|---|---|
| **Portrait chat — inline video active** | `StreamHeaderView` (16:9) | Setting `.strip` → `PinnedAudioStripView` directly below video (active page only). Setting `.floatingPill` → `PinnedAudioPillView` top-trailing over chat. | Hidden |
| **Landscape chat — stage active (beside or over video)** | `LandscapeStreamStage` | Always `PinnedAudioPillView` top-trailing in chat column (or stage corner), active page only. | Hidden |
| **Portrait/Landscape chat — collapsed, offline, primary audio-only, or active channel is pinned** | Hidden (0pt) | `ChatHeaderBar` stays visible; its transport pill shows live waveform + count (`〰️ N`) and opens `AudioMixerSheet` (plus 1-tap `🎥` Show Video on a live/pinned channel). | Hidden |
| **Outside chat (Home / Chats / Search) — primary video (not PiP) + pinned audio** | `MiniPlayerOverlay` corner-snapped video tile (lifted above audio dock) | `MiniPlayerOverlay` bottom Liquid Glass audio dock (`Ludwig + 1 more · Tap for mixer`) | Both visible |
| **Outside chat — primary video in system PiP + pinned audio** | System PiP window | `MiniPlayerOverlay` renders **only** the bottom Liquid Glass audio dock (video tile hidden independently of audio dock!) | Audio dock visible |
| **Outside chat — primary audio-only + pinned audio (or pinned audio only)** | None | Unified single bottom Liquid Glass audio dock merging primary audio-only + `pinnedAudio` (never two stacked docks). | Audio dock visible |

### 5.2 Entry Points (Accessible, Zero Nested Buttons)

1. **`ChatHeaderPopover`:**
   - Refactor each open-chat row (`ChatHeaderPopover.swift:180`) into an `HStack` of **sibling buttons**: leading channel-switch button + trailing pin/unpin button (`headphones` / active purple `headphones` + waveform) for live channels (when `PlayerSettings.isNativePlaybackEnabled`).
   - In the visible channel's details header, show a **Pin Audio** pill when live (or **Unpin Audio** when pinned).
2. **`StreamHeaderView` video overlay:**
   - Replace the single headphones `glyphButton` with a `Menu` (with a clear primary label and VoiceOver support — no hidden long-press-only actions):
     - **"Audio Only"** (switches current stream to audio-only as today)
     - **"Pin to Background Audio"** (demotes current stream to `pinnedAudio`; disabled with caption if 3/3 full)
     - **"Audio Mixer (N)"** (shown when `!pinnedAudio.isEmpty`; icon also shows a tiny accent badge with count `N`)
3. **`ChatHeaderBar`:**
   - Add `.pinnedAudio` case to `CondensedStreamMode` (`NowPlayingToolbarControl.swift`).
   - When the visible channel is in `pinnedAudio`: `ChatHeaderBar` stays visible (even if global `isExpanded == true`), showing the waveform + `🎥` Show Video (calls `promotePinnedToPrimary`) and context menu (*Mute/Unmute*, *Open Audio Mixer*, *Unpin Audio*).
   - When any `pinnedAudio` exists on a chat-only/offline/audio-only page: transport pill shows `〰️ N` (tapping opens `AudioMixerSheet`).
4. **`OpenChatRow` & `ChannelPreviewMenu`:**
   - Add **"Listen in Background"** / **"Stop Background Audio"** button in `ChannelPreviewMenu` (for live channels when `PlayerSettings.isNativePlaybackEnabled`) and swipe action on `OpenChatRow`.

### 5.3 `AudioMixerSheet` (`.presentationDetents([.medium, .large])`)

System Liquid Glass sheet (`NavigationStack` or standard `.sheet` with `.presentationDragIndicator(.visible)`):
- **Top bar:** `"Audio Mixer"` + **Mute All / Unmute All** button.
- **Watching (Primary) section** (when `primary != nil`):
  - Avatar, display name, `VIDEO` / `AUDIO` badge, mute toggle, **Pin** button (when live, native enabled, `!nativeFailed`, and room in `pinnedAudio`).
  - Volume `Slider(value:in:0...1)` when `primary.engineKind == .native` (accessible percentage label + Dynamic Type friendly stacking); omitted on `.web` with a subtle caption (`"Volume slider uses Native Video Player"`).
- **Background Audio (`N / 3`) section:**
  - Each pinned slot card: avatar, live dot, name, subtitle, **Solo** pill, **Mute**, **Video** (promotes & navigates to chat), **Unpin (`xmark`)**, and volume `Slider`.
- **Footer:** **"+ Add from Open Chats"** menu listing live open tabs not currently playing/pinned (shows `"Maximum 3 background streams"` when full).

### 5.4 Settings (`VideoDeviceSettingsScreen` & `SettingsRegistry`)

In `VideoDeviceSettingsScreen.swift` inside the **Video** section (lines 28–109):
- Add `Picker` bound to `@AppStorage(PlaybackPreferences.backgroundAudioIndicatorKey)` (`BackgroundAudioIndicatorStyle`: `.strip` `"Chip Strip"` default, `.floatingPill` `"Floating Pill"`):
  - Uses `SettingLabel("Background Audio Bar", systemImage: "headphones.circle", subtitle: backgroundAudioIndicator.subtitle, disabledReason: nativePlaybackEnabled ? nil : "Not available right now")`.
  - `.disabled(!nativePlaybackEnabled)`.
  - Update the Video section footer with one sentence noting that background audio streams require native playback and landscape always uses the compact floating pill.
- Add to `SettingsRegistry.entries`:
  ```swift
  SettingsEntry("backgroundAudioIndicator", "Background Audio Bar", keywords: ["multi", "audio", "mixer", "pill", "strip", "background", "pin"], in: .videoAndDevice),
  ```

---

## 6. Verification & Test Plan

### Unit Tests (`Packages/Features/Tests/FeaturesTests/`)
1. **`PlaybackCenterPinnedTests.swift` (new):**
   - Pin up to 3 channels; 4th returns `.atCapacity` without mutating existing slots.
   - Deduplication: pinning primary demotes it (native in-place warm swap, web rebuild, PiP stopped & view detached); pinning an already-pinned channel is a no-op; pinning a channel with `nativeFailed == true` is refused.
   - Promotion: promotes pinned slot to primary without duplicating, sets `allowsPictureInPicture = true`, stops old primary, restores unloaded slot if paused >10m.
   - Stop semantics: `stopPrimary()` preserves `pinnedAudio`; `unpinBackgroundAudio` preserves `primary`; `stopAll()` tears down every slot, cancels holds, clears Now Playing & audio session.
   - Solo & Mute All precedence: Solo A → Solo B, Solo → Mute All → Unmute All, manual unmute exiting Solo, unpinning soloed slot restoring remaining slots, new slot added during Solo starting muted.
   - Volume retention across `start()`, warm-swap commit, and media-services reset; volume `0` treated as inaudible for audio-session & background policy.
   - Deterministic `setMuted` on web primary + native slots.
   - Aggregate `PlaybackAudioSession` tests using a fake audio-session driver: every row of the Section 3.7 table including `HomeFeedPreviewController` coexistence and foreground/background transitions with web primary.
   - Multi-slot holds: `.clip` and `.feedPreview` hold all slots preserving manual pauses; `.background` holds primary video and muted pinned slots while keeping unmuted pinned slots playing; mid-hold pin inherits hold.
   - Mixed-state Lock Screen remote Play / Pause / Toggle commands.
   - Pinned offline confirmation (2 distinct timestamps, ignoring nil/failed readings) and `onStreamEnded` removing only the ended pinned slot.
   - Observation isolation: pinning/unpinning Channel B updates only `pinnedAudioFlag(for: B)` and does not mutate `pinnedAudioFlag(for: A)`.
2. **Existing test suites updated & passing:** `PlaybackCenterEngineTests`, `PlaybackCenterPolicyTests`, `PlaybackHoldIntentTests`, `StreamPlaybackPolicyTests`, `SettingsRegistryTests`.
3. **CI verification:** Full GitHub Actions CI (`package-tests`, `features-tests` on iOS Simulator, `accounts-tests`, `app-build` Debug, `app-build-release` Release).
4. **Physical-device TestFlight check:** Documented in `ci/WhatToTest.txt` (including unmuted Web primary + native pinned audio, screen lock with 2 pinned streams, headphones unplug, and Strip vs Floating Pill setting).
