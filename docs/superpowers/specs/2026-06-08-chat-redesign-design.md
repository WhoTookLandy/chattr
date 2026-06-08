# chattr chat redesign — design

**Date:** 2026-06-08
**Status:** Draft for review
**Scope:** The signed-in chat experience — screen structure, navigation model, and message-row readability. Reviewed against axiom-swiftui (`nav`, `gestures`, `toolbars`, `26-ref`) and axiom-design (`app-composition`, `liquid-glass`).

---

## 1. Context

chattr is a **pure second-screen Twitch chat client** — the user watches the stream elsewhere; chattr is the conversation. Today's signed-in shell (`AppShell`) is a three-tab `TabView` (Follows / Chat / Profile). The Chat tab (`ChatTabsScreen`) hosts a horizontal paged surface of `ChatScreen`s with a top channel-tab strip and a `Chat` navigation title.

### Problems being solved (user-prioritised)
1. **Wasted space / weak hierarchy.** The `Chat` nav title is the largest text on screen and carries no information; the bottom tab bar permanently occupies the base. The single most important fact — *which channel* — is a small grey pill.
2. **Generic feel.** Works, but doesn't read as a distinctive, premium native app.
3. **Clunky channel switching.** Switching/adding a channel is a Chat → "+" → Follows tab → back round-trip.

Explicitly **not** a priority: surfacing stream metadata (title, viewers, category) — consistent with a second-screen app where the user is already watching.

## 2. Goals & non-goals

**Goals**
- Make the **conversation own the screen** edge-to-edge; remove dead chrome.
- Make **channel identity + switching** first-class and native.
- Keep each chat **fully focused** while making movement between open chats instant.
- A **subtle, native** visual refinement (Liquid Glass / SF Symbols / spacing) — not a bold restyle.
- Fix the worst **message-row readability** issues.
- Leave a clean path for **moderator tooling** later.

**Non-goals (this pass)**
- Moderator features (future).
- A bolder/branded visual identity (future, separate pass).
- Stream metadata chrome.
- Changing the chat data/session layer (`TabChatModel`, `ChannelSessionRegistry`, emote/badge stores) — reused as-is.

## 3. Design

### 3.1 Screen structure — Chat as home
Remove the `Chat` navigation title and the three-tab `TabView`. The signed-in root becomes the **chat surface itself**, edge-to-edge. Follows and Profile become presented destinations (see 3.4), not peer tabs.

Each open channel is a full-height page. The user **swipes horizontally** to move between open chats. A **page-dots** indicator sits under the header for ≤ ~5 chats; beyond that the switcher (3.3) is the scalable path.

> **Implementation note (gestures).** Paging MUST use a native paging container — `ScrollView(.horizontal)` + `.scrollTargetBehavior(.paging)` (the existing `ChatTabsScreen` LazyHStack is already close). Do **not** hand-roll a `DragGesture`: axiom `gestures.md` shows custom drags conflict with the vertical chat `ScrollView` and `.scrollDismissesKeyboard(.interactively)`. A native paging scroll does axis-locking for free, so horizontal paging and vertical scroll/keyboard-dismiss coexist cleanly.

### 3.2 Header — a real toolbar
The header replaces both the title and the channel-tab strip, implemented as a **`.toolbar`** on the **single `NavigationStack` that wraps the paging container** (in `ChatTabsScreen`), not a hand-rolled `HStack` and not one `NavigationStack` per page. The toolbar reflects the **current page's** channel:

- **`.topBarLeading`** — account avatar → opens **Profile** (3.4).
- **`.principal`** — channel avatar + name + live dot + chevron → opens the **open-chats switcher** (3.3).
- **`.topBarTrailing`** — grid/list icon → opens **Follows** (3.4).

> **Implementation notes (toolbars + glass).**
> - Toolbar gives Liquid Glass styling and **automatic scroll-edge blur** — so we can **delete the manual `.scrollEdgeEffectStyle(.hard, for: .top)`** currently compensating for the tab strip.
> - **No conditional `if` inside `.toolbar`** (axiom `toolbars.md`): it rebuilds the whole bar and flickers. The live-dot / channel-name is **one stable principal item whose label is bound to the current page's channel**, never inserted/removed conditionally — so paging updates the label, not the toolbar structure. This aligns with the existing discipline of keeping per-message work off `ChatScreen.body`.
> - Header is navigation-layer → glass is correct here. Chat rows are content-layer → **never** glass.

### 3.3 Open-chats switcher (distinct from Follows)
Tapping the channel name presents a **sheet** listing **only the user's open chats** — the swipe order — with:
- live / unread indicators per chat,
- drag-to-reorder (defines swipe order),
- ✕-to-close (drops the tab; reuses `ChatTabsModel` close + registry release),
- a **"Browse Follows to add a chat"** button that presents Follows (3.4).

This is deliberately lightweight and is **not** the Follows browse experience. Section labels use title-style casing (iOS 26 no longer auto-uppercases section headers).

### 3.4 Navigation model — Follows & Profile as sheets
`Follows` (`ChannelListScreen`) and `Profile` (`ProfileScreen`) keep their existing screens and **each is presented as a sheet wrapping its own `NavigationStack`**, preserving independent back-stacks (what the per-tab `NavigationStack`s give today). This is the same modal-with-NavigationStack pattern already used by `ThreadView`.

- `openChannel` action and `ChatTabsModel` are reused unchanged. The current `onAddTab: { selectedTab = .follows }` becomes "present the Follows sheet."
- **Empty state** (zero open chats): the chat surface shows a prompt that opens Follows — so "browse my follows" still has a full-screen home; it simply isn't a permanent tab.
- Sheets follow HIG button rules (axiom `toolbars.md`): a browse/settings sheet dismisses via a single navigation affordance; don't add a misleading solo "Done" to a non-editing reading sheet — a swipe-down + nav back is sufficient, or a `.cancellationAction`/`.confirmationAction` pair where an action is being committed.

### 3.5 Message-row readability (content layer)
Keep the inline IRC-style flow (badges → name → runs) but fix the three worst issues:

1. **Wrapping / boundaries.** Today the message body flows through one `FlowLayout`, so wrapped lines return to x=0 and messages blur together. Give wrapped continuation a **hanging indent** (align under the message body, not back under the badges) and add clearer **vertical rhythm** between messages. iOS 26 `.lineHeight()` is the modern lever for intra-message line spacing. No heavy zebra — "subtle" is the brief.
2. **Event distinction.** Detect sub/raid/system lines and give them a **light leading accent + tint inset** so they read as events, not plain chat — without becoming loud full-width cards.
3. **Perf contract preserved.** `ChatRow` stays `Equatable` and allocation-light; the hanging-indent change is a layout tweak (likely a small extension to `FlowLayout` for a first-line/hanging inset), **not** a per-row allocation regression. Glass never touches rows.

### 3.6 Compose bar
Pin the compose bar with **`.safeAreaBar(edge: .bottom)`** (iOS 26) for integrated glass blur, and wrap the emote button + text field + send button in a **`GlassEffectContainer`** (axiom `liquid-glass.md`: adjacent glass elements need a container; glass-on-glass is forbidden). Keep the existing send-button treatment — `.glassProminent` + accent tint only when the draft is non-empty (tint conveys the primary action, per glass tinting rules).

### 3.7 Visual identity — subtle native refinement
Liquid Glass on the navigation layer only (header, compose, switcher, pills); SF Symbols; tightened spacing/typography. **Always `.regular`** glass — chat is text-on-black, not media-rich, so `.clear` never applies. No bold restyle this pass.

## 4. Component boundaries
- **`AppShell`** — drops the `TabView`; becomes the chat root + presenter of Follows/Profile sheets. Continues to own `ChatTabsModel`, `onOpen`/`onClose` wiring, and persistence hydration.
- **`ChatTabsScreen`** — the single `NavigationStack` + horizontal paging container (native paging scroll + page-dots). Owns the **toolbar header** (bound to the current page's channel) and the open-chats switcher sheet.
- **`ChatScreen`** — unchanged responsibilities; loses the in-content title/strip assumptions and the manual top scroll-edge hack. No longer owns the header (that moves up to `ChatTabsScreen`).
- **`ChannelSwitcherView`** (new) — the open-chats sheet (reorder/close/add).
- **`ChatRow`** — hanging-indent + event-styling refinements; perf contract intact.
- **`ChannelListScreen` / `ProfileScreen`** — unchanged internals; presented as sheets.

## 5. Risks & tradeoffs
- **Discoverability.** Header-icon nav trades a little discoverability for space (users learn "tap the title to switch"). Mitigated by the Follows empty-state and standard SF Symbol affordances.
- **Paging + scroll coexistence.** De-risked by using a native paging container (3.1); still requires testing with the keyboard up and during fast auto-scroll.
- **Toolbar flicker.** Avoided only if the principal item stays structurally stable (3.2) — must be verified given per-message updates.
- **Hanging indent in `FlowLayout`.** The one non-trivial layout change; inline emote *images* mean the body isn't a single `Text`, so the indent needs a layout-level first-line inset rather than a paragraph style.

## 6. Out of scope (tracked for later)
- Moderator tooling (the avatar rail / per-channel activity dots become relevant then).
- Bolder branded visual identity.
- Stream metadata surfaces.
