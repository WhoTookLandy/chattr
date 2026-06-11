# Login-name Annotation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Optionally show a chatter's login next to a localized display name (`デレク (derek)`) when the two differ ignoring case, controlled by a user setting that defaults on.

**Architecture:** Carry the already-available `chatterUserLogin` through the `ChatLine` model. A single pure function (`ChatAppearance.loginAnnotation`) owns the entire trigger rule and name ordering; the renderer and settings UI just feed and consume it. Setting persists via the existing flat-`@AppStorage`-key pattern and flows live through the SwiftUI environment.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing (`@Suite`/`@Test`), SPM packages (`ChatModel`, `Features`), TwitchKit. Built as an Xcode project (`chattr.xcodeproj`, scheme `chattr`).

---

## File Structure

| File | Responsibility | Change |
|------|----------------|--------|
| `Packages/ChatModel/Sources/ChatModel/ChatLine.swift` | The display-ready line model | Add `authorUserLogin` field + defaulted init param; forward in `withDeletedPlaceholder()` |
| `Packages/ChatModel/Sources/ChatModel/Normalizer.swift` | `ChatMessage` → `ChatLine` | Populate `authorUserLogin` for `.message` lines |
| `Packages/ChatModel/Tests/ChatModelTests/NormalizerTests.swift` | Normalizer tests | Add test: login is carried through |
| `Packages/Features/Sources/Features/Chat/ChatAppearance.swift` | Appearance settings + the decision rule | Add `LoginNameDisplay` enum, property, key, init param, `loginAnnotation(...)` |
| `Packages/Features/Tests/FeaturesTests/LoginNameAnnotationTests.swift` | Decision-rule tests | New suite (create) |
| `Packages/Features/Sources/Features/Chat/ChatRow.swift` | Renders a chat row | Compose `usernamePrefix` from the annotation pair |
| `Packages/Features/Sources/Features/App/RootView.swift` | Injects appearance into env | Read new key, pass into assembled `ChatAppearance` |
| `Packages/Features/Sources/Features/Account/ChatAppearanceScreen.swift` | Full settings screen + live preview | Picker + preview fixture with a mismatched login |
| `Packages/Features/Sources/Features/Chat/ChatSettingsSheet.swift` | Quick in-chat settings | On/off quick toggle |

## Test commands

- **ChatModel (pure):**
  `xcodebuild test -project chattr.xcodeproj -scheme chattr -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ChatModelTests 2>&1 | tail -25`
- **Features:**
  `xcodebuild test -project chattr.xcodeproj -scheme chattr -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:FeaturesTests 2>&1 | tail -25`
- **Build only (for UI changes with no unit test):**
  `xcodebuild build -project chattr.xcodeproj -scheme chattr -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -25`

> If `iPhone 16` isn't an installed simulator, substitute one from `xcrun simctl list devices available`. Swift Testing prints `✔ Test run with N tests passed` / `✘ ... failed` near the end of the output.

---

### Task 1: Carry login through `ChatLine` + `Normalizer`

**Files:**
- Modify: `Packages/ChatModel/Sources/ChatModel/ChatLine.swift` (field ~line 84, init ~329-355, `withDeletedPlaceholder` ~306-327)
- Modify: `Packages/ChatModel/Sources/ChatModel/Normalizer.swift:166-177`
- Test: `Packages/ChatModel/Tests/ChatModelTests/NormalizerTests.swift`

- [ ] **Step 1: Write the failing test**

Add this test inside the existing `@Suite("Normalizer tokenization")` struct in `NormalizerTests.swift` (place it after an existing `@Test` function, before the closing brace):

```swift
@Test("Chatter login is carried onto the ChatLine")
func carriesLogin() {
    // makeMessage derives chatter_user_login as chatterUserName.lowercased()
    let message = makeMessage(chatterUserName: "Tester", fragments: [textSpec("hi")])
    let line = Normalizer.normalize(
        message: message,
        emoteSnapshot: [:],
        currentUserLogin: "someoneelse"
    )
    #expect(line.authorUserLogin == "tester")
    #expect(line.authorDisplayName == "Tester")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project chattr.xcodeproj -scheme chattr -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ChatModelTests 2>&1 | tail -25`
Expected: FAIL to compile — `value of type 'ChatLine' has no member 'authorUserLogin'`.

- [ ] **Step 3: Add the field to `ChatLine`**

In `ChatLine.swift`, add the property immediately after the `authorDisplayName` declaration (after line 84):

```swift
    /// The chatter's lowercase login ("derek"), the unique handle used for
    /// @-mentions and Helix lookups. Distinct from `authorDisplayName`,
    /// which may be a localized non-Latin name ("デレク") or just a
    /// capitalization variant. Empty for system/bubble lines that have no
    /// single inline author. The renderer uses it to annotate localized
    /// names — see `ChatAppearance.loginAnnotation`.
    public let authorUserLogin: String
```

Add a defaulted parameter to the memberwise `init` — insert after the `authorDisplayName: String,` line (line 335):

```swift
        authorUserLogin: String = "",
```

And assign it inside `init` (after `self.authorDisplayName = authorDisplayName`, line 348):

```swift
        self.authorUserLogin = authorUserLogin
```

Forward it in `withDeletedPlaceholder()` — add after the `authorDisplayName: authorDisplayName,` line (line 314):

```swift
            authorUserLogin: authorUserLogin,
```

- [ ] **Step 4: Populate it in `Normalizer`**

In `Normalizer.swift`, in the `.message` return at lines 166-177, add the argument after `authorDisplayName: message.chatterUserName,` (line 172):

```swift
            authorUserLogin: message.chatterUserLogin,
```

(Leave the two bubble builders — `line(from:)` at ~285 and ~299 — untouched; they keep the `""` default, since bubbles render no inline username.)

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild test -project chattr.xcodeproj -scheme chattr -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ChatModelTests 2>&1 | tail -25`
Expected: PASS — all `ChatModelTests` pass (the new test plus existing ones, which still compile because the init param is defaulted).

- [ ] **Step 6: Commit**

```bash
git add Packages/ChatModel/Sources/ChatModel/ChatLine.swift Packages/ChatModel/Sources/ChatModel/Normalizer.swift Packages/ChatModel/Tests/ChatModelTests/NormalizerTests.swift
git commit -m "feat(chat): carry chatter login onto ChatLine"
```

---

### Task 2: `LoginNameDisplay` setting + `loginAnnotation` decision rule

**Files:**
- Modify: `Packages/Features/Sources/Features/Chat/ChatAppearance.swift` (struct body ~19-68, keys ~77-84)
- Test: `Packages/Features/Tests/FeaturesTests/LoginNameAnnotationTests.swift` (create)

- [ ] **Step 1: Write the failing test**

Create `Packages/Features/Tests/FeaturesTests/LoginNameAnnotationTests.swift`:

```swift
import Testing
@testable import Features

@Suite("Login-name annotation rule")
struct LoginNameAnnotationTests {

    @Test("Localized name, display-first → (display, login)")
    func localizedDisplayFirst() {
        let pair = ChatAppearance.loginAnnotation(
            displayName: "デレク", login: "derek", style: .displayFirst
        )
        #expect(pair?.primary == "デレク")
        #expect(pair?.secondary == "derek")
    }

    @Test("Localized name, login-first → (login, display)")
    func localizedLoginFirst() {
        let pair = ChatAppearance.loginAnnotation(
            displayName: "デレク", login: "derek", style: .loginFirst
        )
        #expect(pair?.primary == "derek")
        #expect(pair?.secondary == "デレク")
    }

    @Test("Capitalization-only difference → nil (adds nothing)")
    func capitalizationOnly() {
        #expect(ChatAppearance.loginAnnotation(
            displayName: "Shroud", login: "shroud", style: .displayFirst
        ) == nil)
    }

    @Test("Exact match → nil")
    func exactMatch() {
        #expect(ChatAppearance.loginAnnotation(
            displayName: "ninja", login: "ninja", style: .loginFirst
        ) == nil)
    }

    @Test("Off style → nil even when names differ")
    func offStyle() {
        #expect(ChatAppearance.loginAnnotation(
            displayName: "デレク", login: "derek", style: .off
        ) == nil)
    }

    @Test("Empty login → nil")
    func emptyLogin() {
        #expect(ChatAppearance.loginAnnotation(
            displayName: "デレク", login: "", style: .displayFirst
        ) == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project chattr.xcodeproj -scheme chattr -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:FeaturesTests/LoginNameAnnotationTests 2>&1 | tail -25`
Expected: FAIL to compile — `cannot find 'ChatAppearance.loginAnnotation'` / `cannot find type 'LoginNameDisplay'`.

- [ ] **Step 3: Add the enum, property, key, and helper**

In `ChatAppearance.swift`:

Add the enum just inside the `struct ChatAppearance` opening (after line 19 `public struct ChatAppearance: Equatable, Sendable {`):

```swift
    /// How to annotate a chatter's username with their login. A Twitch
    /// display name differs from the login only by capitalization OR as a
    /// fully localized non-Latin name — so "differs ignoring case" is a
    /// precise proxy for "this is a localized name worth annotating".
    public enum LoginNameDisplay: String, CaseIterable, Sendable {
        case off          // デレク
        case displayFirst // デレク (derek)   — default
        case loginFirst   // derek (デレク)
    }
```

Add the property after `edgeToEdge` (after line 54):

```swift
    /// Annotate localized usernames with the login (see `loginAnnotation`).
    public var loginNameDisplay: LoginNameDisplay = .displayFirst
```

Add the init parameter — in the `init(...)` signature add after `edgeToEdge: Bool = false` (line 61, add a comma to that line):

```swift
        loginNameDisplay: LoginNameDisplay = .displayFirst
```

…and assign it in the init body (after `self.edgeToEdge = edgeToEdge`, line 67):

```swift
        self.loginNameDisplay = loginNameDisplay
```

Add the storage key after `edgeToEdgeKey` (after line 84):

```swift
    public static let loginNameDisplayKey = "chattr.chatAppearance.loginNameDisplay"
```

Add the decision helper as an extension at the end of the file, after the closing brace of the `EnvironmentValues` extension (after line 140):

```swift
// MARK: - Login annotation rule

extension ChatAppearance {
    /// The (primary, secondary) name pair to render for a username, or
    /// `nil` when no login annotation should be shown. `secondary` is the
    /// name shown in dimmed parentheses. The single source of truth for
    /// both the trigger rule and the name ordering.
    public static func loginAnnotation(
        displayName: String,
        login: String,
        style: LoginNameDisplay
    ) -> (primary: String, secondary: String)? {
        guard style != .off,
              !login.isEmpty,
              displayName.lowercased() != login.lowercased() else {
            return nil
        }
        switch style {
        case .off:          return nil   // unreachable — guarded above
        case .displayFirst: return (displayName, login)
        case .loginFirst:   return (login, displayName)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project chattr.xcodeproj -scheme chattr -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:FeaturesTests/LoginNameAnnotationTests 2>&1 | tail -25`
Expected: PASS — all 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Sources/Features/Chat/ChatAppearance.swift Packages/Features/Tests/FeaturesTests/LoginNameAnnotationTests.swift
git commit -m "feat(chat): add LoginNameDisplay setting + annotation rule"
```

---

### Task 3: Render the annotation in `ChatRow`

**Files:**
- Modify: `Packages/Features/Sources/Features/Chat/ChatRow.swift:322-327`

No unit test (SwiftUI `Text` composition) — verified by build + the live preview in Task 5.

- [ ] **Step 1: Replace `usernamePrefix`**

In `ChatRow.swift`, replace the current `usernamePrefix` computed property (lines 322-327):

```swift
    /// Styled username Text, ready to interpolate alongside the colon.
    private var usernamePrefix: Text {
        Text(line.authorDisplayName)
            .font(appearance.font.weight(.semibold))
            .foregroundStyle(usernameColor)
    }
```

with:

```swift
    /// Styled username Text, ready to interpolate alongside the colon.
    /// When the chatter's display name is a localized variant of their
    /// login (and the setting is on), the login is appended in dimmed
    /// parentheses — order per `appearance.loginNameDisplay`.
    private var usernamePrefix: Text {
        let nameFont = appearance.font.weight(.semibold)
        guard let pair = ChatAppearance.loginAnnotation(
            displayName: line.authorDisplayName,
            login: line.authorUserLogin,
            style: appearance.loginNameDisplay
        ) else {
            return Text(line.authorDisplayName)
                .font(nameFont)
                .foregroundStyle(usernameColor)
        }
        let primary = Text(pair.primary)
            .font(nameFont)
            .foregroundStyle(usernameColor)
        let secondary = Text(" (\(pair.secondary))")
            .font(nameFont)
            .foregroundStyle(.secondary)
        return primary + secondary
    }
```

- [ ] **Step 2: Verify it builds**

Run: `xcodebuild build -project chattr.xcodeproj -scheme chattr -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -25`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add Packages/Features/Sources/Features/Chat/ChatRow.swift
git commit -m "feat(chat): render login annotation in usernamePrefix"
```

---

### Task 4: Inject the setting through `RootView`

**Files:**
- Modify: `Packages/Features/Sources/Features/App/RootView.swift:38-42, 57-65`

Without this, live chat ignores the setting (only the settings-screen preview would react). No unit test — build-verified.

- [ ] **Step 1: Add the `@AppStorage` mirror**

In `RootView.swift`, add after the `chatEdgeToEdge` declaration (line 42):

```swift
    @AppStorage(ChatAppearance.loginNameDisplayKey) private var chatLoginNameDisplay: ChatAppearance.LoginNameDisplay = .displayFirst
```

- [ ] **Step 2: Pass it into the assembled appearance**

In the `chatAppearance` computed property (lines 57-65), add the argument after `edgeToEdge: chatEdgeToEdge` (add a comma to that line):

```swift
            loginNameDisplay: chatLoginNameDisplay
```

So the call reads:

```swift
        ChatAppearance(
            textSizePoints: chatTextSizePoints * chatTypeScale,
            showTimestamps: chatShowTimestamps,
            showBadges: chatShowBadges,
            animatedEmotes: chatAnimatedEmotes,
            edgeToEdge: chatEdgeToEdge,
            loginNameDisplay: chatLoginNameDisplay
        )
```

- [ ] **Step 3: Verify it builds**

Run: `xcodebuild build -project chattr.xcodeproj -scheme chattr -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -25`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add Packages/Features/Sources/Features/App/RootView.swift
git commit -m "feat(chat): inject login-name setting into live chat"
```

---

### Task 5: Picker + live preview in `ChatAppearanceScreen`

**Files:**
- Modify: `Packages/Features/Sources/Features/Account/ChatAppearanceScreen.swift` (storage ~29-34, previewAppearance ~46-53, a new Section, preview fixture ~172-180)

- [ ] **Step 1: Add the `@AppStorage` mirror**

In `ChatAppearanceScreen.swift`, add after the `edgeToEdge` storage declaration (line 33):

```swift
    @AppStorage(ChatAppearance.loginNameDisplayKey) private var loginNameDisplay: ChatAppearance.LoginNameDisplay = .displayFirst
```

- [ ] **Step 2: Feed it into the preview appearance**

In `previewAppearance` (lines 46-53), add the argument after `animatedEmotes: animatedEmotes` (add a comma to that line):

```swift
            loginNameDisplay: loginNameDisplay
```

- [ ] **Step 3: Add the Username picker section**

Insert this new `Section` immediately after the "Message Details" section (after line 120, before the "Animated Emotes" section):

```swift
            Section {
                Picker(selection: $loginNameDisplay) {
                    Text("Off").tag(ChatAppearance.LoginNameDisplay.off)
                    Text("デレク (derek)").tag(ChatAppearance.LoginNameDisplay.displayFirst)
                    Text("derek (デレク)").tag(ChatAppearance.LoginNameDisplay.loginFirst)
                } label: {
                    Label("Show Username", systemImage: "at")
                }
            } header: {
                Text("Localized Names")
            } footer: {
                Text("When a chatter's display name differs from their username — common for non-Latin names — show the username alongside it.")
            }
```

- [ ] **Step 4: Give a preview row a mismatched login**

Replace the `previewLineChatter` fixture (lines 172-180) so the picker visibly changes the preview:

```swift
    private static let previewLineChatter = ChatLine(
        id: "preview-chatter",
        authorDisplayName: "デレク",
        authorUserLogin: "derek",
        authorColor: "#FF69B4",
        // Word-level runs, matching Normalizer output — the preview must
        // wrap exactly like real chat lines do.
        runs: ChatModel.Normalizer.wordRuns(text: "welcome to the stream! today we're checking out the new update"),
        timestamp: Date.now.addingTimeInterval(-150)
    )
```

> Note the argument order: `authorUserLogin` comes right after `authorDisplayName` to match the `ChatLine.init` signature from Task 1.

- [ ] **Step 5: Verify it builds**

Run: `xcodebuild build -project chattr.xcodeproj -scheme chattr -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -25`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: Commit**

```bash
git add Packages/Features/Sources/Features/Account/ChatAppearanceScreen.swift
git commit -m "feat(chat): add localized-name picker with live preview"
```

---

### Task 6: Quick on/off toggle in `ChatSettingsSheet`

**Files:**
- Modify: `Packages/Features/Sources/Features/Chat/ChatSettingsSheet.swift` (storage ~54-56, `preferencesSection` ~210-231)

The underlying setting is a 3-way enum; the quick sheet exposes a simple on/off (mapping off ↔ displayFirst). The display-vs-login order lives only in the full Chat Appearance screen.

- [ ] **Step 1: Add the `@AppStorage` mirror**

In `ChatSettingsSheet.swift`, add after the `edgeToEdge` storage declaration (line 56):

```swift
    @AppStorage(ChatAppearance.loginNameDisplayKey) private var loginNameDisplay: ChatAppearance.LoginNameDisplay = .displayFirst
```

- [ ] **Step 2: Add the on/off toggle**

In `preferencesSection` (lines 210-231), add this `Toggle` after the "Animated Emotes" toggle (after line 217, before the "Edge-to-Edge" toggle):

```swift
            Toggle(isOn: Binding(
                get: { loginNameDisplay != .off },
                set: { loginNameDisplay = $0 ? .displayFirst : .off }
            )) {
                Label("Show Usernames", systemImage: "at")
            }
```

- [ ] **Step 3: Verify it builds**

Run: `xcodebuild build -project chattr.xcodeproj -scheme chattr -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -25`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Run the full Features + ChatModel suites once more**

Run: `xcodebuild test -project chattr.xcodeproj -scheme chattr -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:FeaturesTests -only-testing:ChatModelTests 2>&1 | tail -25`
Expected: PASS — all suites green.

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Sources/Features/Chat/ChatSettingsSheet.swift
git commit -m "feat(chat): quick toggle for username annotation in chat settings"
```

---

## Self-review notes (verified against the spec)

- **Spec coverage:** setting model → Task 2; data plumbing → Task 1; decision logic → Task 2; rendering → Task 3; env injection → Task 4 (the spec's called-out "don't miss `RootView`" risk); both UI controls → Tasks 5 & 6; tests → Tasks 1 & 2. All spec sections map to a task.
- **Type consistency:** `LoginNameDisplay` (cases `off`/`displayFirst`/`loginFirst`) and `loginAnnotation(displayName:login:style:) -> (primary:secondary:)?` are defined in Task 2 and used identically in Tasks 3–6. `authorUserLogin` defined in Task 1, used in Tasks 3 & 5 with consistent argument ordering (right after `authorDisplayName`).
- **Out-of-scope confirmed absent:** no `always` mode, no separate dim toggle, no per-channel override.
