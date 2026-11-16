# chattr

An iOS-native, multi-chat client for Twitch. chattr lets you follow several
channels' chat at once, signed in with one or more Twitch accounts, with
first-class third-party emote support (7TV, BTTV, FFZ) and a native Liquid
Glass look.

The MVP is **chat-only and Twitch-only**. The architecture deliberately reserves
seams for stream playback, other platforms (Kick, YouTube), push notifications,
moderation tools, and iPad split-view — all deliverable later without rework.

## Highlights

- **Multi-account** — add multiple Twitch logins and switch between them.
- **Multi-channel** — tab/swipe between joined channels, one visible at a time.
- **Third-party emotes** — Twitch native emotes plus 7TV, BTTV, and FFZ,
  including animated WebP and zero-width overlays.
- **Live + history** — EventSub-driven live chat with join-time backfill via
  `recent-messages.robotty.de` (degrades gracefully when unavailable).
- **Rich events** — sub / resub / gift-sub and raid bubbles, plus message
  deletion and chat-clear handling.
- **Highlights** — a sound and visual treatment when you're @-mentioned or a
  keyword you chose appears.
- **Native feel** — Liquid Glass design language, Dynamic Type, light/dark/system
  themes, and a `UICollectionView`-backed chat list that holds 60+ fps under a
  100+ msg/sec firehose.

## Requirements

| | |
|---|---|
| Xcode | 26 or newer |
| iOS deployment target | **26.0** |
| Swift | 6 (strict concurrency) |
| Accounts | A Twitch account to sign in; a registered Twitch developer app to build your own client ID (see below) |

## Getting started

```sh
git clone https://github.com/WhoTookLandy/chattr.git
cd chattr
open chattr.xcodeproj
```

Build and run the **chattr** scheme on an iOS 26 simulator or device.
Swift Package Manager resolves all dependencies on first build — no extra setup.

### Twitch client ID

The app authenticates with Twitch via OAuth (authorization-code flow with PKCE,
handled by TwitchKit), so **no client secret is required or stored**. The public
client ID lives in [`chattr/chattrApp.swift`](chattr/chattrApp.swift). To run
against your own Twitch developer app, register one at
[dev.twitch.tv](https://dev.twitch.tv) and replace `chattrApp.clientId`.

### UI preview harness

A debug-only design-review harness boots the tab shell with mock data and no
sign-in. Launch the **chattr** scheme with the `-uiPreview` argument (already
wired into the shared scheme's options) to inspect screens without a live
account.

## Architecture

chattr is a thin `@main` shell over a strict, downward-pointing DAG of local
Swift packages under [`Packages/`](Packages). A dependency edge must never point
*up* this list:

```
Core   DesignSystem            ← leaves: zero internal deps
  ↑
EmoteSources   Accounts            ← depend on Core (DesignSystem is used only by Features)
  ↑
ChatModel                          ← depends on EmoteSources
  ↑
Channels                           ← depends on Accounts, EmoteSources, ChatModel
  ↑
Features                           ← all SwiftUI lives here; depends on everything below
  ↑
chattr app target                  ← composition root + DI wiring only
```

| Package | Responsibility |
|---|---|
| **Core** | Cross-cutting primitives: `AppError`, logging, `Endpoints`, JSON disk cache, channel/platform descriptors, session-activity signal. Foundation + `os` only. |
| **DesignSystem** | Liquid Glass visual identity — color, typography, appearance tokens, reusable views. |
| **EmoteSources** | 7TV / BTTV / FFZ providers and the per-channel `EmoteIndex` actor. |
| **ChatModel** | Display-ready `ChatLine` / `LineRun` model and the `Normalizer` (EventSub & IRC-tag → `ChatLine`). |
| **Accounts** | Multi-account state — `Account` (SwiftData), `AccountStore`, OAuth flow. |
| **Channels** | Chat-session lifecycle — `ChannelSession` actor (normalizes each message once and owns the per-channel ring of display-ready rows), `ChannelSessionRegistry`, off-main event routing, badge lookup, backfill, optimistic send. |
| **Features** | Every SwiftUI screen, grouped by feature folder (`Home`, `Chat`, `Channels`, `Emotes`, `Highlights`, `Filters`, `Settings`, `Tabs`, `App`, `Shared`). |

### External dependencies

- **[TwitchKit](https://github.com/AndrewBeshay/TwitchKit)** — the Twitch
  protocol surface (Auth, Helix, EventSub, models), shared with the sibling app
  Streamly. Pinned to an **exact** version across every `Package.swift`.
- **[Nuke](https://github.com/kean/Nuke)** — image/emote loading (animated WebP,
  async/await API), used only in `Features`.

### Data flow, in one breath

EventSub WebSocket frame → `EventSubClient` decodes → the account's dispatcher
(a detached task, never the main actor) hands it to `ChannelEventRouter`, which
drops it into the owning `ChannelSession`'s inbox without waiting → the session
translates it and runs the `Normalizer` **once per channel, off-main** (word
tokens, emotes, self-mentions; timestamps and row ids minted once) → ring
buffer of display-ready rows (cap = Chat History setting) → posted to each
subscriber's mailbox (the session never waits on a subscriber) →
`ChatTranscriptModel` drains everything queued as **one batch per main-actor
hop**, layers on the viewer's highlight keywords, and coalesces a publish
(~15 ms) → `ChatListView` applies the change log to its diffable
`UICollectionView` → `ChatRow` renders. Join history waits at most ~3 s and
merges in above live chat if it's late; reconnect gaps land as one contiguous
batch. Sends are optimistic: the line appears immediately as `.sending` and
reconciles when Helix responds and EventSub echoes it back. Instruments:
`Channels.Pipeline` (`normalize`, `deliver`) and `Features.ChatTranscriptModel`
(`apply-batch`) signpost intervals.

For the full design rationale, see
[`docs/superpowers/specs/2026-05-24-chattr-design.md`](docs/superpowers/specs/2026-05-24-chattr-design.md).
Note that the codebase has since consolidated the originally-planned `ChatUI`
package into `Features` and now consumes `TwitchKit` as a pinned remote package
rather than a local path.

## Project conventions

Before adding code, skim [`docs/conventions.md`](docs/conventions.md). The rules
that bite hardest:

- **Packages are layers; dependencies only point down.** UI goes in `Features`;
  network/IO/persistence goes in its domain package; primitives go in `Core`.
- **Group by feature, not by type.** No `Views/` / `Models/` / `Stores/`
  subfolders — a screen, its `@Observable` model, and its helper views live
  together.
- **File-role suffixes are meaningful:** `*Screen`, `*View`, `*Row`, `*Sheet`,
  `*Model`, `*Store`, `*+Environment`.
- **View models are `@MainActor @Observable`;** async work lives in actors and
  stores, never `await`ed from a view body.

## Testing

Tests use **Swift Testing** for units, snapshot tests for cells, and
`URLProtocol` stubs for network. Package tests are *not* part of the Xcode
scheme — run them per package:

```sh
swift test --package-path Packages/Channels
swift test --package-path Packages/ChatModel
# …etc.
```

## CI and TestFlight

GitHub Actions (`.github/workflows/`):

- **CI** (`ci.yml`) — on every push to `main` and every PR: `swift test` for
  each package, plus an iOS Simulator `build-for-testing` of the app.
- **TestFlight** (`testflight.yml`) — on a `v*` tag (or manually from the
  Actions tab): archives a Release build and uploads it to App Store Connect.
  The build number is the workflow run number unless overridden.

TestFlight signing is cloud-managed through an App Store Connect API key, so
no certificates or profiles live in the repo. One-time setup:

1. App Store Connect → Users and Access → Integrations → App Store Connect API
   → generate a key with the **Admin** role; note the Key ID and Issuer ID and
   download `AuthKey_XXXX.p8` (downloadable once).
2. Make sure the app record for `com.landy.chattr` exists in App Store Connect.
3. Add repository secrets: `ASC_KEY_ID`, `ASC_ISSUER_ID`, and
   `ASC_KEY_P8_BASE64` (`base64 -i AuthKey_XXXX.p8 | pbcopy` on macOS, or
   `[Convert]::ToBase64String([IO.File]::ReadAllBytes("AuthKey_XXXX.p8"))` in
   PowerShell).
4. Push a tag: `git tag v1.0.0 && git push origin v1.0.0`.

## Roadmap

Agreed-on but not-yet-scheduled work (with the blocker noted for each) lives in
[`docs/ROADMAP.md`](docs/ROADMAP.md) — go-live push notifications, a
deleted-message display preference, custom bot lists, and Home-tab extras among
them.

## License

Proprietary. Copyright © 2026 Andrew Beshay. All rights reserved.

This source is not licensed for use, modification, or redistribution.
