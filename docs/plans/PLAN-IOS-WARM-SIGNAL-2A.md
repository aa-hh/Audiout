# PLAN — iOS companion: Warm Signal token layer + Speakers redesign

**Status: scoped, spec-checked twice, patched. NOT executed. No implementation code has been written.**

This branch (`claude/ios-warm-signal-2a`, cut from `claude/companion-app-phase2-ios` @ `381a0f63`) carries a
ready-to-execute work order and nothing else. Pick it up and run it; there is no half-finished state to
reconcile.

## What this is

Implementation of `Audiouter Remote - iOS Design System.dc.html` — the Claude Design project at
<https://claude.ai/design/p/2b310903-1a59-446f-900c-3c784920b7e8> — onto the existing SwiftUI companion app
at `ios/AudiouterRemote/`.

The design document is a two-turn canvas: turn 1 explores three directions, turn 2 converges on seven screens
(`2a` Speakers · `2b` light mode · `2c` Apps · `2d` Groups · `2e` Connect · `2f` device sheet · `2g`
multi-select) plus `1f` glanceable surfaces. **This pass implements the token layer and `2a` only.**

## Where the spec lives

`dev/notes/ios-design-system-2a.dc.html` — a byte-identical copy of the design document, checked in so the
work order's citations resolve. **`doc:N` throughout the work order means line N of that file.** Read it with
`sed -n 'Np' dev/notes/ios-design-system-2a.dc.html`, or open it in a browser to see the rendered mockups
(it is self-contained apart from a viewer runtime it loads by relative path, which is not checked in — the
JSX source is what the work order cites, not the rendering).

Two files in the design project are deliberately **not** copied here and are not needed:
- `components/fig-tokens.css` / `fig-typography.css` — the document references neither (verified: zero hits),
  and the typography file is empty. The document defines its own tokens inline.
- `support.js` — the generated Claude Design viewer runtime, marked "do not edit". Browser plumbing.
- `ios-frame.jsx` — a simulated iPhone bezel/status bar used to frame each mockup, marked
  `@ds-adherence-ignore`. A real iPhone provides all of it. Everything *inside* `<IOSDevice>` is the app.

## Scope decisions already made — do not re-open

Answered by Alec on 2026-08-08. These are settled; the work order is written to them.

| Decision | Answer |
|---|---|
| How much of `2a`–`2g` | **Token/primitive layer + Speakers (`2a`) only.** Apps, Groups, Connect keep today's structure and pick up the gold accent. |
| `1f` widgets / Live Activity / Home tile | **Out.** Needs new WidgetKit targets ⇒ a `project.pbxproj` edit, forbidden by `ios/AGENTS.md:12-20`. Its own task later. |
| Light mode (`2b`) | **Palette only**, following the system appearance. The accent dial and Dark/Light/Auto control (`doc:644-671`) are deferred. |
| Row-as-fader vs existing controls | **Replaces** the `Toggle` + `Slider`, **but keeps the enablement rule** — dragging an unarmed row does nothing and sends nothing, so the ten tests over `isControllable` / `showsFailureCard` / `disabledReason` stay meaningful. |
| Bluetooth section | **Kept, as a structural placeholder** with an honest empty state. No fabricated rows. Tracked as roadmap `004`. |
| The other seven data-less elements | **Dropped**, and Step 12 files a roadmap entry for each so the Mac-side protocol work is tracked. |
| Per-device mute | **Moves to the Main Out drawer.** The row loses its mute button (matching the design); every drawer row gains one, so mute stays two taps away and the row's `MUTED` label stays actionable. |
| Failed rows vs single accessibility element | **Working rows collapse to one element; failed rows do not** — otherwise Diagnose and Try Again vanish for VoiceOver users. |
| Main Out deck placement | **Floats; the list scrolls underneath it.** `.overlay(alignment: .bottom)`, not `.safeAreaInset`. |

## How this was produced

Scoped by an Opus scoping agent (Fable was out of credits), then spec-checked twice by independent read-only
agents against `git show 381a0f63:<path>` — not against the `companion-app-phase2-ios` worktree, whose working
copy differs. The first check found blockers; the order was revised; the second check found seven more, all of
which are fixed here. **Appendix A records what was verified so the next agent does not repeat it.**

## Before you start

- Work in this worktree. Do **not** touch `.claude/worktrees/companion-app-phase2-ios` — another session has
  uncommitted edits there, including a `project.pbxproj` `objectVersion` downgrade.
- `ios/AGENTS.md:47` names an `iPhone 17` simulator that does not exist; Step 9 fixes it to `iPhone 17 Pro Max`.
- The base commit's test suite fails on arrival: 110 tests, 1 failure, `zzDebugDump` at
  `SpeakerRowRulesTests.swift:81` — a deliberate `#expect(Bool(false))` debug probe. That is the baseline, not
  a regression. Another session is already removing it.
- Read `ios/AGENTS.md` before editing anything under `ios/`.

---

# Work order — Warm Signal token layer + Speakers (`2a`) on `AudiouterRemote`

## Goal

Build the design document's token/primitive layer (both colour grounds) and land it on the Speakers tab as the proving screen: warm canvas, five collapsible sections, row-as-fader (tap arms, horizontal drag sets volume), and the floating glass Main Out deck with its per-device drawer. Apps, Groups and Connect pick up the gold accent only. This is the vertical slice that proves the grammar on the one screen the design marks "live" (`design-system.dc.html:44`); `2c`–`2g` and `1f` are separate passes.

Seven designed elements have no data behind them in the companion protocol. They are dropped here and each gets a roadmap entry (Step 12) so the Mac-side work is tracked rather than lost.

---

## Verified facts

Base commit is `381a0f63` on `claude/companion-app-phase2-ios`. **Every citation below was re-read via `git show 381a0f63:<path>`**, not from the existing worktree's uncommitted copy. Design doc = `dev/notes/ios-design-system-2a.dc.html`, cited `doc:N`. Swift paths are relative to `ios/AudiouterRemote/` unless absolute.

**Baseline, measured this session** (throwaway detached worktree at `381a0f63`, since removed):
- `xcodebuild ... -destination 'generic/platform=iOS Simulator' build` → `** BUILD SUCCEEDED **`
- `xcodebuild test ... -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'` → `** TEST FAILED **`; `Test run with 110 tests in 6 suites failed after 0.666 seconds with 1 issue`; the one issue is `✘ Test zzDebugDump() recorded an issue at SpeakerRowRulesTests.swift:81:9: Expectation failed: Bool(false)`. XCUITest suite: `Executed 1 test, with 0 failures ... in 89.730 seconds`.
- `zzDebugDump` occupies `AudiouterRemoteTests/SpeakerRowRulesTests.swift:75-82` **at base** (file is 207 lines). Another session has deleted it in their uncommitted copy — irrelevant to us. Not ours to touch.

**Toolchain:** Xcode 27.0 (27A5228h). `xcrun simctl list devices available` → iOS 27.0 iPhones are `iPhone 17 Pro Max`, `iPhone 17e`, `iPhone Air`. **No `iPhone 17`**, so `ios/AGENTS.md:47` is wrong. `scripts/build.sh` does not exist on this branch; `grep -c xcodebuild scripts/run-tests.sh` → `0`. Raw `xcodebuild` is the only iOS path (`ios/AGENTS.md:33-48`).

**Rules that bind this change** (`ios/AGENTS.md`): `:12-20` `project.pbxproj` hand-edited exactly once, never again — both targets use `PBXFileSystemSynchronizedRootGroup`, so a new `.swift` file needs no project edit; `:21-24` only `AudiouterProtocol` may be depended on, never `AudiouterCore`; `:25-27` iOS 18.0, iPhone-only; `:28-31` Guard 4 does not run these tests. The existing `companion-app-phase2-ios` worktree has `project.pbxproj` modified by another session right now (`objectVersion 77 → 70`). Never work there.

**The test fence on `SpeakersView` — the constraint that shapes this whole plan.** At base, `SpeakerRowRulesTests.swift:66-73` defines `stateProperties(of:)`, matching any property whose type description contains `"State<"`. `:95` asserts:
```swift
#expect(stateProperties(of: SpeakersView(session: DemoMacSession())).isEmpty)
```
and `:96-99` asserts `MainOutRow`'s state `.contains("localVolume")`. `SpeakersView.swift:8` states the invariant deliberately: "This view owns no local state at all". **`SpeakersView` may not gain a single `@State` property.** `MainOutRow` may gain any number — `:96-99` only checks that `localVolume` is present.

Other asserted symbols at base: `MainOutRow.thumbValue(local:server:)` at `:106-108` and `:116`; `MainOutRow(masterVolume:isMuted:session:)` called with exactly three arguments at `:96-98`; **ten** device-row tests over `DeviceRowView.isControllable` / `showsFailureCard` / `disabledReason` at `:122-206`.

**Current Speakers implementation:**
- `AudiouterRemote/UI/Speakers/SpeakersView.swift:15-48` — `NavigationStack` → custom `header` → `StatusBanners` → `List(.insetGrouped)`, sections "Main Out" (`MainOutPicker` + `MainOutRow`) and "Speakers" (`ForEach` of `DeviceRowView`). `:54-83` header. `:85-109` status text/symbol/colour.
- `SpeakersView.swift:114-127` — `MainOutRow`'s type doc comment stating the released-value hold policy (and `:121-127` the rubber-band regression it guards against). `:128-191` the type; `:133` `@State localVolume`; `:137` `@State isDragging`; `:142-144` `static thumbValue`; `:156-188` the `Slider` and its send policy (`:166-170` the `onEditingChanged` that is the *only* writer of `isDragging`); `:174-178` the hold-on-release comment; `:180-186` the `.onChange(of: masterVolume)` that clears the echo.
- `AudiouterRemote/UI/Speakers/DeviceRowView.swift:103-141` row body; `:37-39` `showsFailureCard`; `:70-75` `isControllable`; `:84-87` `disabledReason`; `:154-193` `controlsRow`; `:195-220` `failureCard`, whose `:201` guards `failureSuggestion` with `if let`; `:176-181` the current release policy (clear the echo on release).
- `AudiouterRemote/UI/Speakers/MainOutPicker.swift` — `struct` opens `:9`, `let snapshot`/`let session` `:10-11`, `private enum Target` `:13-16`, `current` `:18-24`, `body` `:26-44` with the `Picker` at `:27-42` and `.accessibilityHint("Choose which speakers Main Out sends to")` verbatim at `:43`.
- `AudiouterRemote/UI/Speakers/StatusBanners.swift:21-37` — three whole-app status strips.
- `AudiouterRemote/RootView.swift` (**not** under `UI/`) — stock `TabView` at `:125-152`; fourth tab labelled `"Connection"` at `:150`.
- No asset catalog exists. `grep -rn "Color("` over `ios/` → 5 hits: `UI/Groups/GroupIconPicker.swift:53`, `UI/Apps/AppGlyph.swift:46,47,106,112`. Explicit `Color.accentColor` literals live at `UI/Groups/GroupsView.swift:54` and `UI/Groups/GroupIconPicker.swift:52,55,60`.

**Model available** (`AudiouterProtocol/Sources/AudiouterProtocol/CompanionSnapshot.swift:39-52`): `DeviceState` carries `id, name, kind, iconSymbolName, isAvailable, supportsAirPlay2, isLocalDevice, volume, isMuted, isSelected, isMainOutMember, connection`. `ConnectionInfo` is `state: String`, `failureHeadline: String?`, `failureSuggestion: String?` (`:28-31`). `kind` is a plain `String` (`:42`). No `isPinned`, no meter level. `MacSessionProtocol.swift:21-23` forbids phone-side persistence of routing state. `DemoMacSession.swift:121` seeds `DeviceRecord(id: "local-mac", name: "This Mac", kind: "localMac", ...)`.

**Roadmap tooling** — `/Users/alechenderson/.claude/plugins/cache/foundry/foreman/0.46.0-alpha/scripts/roadmap.js`:
- `:8-10` `projectDir()` returns `path.resolve(process.env.CLAUDE_PROJECT_DIR || process.cwd())`. **`CLAUDE_PROJECT_DIR` wins over the working directory** — `cd`-ing into the worktree is not sufficient.
- `:54-60` `nextId()` returns `max(existing ids) + 1`, zero-padded to 3.
- `add` takes stdin JSON `{title, why, what, source, depends_on?, touches?, notes?, status?, doc?}` and prints one `{"ok":true,...}` line.
- `git show 381a0f63:ROADMAP.jsonl | grep -c ''` → **23** entries, ids `001`–`023`. Entry `004` is `Bluetooth output support`, `"status":"planned"`.

**UI test coupling** (`AudiouterRemoteUITests/CompanionSmokeUITests.swift`, verified exact): `:32-34` hardcoded screenshot dir; `:45` `createDirectory(withIntermediateDirectories: true)`; `:79-93` `attachAndSaveScreenshot`; `:99` `tabBar.buttons["Connection"]`; `:126` saves `01-speakers.png`; `:129-134` and `:177` `app.switches["Select Kitchen HomePod"]`; `:143` `navigationBars["Apps"].buttons["Add App"]`; `:159` `navigationBars["Groups"].buttons["Add Group"]`.

**Design values:** dark palette `doc:1686-1691` (= the CSS block `doc:14-21`); light palette `doc:1693-1699`. Micro-label *voice* `doc:36` (`ui-monospace / SF Mono`, uppercase, `letter-spacing:.09em`, weight 700) — **no size there**; sizes come from usages: 9.5 px at `doc:57`, `doc:72-73`, `doc:124`, `doc:195`, and 9 px at `doc:126`, `doc:197`; the measured Mac→iOS table gives 10 at `doc:1037`. Row geometry `doc:84-105`; row view-model `doc:1823-1866` (`showEdge` at `doc:1854`); drag maths `doc:1730-1794`; sections `doc:2000-2006`; deck `doc:121-142` (its background is `rgba(84,72,58,.48)` at `doc:122`); drawer `doc:188-217`; header `doc:55-65`. The design's mocks place "This Mac" in `ARMED / LIVE` (`doc:1940`, `doc:1998`, light mock `doc:310`) and never show it unarmed.

---

## Steps

### Step 0 — Fresh worktree (precondition for every track)

From the main checkout `/Users/alechenderson/Projects/AirPlay Controller`:
```bash
git worktree add ".claude/worktrees/ios-warm-signal-2a" -b claude/ios-warm-signal-2a claude/companion-app-phase2-ios
git -C ".claude/worktrees/ios-warm-signal-2a" rev-parse --short HEAD    # must print 381a0f63
```
All work happens there. Never `git commit`, `git push`, or `git add`. Never write in `.claude/worktrees/companion-app-phase2-ios` or the main checkout.

Export this once per shell in every later step:
```bash
export WT="/Users/alechenderson/Projects/AirPlay Controller/.claude/worktrees/ios-warm-signal-2a"
```

### Step 1 — New file: `AudiouterRemote/UI/Shared/WarmSignal.swift`

New `.swift` files under `AudiouterRemote/` need no project edit (`ios/AGENTS.md:12-20`). Begin with `// SPDX-License-Identifier: GPL-2.0-or-later`.

**UIKit has no `UIColor(hex:alpha:)` — write it here, in this file.** It is the only supporting helper this pass adds, and it must live in `WarmSignal.swift` (the one-new-file fence):
```swift
private extension UIColor {
    /// 0xRRGGBB → UIColor. The design's palettes are written as hex (doc:1686-1699).
    convenience init(rgb: UInt32, alpha: CGFloat) {
        self.init(red:   CGFloat((rgb >> 16) & 0xFF) / 255,
                  green: CGFloat((rgb >>  8) & 0xFF) / 255,
                  blue:  CGFloat( rgb        & 0xFF) / 255,
                  alpha: alpha)
    }
}
```

Then an enum namespace of `Color` statics, each a light/dark pair so appearance follows the system with no preference storage:
```swift
private func warm(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
    Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(rgb: dark, alpha: darkAlpha)
        : UIColor(rgb: light, alpha: lightAlpha) })
}
```

Ship all **24** tokens — dark from `doc:1686-1691`, light from `doc:1693-1699`. There is no `blur` token: the design's 26 px blur is delivered by `.ultraThinMaterial` instead (see `glassPanel` below).

| token | dark | light |
|---|---|---|
| `canvas` | `#16130F` | `#FBFBF9` |
| `canvasHi` | `#1B1712` | `#FBFBF9` |
| `panel` | `#1D1915` | `#FBFBF9` |
| `raised` | `#241F1A` | `#FBFBF9` |
| `well` | `#100D0A` | `#F5F4ED` |
| `hairline` | `#3A332B` | `#E7E6DF` |
| `label` | `#FFFFFF` @ .92 | `#1E1C1C` |
| `label2` | `#FFFFFF` @ .55 | `#706464` |
| `label3` | `#FFFFFF` @ .28 | `#76716B` |
| `gold` | `#E8B84B` | `#A97F1E` |
| `ember` | `#8A6A2F` | `#C2A05A` |
| `glow` | `#FFD97A` | `#E8B84B` |
| `ring` | `#8D7D5E` | `#A08C66` |
| `fail` | `#D9564A` | `#BB3A2F` |
| `caution` | `#E29A3D` | `#B3701C` |
| `thumb` | `#857762` | `#9E8D6B` |
| `thumbLow` | `#5F5546` | `#8A7A62` |
| `rim` | `#6B5F4E` | `#9E8D6B` |
| `meter` | `#4E463A` | `#CBBEA1` |
| `pill` | `#38322B` | `#D0CDC3` |
| `socket` | `#34302A` | `#E0D8C6` |
| `glass` | `#342D25` @ .52 | `#FAF7EE` @ .66 |
| `glassEdge` | `#FFFFFF` @ .11 | `#1E1C1C` @ .10 |
| `glassHi` | `#FFFFFF` @ .10 | `#FFFFFF` @ .80 |

(`thumb`/`thumbLow` are the fader thumb's gradient stops: dark `#857762 → #5F5546` at `doc:138`, light `#9E8D6B → #8A7A62` at `doc:366`.)

Also in this file:
- `static let canvasGradient: LinearGradient` — `canvasHi` → `canvas` at 44% → `canvas` (`doc:52`).
- `static let deckFill: Color` — the Main Out deck's own warm ground, `#54483A` @ .48 dark (`doc:122`) / `#FAF7EE` @ .78 light (`doc:350`). **Not a neutral grey.**
- `func microLabel(_ size: CGFloat = 9.5)` `ViewModifier` + `View.microLabel(_:)` extension: `.font(.system(size: size, weight: .bold, design: .monospaced))`, `.tracking(size * 0.09)`, `.textCase(.uppercase)`. Default 9.5 matches `doc:57/72/124/195`; pass `9` at the two places the design uses 9 px (`doc:126`, `doc:197`).
- `func readout(_ size: CGFloat)`: `.font(.system(size: size, weight: .bold, design: .monospaced))`, `.tracking(-0.4)`.
- `func glassPanel(cornerRadius: CGFloat, fill: Color = WarmSignal.glass)` `ViewModifier`: `fill` behind `.ultraThinMaterial` in a `RoundedRectangle(cornerRadius:)`, with a `.strokeBorder(WarmSignal.glassEdge, lineWidth: 0.5)` overlay.
- **The one shared fader arithmetic**, used by Step 3 and Step 7 — this is the symbol Step 7 refers to, no other:
  ```swift
  /// The design's row/deck drag maths (doc:1742, doc:1775): the value captured
  /// at gesture start, plus the fraction of the track the finger has crossed.
  static func faderValue(start: Int, translationWidth: CGFloat, trackWidth: CGFloat) -> Int {
      guard trackWidth > 0 else { return start }
      return min(100, max(0, Int((Double(start) + (translationWidth / trackWidth) * 100).rounded())))
  }
  ```
- One comment: `// razor: appearance follows the system. The design's accent dial and Dark/Light/Auto control (doc:644-671) are deferred — add a preference plus an environment override here when they land.`

### Step 2 — Gold accent across the app

Two edits, and an honest statement of what each does:

1. `AudiouterRemote/RootView.swift:125` — add `.tint(WarmSignal.gold)` to the `TabView`. This changes **tint-derived chrome only**: tab-bar selection, `Button`s, `NavigationLink` chevrons, `Picker` menus, toggles. It does **not** reach `Color.accentColor`, which resolves from the app accent (no asset catalog exists → system blue) and ignores the ancestor tint.
2. Therefore also replace the four explicit `Color.accentColor` literals with `WarmSignal.gold`: `UI/Groups/GroupsView.swift:54` (`.tint(.accentColor)`) and `UI/Groups/GroupIconPicker.swift:52`, `:55`, `:60`. Token swaps only — no other change to either file.

Adding an `AccentColor` asset catalog remains banned (see Out of scope); four token swaps are smaller than introducing a resource bundle.

Do **not** change the tab labels — `"Connection"` at `RootView.swift:150` stays. The design's "Connect" name and custom glass tab bar (`doc:143-175`) belong to a later pass, and keeping the label keeps `CompanionSmokeUITests.swift:99` and `:168` green untouched.

### Step 3 — Rewrite `AudiouterRemote/UI/Speakers/DeviceRowView.swift` as the fader row

Keep the type name, `let device: DeviceState`, `let session: any MacSessionProtocol`, and **all three statics byte-identical with their doc comments**: `showsFailureCard(_:)` (`:37-39`), `isControllable(_:appRoutes:)` (`:70-75`), `disabledReason(for:controllable:)` (`:84-87`). Ten tests at `SpeakerRowRulesTests.swift:122-206` depend on them. `DeviceRowView` is not fenced against `@State` — only `SpeakersView` is.

**The mute button is removed from the row** (base `DeviceRowView.swift:156-164`, `session.setDeviceMuted`). The design's row model has no mute (`doc:1823-1866`). It is **not** dropped from the product — Step 7 puts a mute control on every drawer row, so mute stays reachable in two taps and the `"MUTED"` sub-label below stays actionable.

**Derived values — define these; the rest of the step reads them.** None is stored state beyond what the gesture block declares:
```swift
private var controlsEnabled: Bool {
    Self.isControllable(device, appRoutes: session.snapshot?.appRoutes ?? [])
}
private var isLive: Bool {                                              // doc:1828
    device.isSelected && device.isAvailable
        && !Self.showsFailureCard(device) && device.connection.state != "connecting"
}
private var dragging: Bool { axis == .horizontal }                      // doc:1826
private var displayVolume: Int { Int((localVolume ?? Double(device.volume)).rounded()) }
private var volumeFraction: CGFloat { isLive ? CGFloat(displayVolume) / 100 : 0 }  // doc:1852
```

**Layout** (`doc:84-105`): `ZStack(alignment: .leading)`, `.frame(minHeight: 64)`, `.clipShape(RoundedRectangle(cornerRadius: 16))`, `.padding(.bottom, 2)`, content `HStack(spacing: 12)` with 12 pt horizontal padding. Read the row's width from a `GeometryReader` into a `@State private var rowWidth: CGFloat = 0` via `.onGeometryChange` (iOS 16+ in the iOS 27 SDK, fine at the 18.0 target) — that width is the fader track.

- **Wash** (back layer): width `volumeFraction × rowWidth`, `LinearGradient(colors: [gold.opacity(dragging ? 0.30 : 0.14), gold.opacity(dragging ? 0.17 : 0.06)], startPoint: .leading, endPoint: .trailing)` (`doc:1853`); width `0` unless the row is *live* (`doc:1852`).
- **Edge line**: 2 pt wide, `gold`, opacity `dragging ? 1 : 0.4`, at `x = volumeFraction × rowWidth − 1`; shown only when live (`doc:1854`, `doc:1855-1856`).
- **Row background** while dragging: `gold.opacity(0.06)` (`doc:1851`).
- **Halo**: 44×44 `Circle().fill(WarmSignal.raised)`, ring per `doc:1829-1832` — failed → 2.8 pt solid `fail`; `connection.state == "connecting"` → 2.5 pt **dashed** `ring`; live → 2.5 pt solid `ring`; otherwise none. Inside, `Image(systemName: device.iconSymbolName)` tinted `label3` unavailable / `label` live / `label2` otherwise (`doc:1848`).
- **Routed dot**: 11×11 circle bottom-trailing, 1.5 pt `canvas` border; `gold` + 8 pt `glow` shadow when routed, else `socket` (`doc:92`, `doc:1849-1850`). Routed = `session.snapshot?.appRoutes.contains { $0.destinationKind == "device" && $0.deviceID == device.id } == true`.
- **Name**: 16.5 pt, `.semibold` armed / `.regular` otherwise (`doc:1857`), `.tracking(-0.2)`, `.lineLimit(1)`, colour `label3` unavailable / `label` live / `label2` otherwise (`doc:1858`).
- **Sub-label**, `.microLabel()`, evaluated in this order (`doc:1833-1837` plus the muted case at `doc:1897`):
  1. `Self.showsFailureCard(device)` → `device.connection.failureHeadline ?? "CONNECTION FAILED"`, tint `fail`
  2. `!device.isAvailable` → `"UNAVAILABLE"`, tint `label3`
  3. `device.connection.state == "connecting"` → `"CONNECTING…"`, tint `ring`
  4. `device.isMuted` → `"MUTED"`, tint `label2`
  5. `device.isSelected` → `"LIVE"`, tint `gold`
  6. else → `"IDLE"`, tint `label3`
- **Readout**, trailing: `.readout(dragging ? 22 : 13)` (`doc:1863`); `"—"` when unavailable or failed, else `String(displayVolume)` — `displayVolume` is an `Int`, so this renders `"80"`, not `"80.0"` (`doc:1861`); tint `gold` live, else `label3` (`doc:1862`).
- Whole row `.opacity(device.isAvailable ? 1 : 0.45)` (`doc:1846`).

**Failure affordance.** When `Self.showsFailureCard(device)`, the readout slot is replaced by controls, not the number:
- If `device.connection.failureSuggestion != nil`, show a `Button("Diagnose")` at 12.5 pt `.semibold` in `gold` (`doc:345`) toggling `@State private var showFailureDetail`; expanded, render the suggestion at `.footnote` in `label2` beneath the row content.
- If it is `nil`, **no "Diagnose" button at all** — mirrors today's `if let` guard at `DeviceRowView.swift:201`.
- Either way, show `Button("Try Again") { session.retryConnection(id: device.id) }` beneath, keeping its existing `.accessibilityHint("Retry connecting to \(device.name)")`.

**Gesture — this is the hardest part; build exactly this.** SwiftUI has no equivalent of the design's CSS `touch-action: pan-y` (`doc:79`), and a plain `.gesture(DragGesture(minimumDistance: 0))` on a row inside a `ScrollView` wins arbitration outright and kills vertical scrolling. Use `.simultaneousGesture` plus an explicit axis latch, so the `ScrollView` keeps its own pan and the row only acts once the finger has committed horizontally.

```swift
private enum DragAxis { case horizontal, vertical }

@State private var axis: DragAxis?        // nil until the gesture commits
@State private var dragStartVolume: Int?  // captured at commit — doc:1755-1765
@State private var localVolume: Double?   // in-drag echo
```

```swift
.simultaneousGesture(
    DragGesture(minimumDistance: 0)
        .onChanged { value in
            let w = value.translation.width, h = value.translation.height
            if axis == nil {
                // 5 pt slop (doc:1739, doc:1773), then commit to one axis for
                // the rest of the gesture. Vertical commits are inert so the
                // enclosing ScrollView keeps the pan.
                guard max(abs(w), abs(h)) >= 5 else { return }
                axis = abs(w) > abs(h) ? .horizontal : .vertical
                if axis == .horizontal { dragStartVolume = device.volume }
            }
            guard axis == .horizontal, controlsEnabled, let start = dragStartVolume else { return }
            let v = WarmSignal.faderValue(start: start, translationWidth: w, trackWidth: rowWidth)
            localVolume = Double(v)
            session.setDeviceVolume(id: device.id, volume: v, isFinal: false)
        }
        .onEnded { _ in
            defer { axis = nil; dragStartVolume = nil }
            switch axis {
            case .horizontal:
                guard controlsEnabled else { return }
                session.setDeviceVolume(id: device.id,
                                        volume: Int((localVolume ?? Double(device.volume)).rounded()),
                                        isFinal: true)
                localVolume = nil                    // today's policy, DeviceRowView.swift:176-181
            case .vertical:
                return                               // the ScrollView handled it
            case nil:
                guard device.isAvailable else { return }
                session.setDeviceSelected(id: device.id, selected: !device.isSelected)  // doc:1792
            }
        }
)
```

`dragStartVolume` is captured at the commit, never re-based per tick. `displayVolume = localVolume ?? Double(device.volume)`.

**The `controlsEnabled` gate is the deliberate departure from `doc:1864`**, which attaches the drag unconditionally: when `Self.isControllable(device, appRoutes: session.snapshot?.appRoutes ?? []) == false` the drag is inert — nothing moves, nothing is sent. That is what keeps the ten enablement tests meaningful.

**Accessibility — required; this replaces the `Toggle` and the `Slider`. Two shapes, chosen by state.**

A *working* row collapses to one element, so VoiceOver reads it as the single control it now is. A *failed* row does **not** — it has no volume to adjust, and collapsing it would swallow the Diagnose and Try Again buttons entirely. Apply the whole block below only when `!Self.showsFailureCard(device)`; when the row is failed, leave its children as ordinary elements so both buttons stay reachable.

```swift
// working rows only — a failed row keeps its buttons as real, focusable elements
.accessibilityElement(children: .ignore)
.accessibilityAddTraits(.isButton)
.accessibilityLabel(device.name)
.accessibilityValue(device.isSelected ? "Armed" : "Not armed")
.accessibilityHint(hint)
.accessibilityAction { session.setDeviceSelected(id: device.id, selected: !device.isSelected) }
.accessibilityAdjustableAction { direction in
    guard controlsEnabled else { return }
    session.setDeviceVolume(id: device.id,
                            volume: min(100, max(0, device.volume + (direction == .increment ? 5 : -5))),
                            isFinal: true)
}
```

**`disabledReason` must still be spoken.** Today the reason rides on the two controls the rule disables (`DeviceRowView.swift:77-83`, `:98-101` `disabledClause`, consumed at `:164` and `:184`). Those controls are gone, so fold it into the row hint instead — do not let it become tested-but-unused:
```swift
private var hint: String {
    let base = "Double tap to \(device.isSelected ? "disarm" : "arm")."
    guard controlsEnabled else {
        // the rule's own words, e.g. "Select this speaker to change its volume"
        return [base, Self.disabledReason(for: device, controllable: false)].compactMap { $0 }.joined(separator: " ")
    }
    return base + " Swipe up or down to change volume."
}
```
A row you cannot adjust must not advertise a swipe that does nothing, and must say why — that is the behaviour `:77-83` documents and it may not regress.

The strings `device.name` and `"Armed"`/`"Not armed"` are load-bearing — Step 10's UI test asserts them.

`disabledClause` (`:98-101`) and `kindLabel` (`:143-152`) lose their only callers. Delete both; leaving dead private helpers behind is not "keeping the diff small".

Update the two `#Preview`s at `:223-246` so they compile.

### Step 4 — Rewrite `AudiouterRemote/UI/Speakers/SpeakersView.swift`

**`SpeakersView` keeps zero `@State` properties** (`SpeakerRowRulesTests.swift:95`; the invariant is documented at `SpeakersView.swift:8`). Do not widen it, do not touch the test.

Split the screen so presentation state has a legal home:
- **`SpeakersView`** — stateless shell: `WarmSignal.canvasGradient` `.ignoresSafeArea()`, the header, `StatusBanners(snapshot: session.snapshot)` unchanged, then either `SpeakerConsole(snapshot: snapshot, session: session)` when `session.snapshot != nil`, or the existing `ContentUnavailableView` from `:38-43`. Keeps `.toastOverlay(session.toasts)`. Drops `NavigationStack`/`.navigationTitle` — the design draws its own header (`doc:53-65`).
- **`private struct SpeakerConsole: View`**, same file — owns the sections, the deck and the drawer, and with them:
  ```swift
  @State private var collapsed: Set<String> = []   // the `= []` is required: State<Set<String>>
  @State private var drawerOpen = false            // has no init(), so without it `collapsed`
                                                   // becomes a memberwise-init parameter and
                                                   // SpeakerConsole(snapshot:session:) won't compile
  ```
  It is only constructed when a snapshot exists, so its state dies with the snapshot exactly the way `MainOutRow`'s echo does — which is precisely what the fenced test was protecting (`SpeakerRowRulesTests.swift:88-94`). The test needs no change and stays fenced.
  **Do not use `@GestureState` on `SpeakersView`** — `stateProperties(of:)` matches on the substring `"State<"`, so `GestureState<…>` would trip the fence too. (`@StateObject`/`@Environment`/`@Namespace` would not, but none is needed here.)

**Scroll container — named explicitly, because the whole gesture design in Step 3 depends on it.** `SpeakerConsole`'s sections live in:
```swift
ScrollView {
    LazyVStack(spacing: 0) { /* the five sections */ }
        .padding(.bottom, deckHeight + 16)   // the deck floats over this — see Step 5
}
```
`ScrollView` + `LazyVStack`, **not** `List`: every row is fully custom-drawn and `List`'s own cell chrome, separators and swipe handling would fight both the wash and the horizontal drag. `.simultaneousGesture` arbitration in Step 3 is specified against this container.

Add: `// razor: collapse state is in-memory only. The design wants it remembered per Mac (doc:1046), but the phone may not persist routing state (Model/MacSessionProtocol.swift:21-23); revisit if that rule changes.`

**Header** (`doc:55-65`), padding `.horizontal 18`, `.bottom 10`:
`"CONNECTED TO"` `.microLabel()` in `label2`; `"Speakers"` at 26 pt `.bold` `.tracking(-0.7)` in `label`; trailing, a glass pill (`Capsule`, `glassPanel`) with a 6 pt `gold` dot carrying a 6 pt `glow` shadow and `session.snapshot?.serverName ?? "No Mac"` at 12 pt `.medium`. When `session.isDemo`, append `" · Demo"` to that text — no second badge. When `session.connectionStatus != .live`, tint the dot `label3` and use the existing status vocabulary from `SpeakersView.swift:85-93` as the pill text.

**Sections** — exactly five, in this order (`doc:2000-2006`):

| Header | Membership | Tint |
|---|---|---|
| `PINNED` | always empty (no `isPinned` in the protocol) | `gold` |
| `ARMED / LIVE` | `isSelected && isAvailable` | `gold` |
| `AIRPLAY` | `!isSelected && isAvailable` | `label2` |
| `BLUETOOTH` | always empty | `label2` |
| `UNAVAILABLE` | `!isAvailable` | `label2` |

An available, unselected local Mac (`isLocalDevice`, `DemoMacSession.swift:121`) therefore lands under `AIRPLAY`. Accepted deliberately: the header is a category label from the design, and the row names and icons it "This Mac". The design never draws the unarmed case — its state seeds it armed (`doc:1715`, `armed: { hp:true, sonos:true, mac:true, … }`, rendered at `doc:310` with a `LIVE` sub-label at `:311`) and its AIRPLAY candidate lists exclude `mac` outright (`doc:1950`, `doc:1999`). Inventing a sixth section is a design decision this pass is not authorised to make.

Section header (`doc:70-75`): `.frame(height: 34)`; a 9×9 chevron of two 1.8 pt strokes rotated `-45°` open / `135°` closed; title `.microLabel()` in the tint above; member count `.microLabel()` in `label3`; then a 1 pt `hairline` rule filling the rest. The whole header is tappable and toggles that section in `collapsed`.

**Empty-section rule — one rule, uniform:** all five headers always render. `PINNED` and `BLUETOOTH`, when expanded, additionally render a single non-interactive 34 pt row, `.microLabel()` in `label3`, centred:
- `PINNED` → `"NO PINNED SPEAKERS"`
- `BLUETOOTH` → `"BLUETOOTH OUTPUT NOT AVAILABLE YET"`

The other three render nothing under an empty header — their count says it. **No fabricated device names, halos, levels or volume readouts anywhere.** Nothing in `PINNED` or `BLUETOOTH` may be mistakable for a real speaker. Above the Bluetooth case add:
`// razor: structural placeholder only. Nothing on the wire ever reports a Bluetooth output — DeviceState.kind is a free-form String (AudiouterProtocol CompanionSnapshot.swift:42) and the Mac never sends one. Tracked as roadmap 004.`
(Stated as a fact about the wire, not a compile-time fact: `ios/AGENTS.md:21-24` forbids this target from referencing `AudiouterCore` at all.)

### Step 5 — Main Out deck

Ownership and placement, decided here so nothing is left to invent:
- **`SpeakerConsole`** renders the deck container and its **header row** — it has the `snapshot` and owns `drawerOpen`.
- **`MainOutRow`** renders the **control row** (mute button + fader + readout) and nothing else, nested inside the deck container beneath the header row.
- **The deck floats; the list scrolls underneath it.** Attach it with `.overlay(alignment: .bottom)` on the `ScrollView`, **not** `.safeAreaInset(edge: .bottom)` — the inset would reserve space and stop the list above the deck, leaving the frosted glass blurring a blank background instead of passing content. Give the deck a fixed `deckHeight` constant and use that same value for the `LazyVStack`'s bottom padding (Step 4) so the last row can still be scrolled clear of it.

`MainOutRow` must keep `MainOutRow(masterVolume:isMuted:session:)` callable with exactly three arguments (`SpeakerRowRulesTests.swift:96-98`) and must keep `localVolume` among its `@State` (`:99`). Extra properties are fine as long as they carry defaults so the memberwise init keeps its three-argument form:

```swift
struct MainOutRow: View {
    let masterVolume: Int
    let isMuted: Bool
    let session: any MacSessionProtocol
    var onToggleMute: () -> Void = {}   // defaulted → the 3-arg init still compiles
    var onIdlePress: () -> Void = {}    // a press with no movement — raises the drawer

    @State private var localVolume: Double?
    @State private var isDragging = false
    @State private var trackWidth: CGFloat = 0
    static func thumbValue(local: Double?, server: Int) -> Double { local ?? Double(server) }
    ...
}
```
Keep `thumbValue` (`:142-144`), the release-hold policy and the `.onChange(of: masterVolume)` echo clear (`:180-186`), and the type doc comment at `:114-127` verbatim except for one added sentence noting the `Slider` became a drawn fader.

**`isDragging` must be driven by the new gesture — this is the one silent-bug trap in the whole plan.** At base it is set only by the `Slider`'s `onEditingChanged` (`:166-170`), which this step deletes. The `.onChange(of: masterVolume)` guard at `:180-186` reads it (`guard !isDragging else { return }; localVolume = nil`). If nothing sets it, it stays `false` forever, every incoming Main Out snapshot clears the echo mid-drag, and the thumb rubber-bands under the finger — exactly the regression documented at `SpeakersView.swift:121-127`. **No test catches this**: `SpeakerRowRulesTests.swift:96-99` only checks the property is *declared*. Set `isDragging = true` when the axis latch commits horizontally and `false` in `onEnded`, or delete the property and re-express the `:180-186` guard against the latch's own `axis`. Either is fine; leaving it unset is not.

**Deck container** (`doc:121-142`), `.padding(.horizontal, 14)`: `RoundedRectangle(cornerRadius: 26)`, `.glassPanel(cornerRadius: 26, fill: WarmSignal.deckFill)`, an inset top highlight in `glassHi`, `.shadow(color: .black.opacity(0.4), radius: 17, y: -10)`, padding 13/15/14.

**Header row** (in `SpeakerConsole`): `"MAIN OUT"` `.microLabel()` in `gold`; then `MainOutPicker` as the target name; then `"\(armedCount) ARMED"` `.microLabel(9)` in `label2` (`doc:126`); spacer; a 9×9 chevron rotated `-45°` closed / `135°` open, tappable, toggling `drawerOpen`.

Both derived on `SpeakerConsole`, no new state:
```swift
private var armedDevices: [DeviceState] { snapshot.devices.filter { $0.isSelected && $0.isAvailable } }
private var armedCount: Int { armedDevices.count }
private var master: Int { snapshot.mainOutMasterVolume }
```
`armedDevices` is the same list the `ARMED / LIVE` section renders (Step 4) and the same list the drawer renders (Step 7) — derive it once here and pass it down.

**Control row** (in `MainOutRow`):
- Mute button 38×38, `RoundedRectangle(cornerRadius: 13)` filled `well` with a 0.5 pt `rim` border, `Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")` in `label2`, action `onToggleMute`. `SpeakerConsole` passes `{ session.setMainOutMuted(!snapshot.mainOutMuted) }` — `MainOutRow` has no `snapshot`, only `isMuted`.
- Fader in a 44 pt hit slab (`doc:1036`): track 18 pt `Capsule` filled `well`, 1 pt `rim` border, inset shadow; fill 16 pt, `LinearGradient(ember → gold)`, width `master/100 × trackWidth`; thumb 38×38 `RoundedRectangle(cornerRadius: 13)`, `LinearGradient(thumb → thumbLow)`, 1 pt `rim` border, drop shadow, centred on the fill's end.
- Readout `.readout(16)` in `gold`, `.frame(width: 26, alignment: .trailing)`.
- Gesture (`doc:1730-1749`): the **same** axis-latch shape as Step 3, over `trackWidth`, using `WarmSignal.faderValue`. Horizontal commit → `setMainOutMasterVolume(..., isFinal: false)` per tick, `isFinal: true` on release, echo held (do **not** clear `localVolume` on release — that is `MainOutRow`'s documented difference at `:174-178`). No commit at all (a press under 5 pt) → call `onIdlePress()`.
- Accessibility: `.accessibilityLabel("Main Out volume")`, `.accessibilityValue("\(Int(Self.thumbValue(local: localVolume, server: masterVolume))) percent")`, and an `.accessibilityAdjustableAction` in 5-point steps — the removed `Slider` gave this for free and it must not regress.

### Step 6 — `AudiouterRemote/UI/Speakers/MainOutPicker.swift`: menu style

Keep `Target` (`:13-16`), `current` (`:18-24`) and the whole `Picker` expression (`:27-42`) verbatim, including `.accessibilityHint(...)` at `:43`. Add only, after `:42`: `.pickerStyle(.menu)`, `.labelsHidden()`, `.tint(WarmSignal.label)`, `.font(.system(size: 15, weight: .semibold))` — so it renders as the deck header's tappable target name.

### Step 7 — Main Out drawer (on `SpeakerConsole`)

Per `doc:188-217`, driven by `SpeakerConsole`'s `drawerOpen`:
- Scrim `Color(red: 8/255, green: 6/255, blue: 4/255).opacity(0.5)`, full-bleed, tap to dismiss.
- Panel inset 10 pt horizontally, directly above the deck; `RoundedRectangle(cornerRadius: 28)`, `.glassPanel(cornerRadius: 28, fill: WarmSignal.panel)`, padding 16/14/12.
- Grabber 38×4 `Capsule` in `label3`, centred, 14 pt below.
- Header: `"ACTIVE DEVICES"` `.microLabel()` in `gold`, spacer, `"DRAG TO ADJUST"` `.microLabel(9)` in `label2` (`doc:197`).
- Rows: one per device in `armedDevices` (Step 5). Corner radius 14, padding 10/12, `well` fill, 0.5 pt `rim` border; wash `LinearGradient(ember → gold).opacity(0.30)` to `volume%`; 2.5 pt `glow` edge line; a 24×24 `ring` circle; name at 14.5 pt in `label`; `.readout(14)` in `gold`.
  (The design's own drawer list is `['hp'].concat(armed2)` at `doc:2007` — its pinned device plus the armed ones. Here the `PINNED` section is always empty, so that reduces to the armed devices.)
- **Mute lives here.** Each drawer row gets a leading 28×28 mute button — `RoundedRectangle(cornerRadius: 9)` filled `well`, 0.5 pt `rim` border, `Image(systemName: device.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")` in `label2`, tinted `gold` when muted — calling `session.setDeviceMuted(id: device.id, muted: !device.isMuted)`. This is the replacement for the per-row mute button Step 3 removes (`DeviceRowView.swift:156-164`): mute stays two taps away and the row's `"MUTED"` sub-label stays actionable. Verify the exact `setDeviceMuted` signature on `MacSessionProtocol` before writing the call; if it differs, use what is there and say so.
- Drag: the **same axis latch as Step 3**, calling **`WarmSignal.faderValue(start:translationWidth:trackWidth:)`** from Step 1 — that is the only shared symbol, no new file or helper type. Same `DeviceRowView.isControllable` gate.
- Accessibility per drawer row: `.accessibilityLabel(device.name)`, `.accessibilityValue("\(volume) percent")`, `.accessibilityAdjustableAction` in 5-point steps. The mute button keeps its own element with `.accessibilityLabel(device.isMuted ? "Unmute \(device.name)" : "Mute \(device.name)")`.
- Transition `.move(edge: .bottom).combined(with: .opacity)`, `.animation(.spring(duration: 0.25), value: drawerOpen)`.

### Step 8 — Sanity build

```bash
cd "$WT"
xcodebuild -project ios/AudiouterRemote/AudiouterRemote.xcodeproj -scheme AudiouterRemote \
  -destination 'generic/platform=iOS Simulator' build
```
Must print `** BUILD SUCCEEDED **` before continuing.

### Step 9 — `ios/AGENTS.md:47`: fix the stale simulator name

`-destination 'platform=iOS Simulator,name=iPhone 17'` → `'platform=iOS Simulator,name=iPhone 17 Pro Max'`. In the prose at `:41-44`, replace "today that's the iPhone 17 family" with the three that exist: `iPhone 17 Pro Max`, `iPhone 17e`, `iPhone Air`. Nothing else in that file changes.

### Step 10 — `AudiouterRemoteUITests/CompanionSmokeUITests.swift`: two assertions

| Line | Assertion | Verdict |
|---|---|---|
| `:99`, `:168` | `tabBar.buttons["Connection"]` | **Unchanged.** Step 2 keeps the stock `TabView` and the `"Connection"` label. |
| `:129-134` | `app.switches["Select Kitchen HomePod"]` | **Updated** — the `Toggle` is gone. |
| `:177` | same switch re-read after navigation | **Updated** to match. |
| `:143` | `navigationBars["Apps"].buttons["Add App"]` | **Unchanged** — `AppsView.swift:20-29` untouched. |
| `:159` | `navigationBars["Groups"].buttons["Add Group"]` | **Unchanged** — `GroupsView.swift:67-75` untouched. |
| `:124`, `:138`, `:154`, `:169` | `anyElement(containing:)` substring matches | **Unchanged** — those names still render. |

Replace `:128-134` with:
```swift
// Interaction: tap a speaker row to arm it (the row IS the control now —
// the Select switch was replaced by row-as-fader).
let homePodRow = app.buttons["Kitchen HomePod"]
XCTAssertTrue(homePodRow.waitForExistence(timeout: 5))
let beforeToggle = homePodRow.value as? String
homePodRow.tap()
let afterToggle = homePodRow.value as? String
XCTAssertNotEqual(beforeToggle, afterToggle, "Tapping the Kitchen HomePod row should flip it between armed and not armed")
```
and `:177` with `let persistedToggle = app.buttons["Kitchen HomePod"].value as? String`. Leave the message at `:178-179`. Do **not** change the screenshot directory at `:32-34`. Add no tests. Do not touch `SpeakerRowRulesTests.swift`.

### Step 11 — Full test run

```bash
cd "$WT"
xcodebuild test -project ios/AudiouterRemote/AudiouterRemote.xcodeproj -scheme AudiouterRemote \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' 2>&1 | tee /tmp/ios-warm-signal-test.log
grep -E "✘|Test run with|Executed .* test" /tmp/ios-warm-signal-test.log
```

### Step 12 — Seven roadmap entries — ✅ ALREADY DONE, SKIP

**These were filed on 2026-08-08 when this handoff was prepared, and are already committed on this branch as `025`–`031`** (alongside `024`, this pass itself). `ROADMAP.jsonl` here has 31 entries, not the base's 23.

**Do not run this step.** Verify and move on:
```bash
grep -c '' ROADMAP.jsonl        # expect 31
python3 -c "import json;[print(json.loads(l)['id'], json.loads(l)['title']) for l in open('ROADMAP.jsonl') if l.strip() and json.loads(l)['id'] >= '024']"
```
If those seven are missing, something has gone wrong with the branch — stop and report rather than re-adding them.

The rest of this step is kept only as the record of how they were filed and what they cover.

<details>
<summary>Original Step 12 (executed already — reference only)</summary>

**Mechanism.** `roadmap.js:8-10` resolves `CLAUDE_PROJECT_DIR` **before** the working directory, so `cd` alone is not enough. Set it explicitly on every invocation:

```bash
export CLAUDE_PROJECT_DIR="$WT"
cd "$WT"
echo '{...}' | node /Users/alechenderson/.claude/plugins/cache/foundry/foreman/0.46.0-alpha/scripts/roadmap.js add
```

**Stop-check — count lines, do not read `git status`.** The main checkout's `ROADMAP.jsonl` is *already* modified by another session, so ` M` there proves nothing either way. Take a count before the first add and compare after:
```bash
MAIN="/Users/alechenderson/Projects/AirPlay Controller"
BEFORE_MAIN=$(grep -c '' "$MAIN/ROADMAP.jsonl")
BEFORE_WT=$(grep -c '' "$WT/ROADMAP.jsonl")     # expect 23
# ... run the first add ...
[ "$(grep -c '' "$WT/ROADMAP.jsonl")" -eq $((BEFORE_WT + 1)) ] || { echo "FAIL: worktree roadmap did not grow"; exit 1; }
[ "$(grep -c '' "$MAIN/ROADMAP.jsonl")" -eq "$BEFORE_MAIN" ]   || { echo "FAIL: wrote to the MAIN checkout"; exit 1; }
```
If the main checkout's count grew, STOP before running the remaining six: delete exactly the appended line with an editor (**never** `git checkout` / `git restore` that file — another session has uncommitted work in it), confirm the count is back to `$BEFORE_MAIN`, and report.

**Ids — no collision, but check before asserting one.** Base has 23 entries, ids `001`–`023` (`git show 381a0f63:ROADMAP.jsonl | grep -c ''` → 23), and `roadmap.js:54-60` assigns `max+1`, so these seven become `024`–`030`. Main's roadmap currently holds `001`–`023`, `025`–`032`, `034`–`039` — so `024` is **free** and `033` is free; only `025`–`030` are taken by different tasks there. Add all seven anyway; report the overlap as a merge-time renumber for the user. Re-derive main's id set at execution time rather than repeating that list — other sessions add entries. Do not hand-edit ids, do not skip entries to dodge it.

Every entry: `"source": "user"`, `"doc": "none"`, omit `status`. Each `why` states plainly that the iOS design document `Audiouter Remote - iOS Design System.dc.html` draws this element but the companion protocol carries no data for it, and names the files that would change; `touches` lists those files.

| # | title | element | files to name |
|---|---|---|---|
| 1 | Pinned speakers in the companion protocol | `PINNED` section (`doc:1045`) + "Pin to top" (`doc:770-773`) | `AudiouterProtocol/Sources/AudiouterProtocol/CompanionSnapshot.swift` (`isPinned` on `DeviceState`), `CompanionCommand.swift` (`setDevicePinned`), `AudiouterCore/Sources/AudiouterCore/CompanionSnapshotBuilder.swift`, `CompanionCommandDispatcher.swift`. Note the phone may not persist it (`ios/.../MacSessionProtocol.swift:21-23`). |
| 2 | Per-device output level in the companion snapshot | live meter (`doc:98-102`, `doc:1860`) | `CompanionSnapshot.swift`, `CompanionSnapshotBuilder.swift` |
| 3 | Rename and re-icon a speaker from the phone | `doc:739`, `doc:776-778` | `CompanionCommand.swift`, `CompanionCommandDispatcher.swift` |
| 4 | Structured failure diagnosis for the companion | `doc:812-844` — checklist + Mac IP + last-seen, replacing the two free-text strings at `CompanionSnapshot.swift:29-31` | `CompanionSnapshot.swift`, `CompanionSnapshotBuilder.swift` |
| 5 | Report companion link latency to the phone | `PAIRED · 3 MS LINK` (`doc:599`) | `CompanionSnapshot.swift`, `AudiouterCore/Sources/AudiouterCore/CompanionServer.swift`, `CompanionSnapshotBuilder.swift` |
| 6 | User-ordered groups | drag handle to reorder (`doc:493`) | `CompanionSnapshot.swift` (order on `GroupState`), `CompanionCommand.swift`, `CompanionCommandDispatcher.swift` |
| 7 | Mute a single app's route from the phone | tap-to-mute (`doc:1819`) | `CompanionCommand.swift` (`setAppMuted`), `CompanionSnapshot.swift` (`AppRouteState.isMuted`), `CompanionCommandDispatcher.swift` |

**No Bluetooth entry** — that is roadmap `004`, already present and `planned`. Do not add one; do not edit `004`.

</details>

### Step 13 — Screenshots, both grounds

The UI smoke test saves `01-speakers.png` (`CompanionSmokeUITests.swift:126`) into the hardcoded dir at `:32-34`, which belongs to **another session's scratchpad** and already holds a pre-change `01-speakers.png` from earlier today. Delete before each run, check exit codes, and copy the artefacts out to this session's scratchpad — leave nothing new in theirs.

```bash
set -euo pipefail
# SHOTS is hardcoded in CompanionSmokeUITests.swift:32-34 — read it out of the source rather
# than pasting it, because it is an absolute path baked in by an older session and may drift.
SHOTS=$(sed -n '32,34p' ios/AudiouterRemote/AudiouterRemoteUITests/CompanionSmokeUITests.swift \
        | grep -o '/[^"]*' | head -1)
test -n "$SHOTS" || { echo "FAIL: could not read the screenshot dir from CompanionSmokeUITests.swift:32-34"; exit 1; }

# OUT is YOUR session's scratchpad — substitute it. Anywhere writable outside the repo works.
OUT="${CLAUDE_SCRATCHPAD:?set OUT to your own scratchpad directory before running this}"
cd "$WT"; mkdir -p "$OUT"

xcrun simctl boot "iPhone 17 Pro Max" 2>/dev/null || true; sleep 5

# Move the other session's existing screenshots aside rather than deleting them —
# never destroy another session's artefacts. They go back at the end.
STASH="$OUT/other-session-shots"; mkdir -p "$STASH"
for f in "$SHOTS"/*.png; do [ -e "$f" ] && mv "$f" "$STASH/"; done

for MODE in dark light; do
  rm -f "$SHOTS/01-speakers.png"                      # ours from the previous loop pass only
  xcrun simctl ui booted appearance "$MODE"
  xcodebuild test -project ios/AudiouterRemote/AudiouterRemote.xcodeproj -scheme AudiouterRemote \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
    -only-testing:AudiouterRemoteUITests 2>&1 | tail -20   # exit code propagates via pipefail
  test -f "$SHOTS/01-speakers.png" || { echo "FAIL: no screenshot produced for $MODE"; exit 1; }
  mv "$SHOTS/01-speakers.png" "$OUT/speakers-$MODE.png"    # move, don't copy — leave their dir clean
done

xcrun simctl ui booted appearance dark

# put the other session's screenshots back exactly as they were
for f in "$STASH"/*.png; do [ -e "$f" ] && mv "$f" "$SHOTS/"; done
rmdir "$STASH" 2>/dev/null || true

ls -la "$OUT"/speakers-*.png
```
If either `xcodebuild` fails, `set -e` + `pipefail` stops the script — do not proceed to grading. Note `xcrun simctl ui booted appearance` mutates simulator state shared with any other session running UI tests; the final line restores `dark`.

Then **read both PNGs** and report each of these six explicitly:
1. Dark shot has the warm near-black canvas (`#16130F` family), not system grey.
2. Light shot has the paper ground (`#FBFBF9` family) with the `#1E1C1C` ink title, and its gold is the darker `#A97F1E`, not the dark ground's `#E8B84B`.
3. All five section headers present, in order: PINNED, ARMED / LIVE, AIRPLAY, BLUETOOTH, UNAVAILABLE.
4. PINNED and BLUETOOTH show their placeholder micro-label, not device-shaped rows.
5. At least one armed row shows a gold wash and its numeric readout.
6. The Main Out deck sits above the tab bar, with its fader and gold readout, on the warm `deckFill` ground (not grey).

Any of the six not visibly true is a failure — report it, do not paper over it.

---

## Out of scope — do not touch

- `UI/Apps/` (all 4 files), `UI/Connect/` (all 6), `UI/Shared/ToastBanner.swift`, `UI/Shared/ToastCenter.swift`, `UI/Speakers/StatusBanners.swift`, `Model/`, `Networking/`, `AudiouterRemoteApp.swift`. In `UI/Groups/`: **`GroupEditorView.swift` is entirely out of scope**, and in the other two files **only** the four `Color.accentColor` → `WarmSignal.gold` token swaps named in Step 2 (`GroupsView.swift:54`, `GroupIconPicker.swift:52,55,60`) — nothing else in either.
- The one sanctioned deletion inside a file being rewritten: `DeviceRowView`'s now-callerless `disabledClause` (`:98-101`) and `kindLabel` (`:143-152`), per Step 3. No other dead-code removal anywhere.
- `AudiouterProtocol/` and everything under `AudiouterCore/` — no protocol fields, no commands, no Mac-side work. That is what Step 12 tracks.
- `AudiouterRemote.xcodeproj/project.pbxproj` and `xcshareddata/xcschemes/AudiouterRemote.xcscheme` — forbidden by `ios/AGENTS.md:12-20`, and another session has both open. New `.swift` files need no project edit. If anything seems to require a pbxproj edit, STOP.
- **No asset catalog.** Do not add `Assets.xcassets`, an `AccentColor` colour set, or any resource bundle. Step 2's four token swaps are the sanctioned alternative.
- **`AudiouterRemote/Info.plist`** — in particular do not set `UIUserInterfaceStyle`. Forcing an appearance would defeat Step 13's dark/light comparison outright.
- `AudiouterRemoteTests/` — all five files, including `SpeakerRowRulesTests.swift`. `zzDebugDump` stays failing; the zero-`@State` fence on `SpeakersView` stays as written (Step 4 satisfies it by construction, not by editing it).
- `CompanionSmokeUITests.swift:32-34`, `:143`, `:159`, and the `"Connection"` tab label at `RootView.swift:150`.
- Repo-root `AGENTS.md`, `CLAUDE.md`, `PROGRESS.md`, `docs/`, `.githooks/`, `scripts/`. The only doc edit is `ios/AGENTS.md:41-47` (Step 9). `ROADMAP.jsonl` is written only through `roadmap.js add` in the worktree (Step 12) — never hand-edited.
- Design sections `2b`'s Appearance UI, `2c`, `2d`, `2e`, `2f`, `2g`, `1f` — including the long-press multi-select at `doc:1761-1764` and the per-row meter at `doc:98-102`.
- No cleanup, no abstractions, no error handling for impossible cases, no backwards-compat shims. No refactor of `MacSessionProtocol`, `DemoMacSession`, or `RemoteSession`. No new dependency.
- **New files:** the only new file this pass creates is `AudiouterRemote/UI/Shared/WarmSignal.swift`. Any further new file is out of scope — if a step seems to need one, STOP and report.
- **Never** `git commit`, `git push`, `git add`, `git stash`, `git checkout <file>`, or `git restore`. Everything stays uncommitted. Never write in `.claude/worktrees/companion-app-phase2-ios` or in the main checkout.

---

## Verification

Run in the fresh worktree; paste real output for each.

**1. Build**
```bash
xcodebuild -project ios/AudiouterRemote/AudiouterRemote.xcodeproj -scheme AudiouterRemote \
  -destination 'generic/platform=iOS Simulator' build
```
Expect `** BUILD SUCCEEDED **`. *Baseline observed this session: `** BUILD SUCCEEDED **`.*

**2. Tests**
```bash
xcodebuild test -project ios/AudiouterRemote/AudiouterRemote.xcodeproj -scheme AudiouterRemote \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'
```
Expect exactly the baseline: `Test run with 110 tests in 6 suites failed ... with 1 issue`, that issue being `✘ Test zzDebugDump() recorded an issue at SpeakerRowRulesTests.swift:81:9`, and the XCUITest suite reporting `Executed 1 test, with 0 failures`. **Any second failure, or a count other than 110, is ours** — in particular a failure in `theMainOutDragEchoCannotOutliveTheRowItBelongsTo` means Step 4's split was not honoured and `SpeakersView` gained `@State`. *Baseline observed this session: 110 tests / 1 issue / `zzDebugDump`; UI test passed in 89.730 s.*

**3. Screenshots** — paste `$OUT/speakers-dark.png` and `$OUT/speakers-light.png` absolute paths plus the six-point confirmation from Step 13. Confirm `ls "$SHOTS"` shows no `speakers-*.png` and no `01-speakers.png` left behind in the other session's directory.

**4. Roadmap** — nothing to run (Step 12 is already done). Just paste `grep -c '' ROADMAP.jsonl` → **31** and confirm ids `024`–`031` are present and untouched by your work.

*Merge note for whoever lands this branch:* main's roadmap currently uses `024`–`032` and `034`–`039` for different tasks, so ids `024`–`031` here **will** collide at merge and need renumbering. Re-derive main's id set at merge time — other sessions keep adding.

**5. Nothing committed** — `git -C "$WT" log --oneline -1` still `381a0f63`, plus `git -C "$WT" status --short`.

Done = 1–5 all produced in the executor's session, with output pasted.

---

## Execution plan

**Step 0 is already done** — you are reading this *inside* `.claude/worktrees/ios-warm-signal-2a`, branch `claude/ios-warm-signal-2a`, cut from `claude/companion-app-phase2-ios` @ `381a0f63`. Set `export WT="$(git rev-parse --show-toplevel)"` and skip to Track A.

**Track B is already done** — the seven roadmap entries are filed and committed (see Step 12). Two tracks remain, A then C.

**Track A — token layer + Speakers redesign.** Steps 1–8. Files: `AudiouterRemote/UI/Shared/WarmSignal.swift` (new — the only new file), `AudiouterRemote/UI/Speakers/SpeakersView.swift`, `AudiouterRemote/UI/Speakers/DeviceRowView.swift`, `AudiouterRemote/UI/Speakers/MainOutPicker.swift`, `AudiouterRemote/RootView.swift`, `AudiouterRemote/UI/Groups/GroupsView.swift` (one token), `AudiouterRemote/UI/Groups/GroupIconPicker.swift` (three tokens).
**Model: opus · Effort: high.** Hand-drawn instrument layout, a drag gesture that must coexist with a `ScrollView` under an axis latch, a six-branch state machine, and a zero-`@State` fence plus a three-argument init and a `Mirror`-inspected property list that must all survive.

**Track B — roadmap entries.** Step 12. Files: `ROADMAP.jsonl`.
**Model: haiku · Effort: low.** Seven mechanical stdin-JSON invocations from a filled-in table, plus one stop-check.

**Track C — test + docs follow-up.** Steps 9–10. Files: `ios/AGENTS.md`, `AudiouterRemoteUITests/CompanionSmokeUITests.swift`.
**Model: sonnet · Effort: low.**

**Concurrency: Step 0 → (A ∥ B) → C → Verification.**
- A's seven files all sit under `ios/AudiouterRemote/AudiouterRemote/`; B's single file is `ROADMAP.jsonl` at the worktree root. Fully disjoint, and neither consumes the other's output once Step 0 exists — safe in parallel.
- C is serialized after A. Its files (`ios/AGENTS.md`, `AudiouterRemoteUITests/CompanionSmokeUITests.swift`) are disjoint from both, but its assertion rewrite depends on Track A actually shipping the `device.name` / `"Armed"` / `"Not armed"` accessibility contract. Serialize — a red UI test costs more than the two minutes saved.
- Verification (Steps 11 + 13 + all five checks) runs once, on the combined tree, after all tracks finish.

---

## Executor rules (copy verbatim into the handoff prompt)

> - Follow the steps in order. Do not add, merge, reorder, or skip steps.
> - If reality contradicts a Verified fact or a step is impossible as written, STOP and report the discrepancy. Do not improvise a workaround.
> - Before reporting progress, audit each claim against a tool result from this session. Only report work you can point to evidence for. If tests fail, say so with the output.
> - "Done" means the Verification commands were run in this session and passed. Paste their output.
> - Touch nothing in the Out-of-scope list.
> - Never run `git commit`, `git push`, or `git add`. Creating the worktree is fine; committing into it is not. All work stays uncommitted for the user to review.
> - Deliver what was asked, at the scope intended. If the spec seems mistaken or a better approach exists, say so in a sentence and continue as specified rather than quietly narrowing, widening, or transforming it.

---

# Appendix A — what two spec checks already verified

Both checks read the base commit via `git show 381a0f63:<path>`. **Do not spend tokens re-verifying these.**
If one turns out to be wrong at execution time, that is a genuine discrepancy — stop and report it, per the
executor rules.

## Language and framework mechanics

- **The zero-`@State` fence works as designed.** `stateProperties(of:)`
  (`AudiouterRemoteTests/SpeakerRowRulesTests.swift:66-73`) is `Mirror(reflecting:).children` — one level,
  stored properties of the value handed in. A `SpeakerConsole` built inside `body` is not a stored property of
  `SpeakersView`, so its `@State` is invisible to `#expect(stateProperties(of: SpeakersView(...)).isEmpty)` at
  `:95`. Step 4's split satisfies the test without editing it.
  *Trip-wire:* the filter matches the substring `"State<"`, so `@GestureState` on `SpeakersView` would also
  trip it. `@StateObject` / `@Environment` / `@Namespace` would not.
- **`MainOutRow`'s three-argument init survives the added closures.** SE-0242 gives `var` properties with
  initial values a default argument in the memberwise init, in declaration order, so
  `MainOutRow(masterVolume:isMuted:session:)` stays callable with `onToggleMute`/`onIdlePress` declared after
  them with `= {}`. Trailing `private @State` does not lower it — already proven at base, where the same call
  at `:96-98` compiles past `localVolume` and `isDragging`.
- **Extra `@State` on `MainOutRow` is safe.** `:96-99` asserts only `.contains("localVolume")`, not an exact
  property set.
- **The Step 3 gesture is legal Swift.** `onGeometryChange(for:of:action:)` is `@available(iOS 16.0…)` in the
  iOS 27 SDK, fine at the 18.0 deployment target. `switch` over `Optional<DragAxis>` with
  `.horizontal` / `.vertical` / `nil` is exhaustive. `defer` runs at scope exit, i.e. **after** the switch
  body — `dragStartVolume` and `axis` are still readable inside it.

## API surface — all confirmed present at base

`MacSessionProtocol` (`ios/AudiouterRemote/AudiouterRemote/Model/MacSessionProtocol.swift`): `snapshot`,
`isDemo`, `toasts`, `connectionStatus` (`:34`), `setDeviceSelected(id:selected:)`,
`setDeviceVolume(id:volume:isFinal:)`, `setMainOutMuted(_:)`, `setMainOutMasterVolume(_:isFinal:)` (`:50`),
`retryConnection(id:)`. Phone-side persistence ban at `:21-23`.
`MacConnectionState` is `Equatable` (`Networking/MacConnection.swift:20-27`), so `!= .live` compiles.

`DeviceRowView` statics, signatures exact: `showsFailureCard(_ device: DeviceState) -> Bool` (`:37-39`);
`isControllable(_ device: DeviceState, appRoutes: [AppRouteState]) -> Bool` (`:70-75`);
`disabledReason(for device: DeviceState, controllable: Bool) -> String?` (`:84-87`). Ten tests at
`SpeakerRowRulesTests.swift:122-206` depend on them.

Protocol model (`AudiouterProtocol/Sources/AudiouterProtocol/CompanionSnapshot.swift`): `DeviceState` `:39-52`
with all eight fields Step 3 reads, `kind` a plain `String` at `:42`; `ConnectionInfo` `:28-31` with
`failureHeadline`/`failureSuggestion` both `String?`; `AppRouteState.destinationKind: String` and
`deviceID: String?` at `:136-138`; `Snapshot.serverName` `:202`, `mainOutMasterVolume` `:205`,
`mainOutMuted` `:206`.

`.accessibilityHint("Retry connecting to \(device.name)")` verbatim at `DeviceRowView.swift:217`.
`.toastOverlay(session.toasts)` in use at `SpeakersView.swift:49`.

## The two echo policies are genuinely opposite, and both citations are right

`DeviceRowView.swift:176-181` **clears** the in-drag echo on release (`localVolume = nil` at `:180`).
`SpeakersView.swift:174-178` is the comment explaining that `MainOutRow` deliberately **holds** it instead.
Step 3 and Step 5 specify them accordingly. They are not swapped.

## Roadmap tooling

`scripts/roadmap.js` in the foreman plugin cache: `:8-10` `projectDir()` is
`path.resolve(process.env.CLAUDE_PROJECT_DIR || process.cwd())` — **the env var wins over `cd`**, which is why
Step 12 exports it. `:54-60` `nextId()` is max+1, zero-padded. `source:"user"` and `doc:"none"` both validate;
omitting `status` defaults to `planned`. `cmdAdd` does not stage the file, so no stray `git add`.

Base has 23 entries, ids `001`–`023`. Seven adds → `024`–`030`, final count 30.

## Environment

Xcode 27.0 (27A5228h). Available iOS 27.0 iPhone simulators: `iPhone 17 Pro Max`, `iPhone 17e`, `iPhone Air`
— **no plain `iPhone 17`**. `scripts/build.sh` does not exist on this branch and
`grep -c xcodebuild scripts/run-tests.sh` → `0`, so the repo's remote-Mac build routing does not apply to the
iOS target: raw `xcodebuild` is the only path, exactly as `ios/AGENTS.md:33-48` says.

---

# Appendix B — defects found and fixed after the second check

Recorded so nobody reintroduces them. All are already corrected in the steps above.

1. `UIColor(hex:alpha:)` does not exist in UIKit — Step 1 now writes the initializer.
2. `isDragging` in `MainOutRow` was left with no writer after the `Slider` was deleted, which would have
   shipped the rubber-band regression `SpeakersView.swift:121-127` documents. **No test catches this.** Step 5
   now requires the axis latch to drive it.
3. `dragging`, `controlsEnabled`, `volumeFraction`, `displayVolume`, `armedCount`, `master` were all read and
   never defined — Steps 3 and 5 now define each.
4. `@State private var collapsed: Set<String>` had no default, which would have made it a required
   memberwise-init parameter and broken the call site. Now `= []`.
5. `String(displayVolume)` on a `Double` rendered `"80.0"`. `displayVolume` is now an `Int`.
6. The scroll container was never named, though the entire gesture design depends on it. Now explicitly
   `ScrollView` + `LazyVStack`, with the reason `List` was rejected.
7. `.accessibilityElement(children: .ignore)` on every row would have hidden the failure buttons from
   VoiceOver. Now conditional on the row not being failed.
8. `disabledReason` would have become tested-but-unused, silently regressing what a VoiceOver user is told
   about a row they cannot adjust. Now folded into the row hint.
9. Per-device mute was being deleted with no replacement. Now on the drawer rows.
10. Step 12's stop-check read `git status`, which cannot distinguish our write from the other session's
    pre-existing modification. Now a line-count comparison.
11. The claimed roadmap id collision was wrong — main holds `001`–`023`, `025`–`032`, `034`–`039`, so `024`
    and `033` are free. Step 12 now says to re-derive it at execution time rather than trusting a snapshot.
12. Step 13 `rm -f`'d another session's screenshots. Now moves them aside and restores them.
13. Three design-doc citations pointed at lines that did not carry the claim (`doc:2007` for the drawer's
    contents; `doc:1940`/`doc:1998` for "This Mac" being armed). Corrected to `doc:1715`, `doc:1950`,
    `doc:1999`, `doc:310`.
14. `GroupEditorView.swift` was unfenced; the dead `disabledClause`/`kindLabel` had no stated disposition;
    `xcrun simctl ui booted appearance` mutates state shared with other sessions. All now covered.
