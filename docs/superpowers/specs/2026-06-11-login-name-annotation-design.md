# Login-name annotation for localized display names

**Date:** 2026-06-11
**Status:** Approved (design), pending implementation plan

## Problem

A Twitch user's `display_name` can differ from their `login` in only two
ways: capitalization (`Shroud` / `shroud`), or a fully localized non-Latin
name (`デレク` / `derek`). The localized case is the painful one — you can't
tell who the chatter is, can't @-mention them, can't search for them,
because the visible name shares no characters with the typeable login.

We want to optionally annotate the rendered username with the login when the
two genuinely differ, e.g. `デレク (derek)`.

## Goal

Add a user setting (default ON) that shows the login next to the display
name **only when they differ ignoring case**. Offer one variation: which
name comes first.

- `デレク (derek)` — display first (default)
- `derek (デレク)` — login first

Out of scope (explicitly not built): an "always show login" mode, a separate
dim toggle, per-channel overrides, and any change to mention/search behavior.

## Setting model

A new `String`-backed enum on `ChatAppearance`, persisted with the existing
flat-`@AppStorage`-key pattern (no Codable, no migration):

```swift
public enum LoginNameDisplay: String, CaseIterable, Sendable {
    case off          // デレク
    case displayFirst // デレク (derek)   — DEFAULT
    case loginFirst   // derek (デレク)
}
```

Changes in `ChatAppearance.swift`:

- Add `public var loginNameDisplay: LoginNameDisplay = .displayFirst`.
- Add it to the memberwise `init` (defaulted, so existing call sites are
  unaffected).
- Add `public static let loginNameDisplayKey = "chattr.chatAppearance.loginNameDisplay"`.

`@AppStorage` supports a `RawRepresentable`-`String` enum directly, so the
settings screen and `RootView` can bind/read it the same way they read the
`Bool` keys today.

## Data plumbing

`ChatLine` currently carries `authorDisplayName` but drops the login. Add it:

- **`ChatLine.swift`**: add `public let authorUserLogin: String`, placed
  after `authorDisplayName`. Add a defaulted `authorUserLogin: String = ""`
  parameter to the memberwise `init` (keeps every existing `ChatLine(...)`
  call site — previews, optimistic-send, tests — compiling unchanged).
  Forward it in `withDeletedPlaceholder()`.
- **`Normalizer.normalize(...)`**: pass `authorUserLogin: message.chatterUserLogin`
  in the returned `ChatLine`. (The login is already on the `ChatMessage`; this
  is the only normalization change. The two bubble builders — `line(from:)` —
  leave it at the `""` default; bubbles don't render an inline username.)

## Decision logic (the one rule, isolated and testable)

A single pure function, living next to `ChatAppearance` in the Features
package (the enum lives there, and the function has no SwiftUI dependency so
it unit-tests cleanly):

```swift
extension ChatAppearance {
    /// The (primary, secondary) name pair to render, or nil when no
    /// annotation applies. Secondary is shown in parentheses, dimmed.
    static func loginAnnotation(
        displayName: String,
        login: String,
        style: LoginNameDisplay
    ) -> (primary: String, secondary: String)?
}
```

Rules:

1. `style == .off` → `nil`.
2. `login` empty → `nil` (system/optimistic lines with no login).
3. `displayName.lowercased() == login.lowercased()` → `nil` (capitalization-only
   difference adds nothing).
4. else `.displayFirst` → `(displayName, login)`; `.loginFirst` → `(login, displayName)`.

This is the **only** place the trigger rule and ordering are decided. The
renderer just consumes the pair.

## Rendering

In `ChatRow.usernamePrefix` (currently a single `Text(line.authorDisplayName)`):

- Compute `ChatAppearance.loginAnnotation(displayName: line.authorDisplayName,
  login: line.authorUserLogin, style: appearance.loginNameDisplay)`.
- When `nil`, render exactly as today (`Text(line.authorDisplayName)` with the
  user color + semibold font).
- When non-nil, build a composed `Text`:
  - `primary` in the user color + semibold (same as the bare-name styling), then
  - ` (` + `secondary` + `)` in `.secondary` foreground, same font/weight.
  - Built by `Text` interpolation so the whole thing stays one flow item and
    wraps/hugs the trailing colon exactly like the current
    `"\(usernamePrefix)\(Text(":"))"` interpolation in `messageBody`.

No change to the colon interpolation site — `usernamePrefix` stays a `Text`.

## UI controls

**`ChatAppearanceScreen.swift`** (the full screen with live preview):

- Add `@AppStorage(ChatAppearance.loginNameDisplayKey) private var loginNameDisplay: LoginNameDisplay = .displayFirst`.
- Feed it into `previewAppearance` (add the field to that `ChatAppearance(...)`).
- Add a `Picker` in a new "Username" `Section`:
  - `Off` → `.off`, `デレク (derek)` → `.displayFirst`, `derek (デレク)` → `.loginFirst`.
  - Footer explaining: shown only when a chatter's display name differs from
    their username (common for non-Latin names).
- Update a preview fixture so the effect is visible: give one preview
  `ChatLine` a mismatched login (e.g. `authorDisplayName: "デレク"`,
  `authorUserLogin: "derek"`), so toggling the picker visibly changes the
  preview row.

**`ChatSettingsSheet.swift`** (quick in-chat settings):

- Add a quick control in `preferencesSection`. Because the underlying setting
  is a 3-way enum but the quick sheet uses toggles, bind a `Toggle` to a
  computed `Binding<Bool>` that maps `off ↔ displayFirst`:
  - `get`: `loginNameDisplay != .off`
  - `set`: `loginNameDisplay = $0 ? .displayFirst : .off`
  - Backed by `@AppStorage(ChatAppearance.loginNameDisplayKey)`.
  - Label e.g. "Show Usernames" with an SF Symbol (e.g. `character.cursor.ibeam`
    or `at`). The full order choice (display-first vs login-first) stays in the
    appearance screen reachable via the existing "Chat Appearance" link.

**`RootView`** (environment injection): read the new key via `@AppStorage` and
pass `loginNameDisplay:` into the assembled `ChatAppearance`, alongside the
existing keys, so open chats update live.

## Testing

New `@Suite` in `FeaturesTests` (mirroring `ChatAppearanceMigrationTests`)
exercising `ChatAppearance.loginAnnotation(...)` directly — no SwiftUI, no
defaults needed:

- Localized differ, `.displayFirst` → `("デレク", "derek")`.
- Localized differ, `.loginFirst` → `("derek", "デレク")`.
- Case-only differ (`"Shroud"` / `"shroud"`), `.displayFirst` → `nil`.
- Exact match (`"ninja"` / `"ninja"`), any non-off style → `nil`.
- `.off` with a localized differ → `nil`.
- Empty login → `nil`.

## Files touched

| File | Change |
|------|--------|
| `Packages/ChatModel/Sources/ChatModel/ChatLine.swift` | Add `authorUserLogin` field + defaulted init param; forward in `withDeletedPlaceholder()` |
| `Packages/ChatModel/Sources/ChatModel/Normalizer.swift` | Pass `chatterUserLogin` into the `.message` `ChatLine` |
| `Packages/Features/Sources/Features/Chat/ChatAppearance.swift` | Add `LoginNameDisplay` enum, `loginNameDisplay` property, storage key, init param, `loginAnnotation(...)` helper |
| `Packages/Features/Sources/Features/Chat/ChatRow.swift` | Compose `usernamePrefix` from the annotation pair |
| `Packages/Features/Sources/Features/Account/ChatAppearanceScreen.swift` | Picker + preview wiring |
| `Packages/Features/Sources/Features/Chat/ChatSettingsSheet.swift` | Quick on/off toggle |
| `Packages/Features/Sources/Features/App/RootView.swift` | Inject new key into `ChatAppearance` |
| `Packages/Features/Tests/FeaturesTests/...` | New suite for `loginAnnotation` |

## Risks / notes

- **Defaulted params everywhere** keep this additive — no existing `ChatLine`
  construction or `ChatAppearance` init breaks.
- `RootView` is the one spot that must be updated or the live-update path
  silently no-ops (preview would still work via local injection, real chat
  wouldn't). Called out so it isn't missed.
- Accessibility: the composed username `Text` reads naturally
  ("デレク derek") to VoiceOver; no extra label needed, but worth a glance
  during implementation.
