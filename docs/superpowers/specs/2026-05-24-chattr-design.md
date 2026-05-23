# chattr — Design Spec

**Status:** approved — pending implementation plan
**Date:** 2026-05-24
**Author:** Andrew (with Claude)

## What this is

chattr is an iOS-native multi-chat client for Twitch. Multi-account, multi-channel, with first-class third-party emote support (7TV, BTTV, FFZ) and a Liquid Glass native look. MVP is chat-only and Twitch-only; the architecture reserves slots for stream playback, Kick, YouTube, iPad split-view, push notifications, mod tools, and per-emote sounds, all delivered post-MVP without architectural rework.

## Goals

- **Performant:** chat scrolls at 60+ fps even at peak (100+ msg/sec on popular streams)
- **Battery efficient:** sessions throttle when off-screen; no background polling; no proactive reconnect while suspended
- **Native:** Liquid Glass design language, iOS conventions for navigation/gestures, Dynamic Type & RTL support
- **Multi-account:** users can add multiple Twitch logins and switch between them

## Non-goals (MVP)

- Stream playback (HLS, picture-in-picture, audio session management)
- Other platforms (Kick, YouTube) — architecture supports them; implementation deferred
- Push notifications (no APNs entitlement in v1)
- Per-emote / per-channel notification sounds (Chatterino-style)
- Moderator actions (ban, timeout, delete others' messages)
- Client-side ignore/block list
- iPad-class layouts (app runs on iPad in scaled mode)
- Light theme polish (system follow + functional dark/light parity only)
- Browse top streams / category discovery

## Scope summary

| Dimension | MVP decision |
|---|---|
| Platforms | iOS phone-first; Twitch only |
| Player | Chat-only; stream-player slot reserved |
| Layout | Tabs/swipe — one channel visible at a time |
| Auth | Multi-account Twitch (multiple logins, switch between) |
| Emotes | Twitch native (from EventSub fragments) + 7TV + BTTV + FFZ |
| Sounds | Highlight sound on @-mention or matched keyword only |
| Channel join | Followed-channels list, search, manual entry |
| History on join | Backfill via `recent-messages.robotty.de` (graceful degradation) |
| Chat actions | Send, /me, replies, cross-source emote picker with search |
| Extra event rendering | Sub / resub / gift sub bubbles, raid bubbles, deletion/clear handling |
| Theming | Light + Dark + System (Liquid Glass) |

## Stack commitments

| Layer | Choice |
|---|---|
| iOS minimum | **26.0** |
| Swift | **6.2**, language mode 6 (strict concurrency) |
| Design language | Liquid Glass (`.glassEffect`, refreshed `Material`, new nav chrome) |
| UI framework | **SwiftUI shell + UIKit chat list** (`UICollectionView` + diffable data source, cells via `UIHostingConfiguration`) |
| Concurrency | Swift Concurrency — `actor` for stateful clients/sessions, `Sendable struct` for stateless, `AsyncStream` for event delivery |
| State observation | `@Observable` view models |
| OAuth | `ASWebAuthenticationSession`; tokens persisted via injectable `TokenStore` (default `KeychainTokenStore(identifier:)`) |
| Image / emote loading | **Nuke** (animated WebP for 7TV, async/await API) |
| Persistence | SwiftData (accounts, joined channels, highlight keywords, settings); in-memory `RingBuffer<ChatLine>` (~500/channel) for messages |
| Logging | `os.Logger` per package |
| Testing | Swift Testing (units), `swift-snapshot-testing` (cells), `URLProtocol` stubs (network), XCUITest (3–5 smoke flows) |
| CI | Xcode Cloud |
| Twitch protocol source | External package **`TwitchKit`** at `~/Dev/twitch-kit/`, shared with Streamly |

## Repository & module layout

```
~/Dev/twitch-kit/                      ← shared, own git repo (extracted from Streamly)
  Package.swift                          (iOS 26, Swift 6.2)
  Sources/TwitchKit/
    Auth/        TwitchAuth (TokenStore-pluggable)
                 TokenStore protocol, KeychainTokenStore, InMemoryTokenStore
    API/         HelixClient (+ viewer endpoints)
    EventSub/    EventSubClient (+ extended events)
    Models/      ChatMessage, ChatFragment, Reply, Badge, Subscription, Raid, MessageDelete, ChatClear, ...
    Scopes       (namespace with constants)

~/Dev/chattr/                          ← this project
  chattr.xcodeproj
  App/                                 thin @main + DI wiring
  Packages/
    Core/                              shared types, errors, logging, RingBuffer, debouncers
    DesignSystem/                      Liquid Glass tokens, typography, reusable views
    EmoteSources/                      7TV/BTTV/FFZ providers + EmoteIndex actor
    ChatModel/                         ChatLine, LineRun, Normalizer (EventSub→ChatLine, IRC-tag→ChatLine)
    Accounts/                          Account (SwiftData), AccountStore actor, OAuthFlow
    Channels/                          JoinedChannel (SwiftData), ChannelSession actor, ChannelSessionRegistry, backfill provider
    ChatUI/                            ChatListView (UIKit-backed), MessageRowView, SendComposer, EmotePicker, ChatBubble
    Features/                          SwiftUI screens: ChannelListScreen, AccountSwitcherScreen, AddChannelScreen, SettingsScreen, HighlightKeywordsScreen
```

### Dependency direction

```
       Features ───────► ChatUI
          │   │           │  │
          ▼   ▼           ▼  ▼
       Accounts ◄──── Channels ───► ChatModel ───► EmoteSources
          │              │              │              │
          ▼              ▼              ▼              ▼
                     TwitchKit (external)
                              │
                          DesignSystem  ◄────── ChatUI, Features (also)
                              │
                            Core
```

ChatUI also depends directly on DesignSystem (for Liquid Glass tokens) and ChatModel (for `ChatLine`/`LineRun`); Features depends on DesignSystem, Accounts, Channels, and TwitchKit. The diagram shows primary direction; SPM enforces the full graph.

SPM enforces no circular dependencies. Modules don't depend on anything above them.

## Component responsibilities

### `Core`

Shared primitives. Owns: `AppError`, logger subsystem constants, `RingBuffer<T>`, debouncer/throttler helpers, result-type helpers. Depends on Foundation only.

### `DesignSystem`

Liquid Glass visual identity. Owns: `Color.brand*`, `Material.appGlass`, `Typography` (Dynamic Type-aware), reusable views (`GlassCard`, `Pill`, `BadgeView`). Depends on SwiftUI.

### `TwitchKit` (external, `~/Dev/twitch-kit/`)

Twitch protocol surface. Public API:

- `TwitchClient(clientId:clientSecret:scopes:tokenStore:isLive:)` — Sendable facade
- `TwitchAuth` actor — `login(...)`, `logout()`, `accessToken()`, `refreshIfNeeded()`
- `HelixClient` struct — typed methods: `getUser(login:|id:)`, `getFollowedChannels(userId:after:)`, `sendChatMessage(broadcasterId:senderId:message:replyParentMessageId:)`, `searchChannels(query:liveOnly:)`, `getStreams(...)`, `getChannelBadges(broadcasterId:)`, `getGlobalBadges()`, `createEventSubSubscription(...)`, `deleteEventSubSubscription(id:)`, `listEventSubSubscriptions()`
- `EventSubClient` actor — `connect()`, `disconnect()`, `subscribe(type:version:condition:) -> String`, `nonisolated let events: AsyncStream<EventSubEvent>`
- Models: `ChatMessage` (with `fragments` per EventSub v1), `ChatFragment` (`text` / `emote` / `cheermote` / `mention`), `EmoteReference`, `Cheer`, `Reply`, `Badge`, `Subscription`, `GiftSubscription`, `Raid`, `MessageDelete`, `ChatClear`
- `protocol TokenStore: Sendable` — `loadAccessToken() async throws -> String?`, `loadRefreshToken() async throws -> String?`, `save(accessToken:refreshToken:) async throws`, `clear() async throws`
- `KeychainTokenStore(identifier:accessGroup:)` — default implementation, keys Keychain entries by `identifier`
- `InMemoryTokenStore` — for tests
- `Scopes` namespace — viewer scopes (`user:read:chat`, `user:write:chat`, `user:read:follows`) and streamer scopes (used by Streamly)

### `EmoteSources`

Third-party emote providers and unified resolution. Public API:

- `protocol EmoteProvider` — `globalEmotes() async throws -> [Emote]`, `channelEmotes(channelId:) async throws -> [Emote]`
- `SevenTVProvider`, `BTTVProvider`, `FFZProvider` implementations
- `SevenTVRealtimeClient` — WebSocket for emote-set updates
- `Emote` struct — `id`, `name`, `urls: [Size: URL]`, `formats: [ImageFormat]`, `isAnimated`, `isZeroWidth`, `source: EmoteSource`, `ownerChannelId: String?`
- `EmoteIndex` actor — per-channel resolver; `resolve(name: String) -> Emote?`; `updateEmotes(_:)`, `updateBadges(_:)`; emits change notifications via `AsyncStream<Void>` when re-resolution is needed

### `ChatModel`

Display-ready message model + normalization. Public API:

- `ChatLine` — `id`, `kind` (`.message` | `.subBubble(Subscription)` | `.giftSubBubble(GiftSubscription)` | `.raidBubble(Raid)` | `.deletedPlaceholder`), `authorBadges`, `authorDisplayName`, `authorColor`, `runs: [LineRun]`, `isHighlighted`, `replyContext: ReplyContext?`, `timestamp`, `status: MessageStatus` (`.live` | `.historical` | `.sending` | `.sent` | `.failed(Error)` | `.deleted`), `rawFragments: [ChatFragment]` (kept for re-normalization)
- `LineRun` enum — `.text(String)`, `.emote(Emote)`, `.mention(login: String, isMe: Bool)`, `.url(String)`, `.cheermote(prefix: String, bits: Int, tier: Int)`
- `Normalizer` — `normalize(_:TwitchKit.ChatMessage, with: EmoteIndex, currentUserLogin:, highlightKeywords:) -> ChatLine` and a backfill variant for IRC-tag input

### `Accounts`

Local multi-account state. Public API:

- `Account` SwiftData model — `id` (Twitch user_id), `login`, `displayName`, `profileImageURL`, `tokenStoreIdentifier`, `needsReauth: Bool`, `addedAt: Date`
- `AccountStore` actor — `add(via: OAuthFlow) async throws -> Account`, `remove(_:)`, `accounts: [Account]`, `activeAccount: Account?`, `setActive(_:)`. Persists via SwiftData. Constructs per-account `TwitchClient` lazily, caches them.
- `OAuthFlow` — `ASWebAuthenticationSession` wrapper; returns code → exchanges via `TwitchAuth`

### `Channels`

Chat session lifecycle. Public API:

- `JoinedChannel` SwiftData model — `channelId`, `accountId`, `loginName`, `displayName`, `joinedAt`
- `ChannelSession` actor — one per `(accountId, channelId)` pair
  - `start()` — establishes EventSub subscriptions (hot path); fires backfill, badges, emote-set fetches in parallel (decoration)
  - `stop()` — deletes subscriptions, cancels in-flight tasks, clears buffer
  - `pause()` / `resume()` — suspend snapshot emission while off-screen
  - `send(text:replyTo:) -> ChatLine.ID` — **synchronous from the caller's perspective**: appends an optimistic `ChatLine(status: .sending)` to the buffer, emits a snapshot, and returns the `localId` immediately. The HTTP call to Helix runs in a session-owned detached Task; success/failure mutates the line's status in place and propagates via the `lines` stream. Callers never `await` network latency.
  - `nonisolated let lines: AsyncStream<[ChatLine]>` — snapshots, coalesced ~15ms
  - On every incoming `ChatLine` with `isHighlighted == true && status == .live`: call `HighlightSoundPlayer.play()` (gated by `SettingsStore.highlightSoundEnabled`). Sound is not played for `.historical` (backfilled) or `.sent` (own-echoed) lines.
  - Internal: `RingBuffer<ChatLine>` (cap 500), in-flight subscription IDs, local-to-server msgId map for dedup, `HighlightSoundPlayer` instance
- `ChannelSessionRegistry` actor — `join(login:account:)`, `leave(channelId:)`, `session(for:account:)`, observes scene phase
- `BackfillProvider` protocol — `fetch(channelLogin:limit:) async throws -> [TwitchKit.ChatMessage]`; default impl hits `recent-messages.robotty.de`; graceful failure
- `HighlightSoundPlayer` — thin `AVAudioPlayer` wrapper with `AVAudioSession.Category.ambient` (mixes with other audio, doesn't take over). Ships with a single default sound asset bundled in `Core`; per-keyword sounds are post-MVP. Throttled to one play per 500ms to avoid stutter on burst highlights.

### `ChatUI`

The chat screen. Key views:

- `ChatScreen` (SwiftUI) — channel header + `ChatListView` + scroll-to-bottom pill + `SendComposer`
- `ChatListView` (SwiftUI → `UIViewControllerRepresentable` → `UICollectionView` + `UICollectionViewDiffableDataSource<Section, ChatLine.ID>`)
- `MessageRowView` (SwiftUI, inside `UIHostingConfiguration`) — renders `ChatLine.runs` + badges + author
- `InlineEmoteView` (SwiftUI) — Nuke-backed; supports animated WebP and zero-width overlays
- `SendComposer` (SwiftUI) — text field + emote picker button + send button + reply chip
- `EmotePicker` (SwiftUI) — sectioned grid (Twitch / 7TV / BTTV / FFZ / channel-only) + search
- `ChatBubble` (SwiftUI) — sub / gift sub / raid bubbles inline in chat

Stick-to-bottom: track `isUserScrolledUp`; if false, scroll to bottom on snapshot; if true, increment unread count and show pill. Snapshot apply uses `animatingDifferences: false` for high-freq message stream; bubbles applied as separate animated snapshot.

### `Features`

Composition screens: `ChannelListScreen`, `AccountSwitcherScreen`, `AddChannelScreen` (search tab + manual tab), `SettingsScreen`, `HighlightKeywordsScreen`. SwiftUI only.

### `App`

Thin entry point: `chattrApp: App` with DI containers — `AccountStore`, `ChannelSessionRegistry`, `EmoteIndex` factory.

## Data flows

### Inbound: EventSub byte → screen pixel

1. URLSession receives WebSocket frame
2. `EventSubClient` (actor) decodes envelope; routes by `messageType`
   - `session_keepalive` → reset timer
   - `session_reconnect` → re-dial new URL, swap sockets, do not re-subscribe
   - `notification` → continue
3. Parse payload → `EventSubEvent.chatMessage(ChatMessage)` → yield on `events` stream
4. `ChannelSession` (actor) filters events for its `(accountId, channelId)`; calls `Normalizer`
5. `Normalizer`: walks `fragments`, tokenizes `.text` fragments, looks up tokens in `EmoteIndex`, substitutes 7TV/BTTV/FFZ emotes, resolves mentions (incl. self-detection), computes highlight, builds `ChatLine` with `runs` + `rawFragments` retained
6. Append to ring buffer; debounced coalescer schedules a snapshot emit
7. Coalesced snapshot emitted on `lines: AsyncStream<[ChatLine]>` (~15ms / one display refresh)
8. `ChatListView` `applySnapshot(_:)` → diffable data source diffs → `UICollectionView` insert
9. `UIHostingConfiguration` cell renders `MessageRowView(line:)`
10. Stick-to-bottom controller decides: scroll to bottom or show pill

Performance notes: `animatingDifferences: false` on chat message snapshots; badges + top-50 emotes prefetched via Nuke at channel join; off-screen sessions' snapshot emission paused.

### Outbound: tap → Helix

1. User types in `SendComposer`; taps Send
2. `ChannelSession.send(text:replyTo:) -> ChatLine.ID`:
   - Generates `localId`
   - Appends optimistic `ChatLine(id: localId, status: .sending)` to ring buffer; emits snapshot
   - **Returns `localId` to the caller immediately** (no await on network)
   - Spawns a session-owned detached Task that calls `HelixClient.sendChatMessage(...)`
3. UI receives the snapshot in the next coalesce tick (~15ms) and renders the greyed sending row
4. Task resolves:
   - On 200: map `localId → serverMsgId` in the session's dedup table; mutate the line `status = .sent`; emit snapshot
   - On 400/403/422: mutate the line `status = .failed(error)`; emit snapshot; UI shows red retry affordance and surfaces Helix error text in composer
5. EventSub echoes the message (50–200ms later): `ChannelSession.ingest` finds the mapped local line by serverMsgId; replaces in place (same `localId`, server-derived fields filled in); no duplicate row

### Channel join: tap → live chat

1. User taps "Join #xqc" in `AddChannelScreen`
2. `ChannelSessionRegistry.join(login:account:)`:
   - `getUser(login:)` → broadcaster id
   - Persist `JoinedChannel` via SwiftData
   - Construct `ChannelSession`; `session.start()`
3. `ChannelSession.start()`:
   - **Hot path** (blocking live-messages state): connect EventSub if needed; subscribe in parallel to `channel.chat.message`, `.notification`, `.message_delete`, `.clear`, `.raid`; store sub IDs
   - **Background decoration** (non-blocking):
     - Backfill from `recent-messages.robotty.de` (150 msgs), normalize with whatever index has, insert by timestamp, dedup by msgId, mark `.historical`
     - Fetch channel badges → update `EmoteIndex`, trigger re-normalize of buffer (cell content reload)
     - Fetch 7TV + BTTV + FFZ channel emote sets in parallel → update `EmoteIndex`, trigger re-normalize
4. Live messages flow as in inbound flow (using whatever index has at the time of receipt)
5. `reNormalizeBuffer()` runs whenever `EmoteIndex` updates: re-walks each line's `rawFragments`, replaces `ChatLine.runs`, emits snapshot; diffable applies as content-only reload (no insertions)

## Error handling & resilience

### EventSub WebSocket failures

| Failure | Response |
|---|---|
| `session_reconnect` | Dial new URL, swap socket, **do not** re-subscribe (server preserves them) |
| `session_keepalive` timeout (N+5s) | Treat as abnormal close → reconnect loop |
| Abnormal close / I/O error | Mark socket dead → reconnect loop |
| `NWPathMonitor.status == .unsatisfied` | Pause attempts; immediate attempt on `.satisfied` |

Reconnect backoff (per Streamly's pattern):

```swift
let live = await isLive()
let maxAttempts = live ? .max : 5
let baseDelay   = live ? 0.5 : 1.0
let maxDelay    = live ? 5.0 : 30.0
// delay = min(base * 2^(attempt-1), maxDelay)
```

For chattr, `isLive` resolves to "any joined channel currently visible in the UI?" On reconnect: re-subscribe every active session's event types (parallel HTTP, typically <500ms total).

### Helix HTTP failures

`HelixClient` wraps every request with:

| Status | Response |
|---|---|
| 200 / 202 | Decode and return |
| 401 | `auth.refreshIfNeeded()` + retry once; if still 401, `.notAuthenticated` (account → `.needsReauth`) |
| 403 | `HelixError.forbidden(message)` — surface Twitch text verbatim |
| 404 | `.notFound` |
| 429 | Respect `Retry-After`; retry up to 3 |
| 5xx | Exponential backoff (1, 2, 4) then throw |
| 422 `msg_duplicate` (send only) | No retry; surface "duplicate message" in composer |
| Network error | Throw `.networkError`; caller decides (decorative endpoints fail silently) |

### OAuth refresh failures

When refresh token itself is invalid: `TwitchAuth` throws `.refreshFailed`; `AccountStore` flags `account.needsReauth = true`, clears its `TokenStore`; UI shows persistent banner with one-tap re-auth CTA. Account dimmed in switcher; sessions paused until resolved.

### Backfill service unavailable

Timeout / 5xx / malformed: abandon silently, log, channel still joins. Graceful degradation — no user-visible error.

### Emote provider failures

Per-provider isolated via `withTaskGroup { addTask { try? await provider.fetch() ?? [] } }`. Failed provider contributes nothing; others still populate `EmoteIndex`. No tight-loop retry; retry on next channel join.

### Network transitions

`NWPathMonitor` observed:
- `.unsatisfied` → all sessions suspended; pause reconnect
- `.satisfied` after `.unsatisfied` → immediate reconnect on each session
- Wi-Fi ↔ cellular → no proactive disconnect; let the existing connection live or die naturally
- Low Data Mode → logged; v1 no behavior change (post-MVP: smaller emote sizes, no animated WebP)

### App lifecycle

| Phase | Behavior |
|---|---|
| Active (foreground, visible channel) | Full speed |
| Inactive (foreground, channel off-screen / swipe in transit) | Snapshot emission paused; WebSocket and buffer stay live |
| Background — first ~10–15s | UI subscriptions paused; **WebSocket stays open** (covers quick app switches) |
| Background — longer | Twitch's keepalive timeout closes our session server-side; we don't attempt to reconnect while backgrounded |
| Suspended (after ≤30s) | All sockets dead; SwiftData + `EmoteIndex` stay in memory until jetsamed |
| Resumed (foreground after background) | For each visible session: reconnect if dead → re-subscribe. If gap > 60s: trigger backfill again to fill the missing window |
| Cold start | Restore `Account` + `JoinedChannel` sets; tokens from Keychain; **lazily** start sessions only for the channel the user lands on; neighbors pre-warm on swipe |

### Subscription quota & zombie cleanup

On cold start per account: `GET /eventsub/subscriptions` → reconcile against `JoinedChannel` set in SwiftData → `DELETE` mismatches. Per session: explicit `DELETE` of `activeSubscriptionIds` in `stop()`. If subscribe ever returns "subscription limit reached": spawn a second WebSocket for that account (architecture supports it; public surface unchanged).

### User-visible error states

| State | Trigger | Presentation |
|---|---|---|
| Transient banner | Reconnect, backfill fail, single Helix retry | Pill at top of channel header — "Reconnecting…" / "Live again" / auto-dismisses |
| Account banner | OAuth refresh failed | Persistent banner — "Re-sign in to @user" with one-tap CTA |
| Inline replace | Channel unavailable, banned, follower-only-and-not-following | Replaces send composer — "You can't send here: \<Twitch's text\>" |

No modal alerts. No system progress views.

## Testing

### Frameworks

Swift Testing for units, `swift-snapshot-testing` for cells, `URLProtocol` stubs for network, XCUITest for 3–5 critical paths.

### Coverage by module

| Module | Coverage |
|---|---|
| `TwitchKit` | High — EventSub envelope decode (per real-Twitch JSON fixtures, parameterized), `ChatMessage` edge cases (text-only, mixed fragments, cheermotes, replies, shared chat), `HelixClient` retry ladder (401-retry, 429 Retry-After, 5xx backoff), `TwitchAuth` refresh paths, reconnect strategy with injected fake clock + socket factory, `KeychainTokenStore` round-trip |
| `EmoteSources` | High — per-provider JSON fixture decoders, `EmoteIndex.resolve` collision precedence (channel > global; Twitch > 7TV > BTTV > FFZ), 7TV WebSocket update integration |
| `ChatModel.Normalizer` | Highest — `@Test(arguments:)` parameterized over fixtures covering plain text, Twitch emote, 7TV emote in text fragment, zero-width 7TV stack, mention self, URL linkification, cheermote splitting, reply context, empty fragments, all-emote messages, highlight on keyword |
| `Channels.ChannelSession` | High — backfill + live merge with dedup, ring buffer cap, snapshot coalescing (30 msgs in 15ms → 1 emit), message_delete handling, chat_clear handling, optimistic send + echo dedup, re-normalize-on-index-update preserves IDs |
| `Accounts.AccountStore` | High — in-memory SwiftData, multi-account isolation, `needsReauth` flow |
| `ChatUI` | Selective — `MessageRowView` snapshot tests (light/dark/Dynamic Type Large/RTL/all variants), stick-to-bottom logic, diff application correctness |
| `Features`, `App` | Low — composition; snapshot tests of default/loading/empty/error states |

### Performance gates

- **Chat list scroll @ 100 msg/sec for 30s:** assert dropped frames < 5/3600 (CI gate)
- **Memory soak @ 200 msg/sec for 50s:** assert `bufferCount <= 500`; manual Instruments run for leak check

### What we don't test

- Twitch's API behavior itself
- `URLSession` networking primitives
- SwiftUI's view rendering (Apple's responsibility)
- `recent-messages.robotty.de` uptime
- 7TV WebSocket protocol compliance

### CI (Xcode Cloud)

- PR / branch push: build chattr + TwitchKit, run all unit + snapshot tests, lint (SwiftFormat check)
- Merge to main: above + perf suite
- Tag push: above + XCUITest smoke suite + Release archive + TestFlight upload

## Future-proofing

| Future feature | How the architecture handles it |
|---|---|
| Kick chat | Sibling shared package `~/Dev/kick-kit/`; new chattr-side adapter; same `ChatLine` model downstream. `protocol ChatPlatform` introduced when second platform lands (not designed upfront) |
| YouTube live chat | HTTP-polling `ChannelSession` variant; same downstream pipeline |
| Stream playback | New `StreamPlayer` package (AVPlayer wrapper, HLS, PiP). `ChatScreen` becomes `ChannelScreen` containing player + chat. Navigation slot already reserved in `App/`. |
| Moderator actions | `HelixClient` gets `banUser`, `timeoutUser`, `deleteMessage`, `clearChat`. `ChatUI` long-press menu becomes context-aware on `account.isModerator(in:)`. ~few hundred lines, no architectural change. |
| Per-emote sounds (Chatterino-style) | `Normalizer` already detects emote runs; add `SoundTriggerRule` lookup + `AVAudioPlayer`. Settings UI in `Features/`. |
| Push notifications (go-live) | `channel.online` EventSub event triggers local notification. APNs entitlement needed only for "fire while suspended"; foreground-only works with existing stream. |
| iPad split-view | `Features/` gains `iPadRootView` hosting multiple `ChatScreen`s in `NavigationSplitView`. Registry already supports multiple visible sessions. |

## Phase 0 — work order before chattr UI work begins

This runs on `~/Dev/Streamly` and the new `~/Dev/twitch-kit/`; none of it ships chattr functionality, but chattr depends on the completion of Phase 0.5 (or pinning to `main` of twitch-kit).

### Phase 0.1 — Extract TwitchKit to its own repo
- Create `~/Dev/twitch-kit/` as new git repo (`git init`, README, LICENSE)
- Copy `Streamly/Packages/TwitchKit/` into it; first commit
- Update Streamly's xcodeproj to depend on `../../twitch-kit` via local SPM path
- Delete `Streamly/Packages/TwitchKit/`
- Verify Streamly builds + tests pass
- Streamly commit: "TwitchKit extracted; consumes from sibling repo"

### Phase 0.2 — Introduce `TokenStore` protocol (back-compat)
- Add `protocol TokenStore`, `KeychainTokenStore(identifier:)`, `InMemoryTokenStore` to TwitchKit
- Refactor `TwitchAuth` to take `tokenStore: TokenStore` instead of hardcoded Keychain keys
- Keep old `TwitchAuth()` initializer working as an alias (internally constructs `KeychainTokenStore(identifier: "default")`) — Streamly continues to build
- Migrate Streamly to new initializer with explicit identifier `"streamly"`
- Add unit tests: protocol contract, KeychainTokenStore round-trip, InMemoryTokenStore usage
- TwitchKit commit: "TwitchAuth: pluggable TokenStore"

### Phase 0.3 — Add viewer-side scopes + Helix endpoints
- `TwitchAuth.init` accepts `scopes: [String]`
- `TwitchKit.Scopes` namespace with constants
- Streamly passes its streamer scopes explicitly
- `HelixClient` gains: `sendChatMessage`, `searchChannels`, `getFollowedChannels`, `getChannelBadges`, `getGlobalBadges`, `getUser(login:|id:)`
- Fixture-based unit tests per endpoint
- TwitchKit commit: "Helix: viewer endpoints + explicit scopes"

### Phase 0.4 — Extend EventSub events
- `EventSubClient.parseEvent` adds handling for `channel.chat.notification`, `channel.chat.message_delete`, `channel.chat.clear`, `channel.raid`
- Typed models per event
- Captured-from-prod JSON fixture tests per event type
- TwitchKit commit: "EventSub: viewer-side chat event types"

### Phase 0.5 — Cleanup & tag
- README in twitch-kit (module overview, scope list, fixture sources)
- CHANGELOG entry
- Tag `v0.1.0`
- Streamly tags its commit consuming `v0.1.0`

Estimated effort: 2–3 focused work sessions. chattr scaffolding begins after this.

## Open questions (not design-blocking)

| Item | Decide before |
|---|---|
| Twitch developer app registration (separate from Streamly's; distinct client_id) | First OAuth flow runs in chattr |
| Bundle identifier (`com.<handle>.chattr`) | First device build |
| Apple Developer Program enrollment | First device build / TestFlight |
| Liquid Glass accent color (Twitch purple is taken; consider distinguishable accent) | First `DesignSystem` polish pass |
| App icon (1024×1024 source) | TestFlight upload |
| Crash reporting (Crashlytics / Sentry / App Store Connect only) | First TestFlight |
| Analytics (default: none in MVP) | App Store submission |

## Glossary

- **EventSub**: Twitch's modern event delivery system (WebSocket transport for our case). Replaces legacy IRC for chat.
- **Helix**: Twitch's REST API. Used for non-event work (auth, sends, searches, user info, badges).
- **7TV / BTTV / FFZ**: third-party emote ecosystems with their own APIs and image hosts.
- **`recent-messages.robotty.de`**: community-hosted IRC-tag-format buffer of recent chat per channel; used for join-time backfill.
- **Zero-width emote**: 7TV concept — an overlay emote that renders *on top of* the previous emote (e.g., `Kappa wide` overlays a "wide" filter on `Kappa`).
- **Shared chat**: a Twitch feature where multiple channels can share a chat window; EventSub messages carry `source_*` fields when applicable.
- **Liquid Glass**: iOS 26's design language — translucent layered materials with refreshed control affordances.
