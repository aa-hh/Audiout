# PR 6 work order: Settings and About (and `ProminentButton`)

Executor: Opus. Surface: `AudioutSettingsUI` (Settings is a SCREEN inside the one surface —
`SettingsRootViewController` hosted by `AppSurfaceController`, sidebar + pane; only About keeps its
own window, `AboutView.swift:112` `windowWidth = 460`).

Every path is relative to the worktree root. All facts were checked at `586bd8a2` (PR 1 committed)
on 2026-09-03. Every ratio quoted below is PR 1's measured value, cited to its table — recompute
nothing.

**PR 6 merges BEFORE PR 7.** PR 6 owns `ProminentButton` wholesale (D1); PR 7 consumes the result.

## Goal

Settings gains three things: the licence sheet's Register button becomes the same gold prominent
button the first-open licence gate uses (F4 — one action, one treatment); About sets the product
name in the bundled wordmark face and credits it (F6); two deprecated-alias call sites in the
folder are re-pointed. To make the first possible, `ProminentButton` moves to `AudioutSharedUI`
and F4 lands INSIDE it: gold fill by default, `inkOnFill` key-window ink, and the measured
white-or-black ink machinery deleted. The Appearance pane, the theme picker (S7) and the Buy
buttons are deliberately untouched.

## Scope fences — PR 6 must NOT touch

- `SettingsSidebarViewController.swift:45` (the `SidebarWarmSurfaceView` call site) and
  `SidebarWarmSurfaceView.swift`. C6 deletes the sidebar warm wash on BOTH screens and that is
  PR 5's (Groups) edit, done once for both call sites. Leave it alone even though PR 1's alias has
  already turned it cool.
- `AppearanceSettingsViewController.swift` — EXCEPT the single token on line 365 (Step 5). PR 1
  already deleted the Follow-system radio and re-derived the theme-tile literals; the theme picker
  STAYS (S7). No accent-dial work, no tile-literal work, no radius work.
- `AudioSettingsViewController.swift` — EXCEPT the single token on line 639 (Step 5).
- The four `AudioutOnboardingUI` files named in Step 1.4 are in scope for the REMOVED
  `picksInkFromFill` ARGUMENT AND ITS COMMENTS ONLY. Do not touch `goldCTA` in any of them (PR 7
  re-points `LicenseGateViewController.swift:273`, `SetupRibbonView.swift:492` and
  `OnboardingViewController.swift:2253`), do not restyle onboarding, do not touch
  `SetupCardView.swift` or `OnboardingChrome.swift`'s other symbols.
- The Buy buttons stay everywhere — the sheet's (`LicenseSheetViewController.swift:100-104`) and
  the General pane's. The iOS "no price, no URL, no button" rule is App Store Guideline 3.1.3(f);
  the Mac sells direct through Paddle and must sell (settings.md:47).
- `SettingsRootViewController.swift`, `SettingsForm.swift`, `GeneralSettingsViewController.swift`:
  no edits. `WarmPanelView` stays (dark-mode legibility; `AudioutSettingsUI/AGENTS.md:17`).
- `Tokens.swift`: DELETE the two aliases named in Step 6 only if the grep there says PR 6 is the
  last consumer. Never delete `goldCTA` (`Tokens.swift:1082`) — see D6.
- `DeviceRowView`, `AppRowView`, `PopoverColumnGrid` (PR 3's), anything under `AudioutPopoverUI`,
  `AudioutWindowUI`, `AudioutApp`.
- The six `dev/notes/settings-snapshots/*.png` goldens: never regenerated
  (`AudioutSettingsUI/AGENTS.md:20`). See D7.
- Every `AGENTS-HISTORY.md`, `docs/`, `PRODUCT.md`, `DESIGN.md`, `ROADMAP.jsonl` (PR 2 and PR 9 own
  docs).
- No cleanup, no abstractions, no error handling for impossible cases, no backwards-compat shims.
  Do not tidy the licence sheet's other four buttons, do not restyle the About window, do not add
  an Analytics event (no new user action — the Register button already exists and its funnel
  events are untouched).

## Decisions recorded (the executor does not re-open these)

- **D1 — `ProminentButton` moves to `AudioutSharedUI`, and PR 6 owns the class wholesale, F4
  included.** The class is `final class ProminentButton: NSButton` — internal — inside
  `AudioutOnboardingUI/OnboardingChrome.swift:77`, and `AudioutSettingsUI`'s dependencies are
  `["AudioutCore", "AudioutSharedUI"]` only (Package.swift:249-252), so it is unreachable from the
  sheet today. Two ways out; SharedUI wins:
  - adding `AudioutOnboardingUI` to Settings' dependencies makes a steady-state settings pane link
    the first-run flow (and, transitively, the `AudioutField` Metal product,
    Package.swift:263-272), and points the dependency arrow the wrong way — onboarding is the
    plausible future consumer of the licence sheet, which would then be a cycle;
  - `AudioutSharedUI` is already the shared-control layer both targets depend on, and the class
    needs nothing from `AudioutOnboardingUI` (it reads `Tokens` and AppKit only).
  Owning it wholesale is what makes PR 6 and PR 7 composable: PR 7's plan deletes
  `picksInkFromFill` and switches the key ink to `inkOnFill`, and a new call site of PR 6's passing
  that argument would break whichever PR merged second. So F4's ink change lands here, in the same
  commit as the move, and PR 7 finds a class with no such parameter.
- **D2 — the class becomes single-ink.** Key window: `Tokens.Color.inkOnFill`. Not key:
  `Tokens.Color.label`, unchanged. The forced-white default, the measured white-or-black pick and
  the two notification observers that re-stamped it all go (Step 1.2). Ratios are PR 1's:
  `inkOnFill` on Full gold measures 10.18:1 dark and 4.94:1 light; on Subtle gold 7.04:1 and
  4.56:1 (PR1 token table, Gold family). The light-IC flip to white that D4 of PR 1 recorded is
  inside the `inkOnFill` token itself, so the button gets it for free.
- **D3 — `fill`'s default becomes `Tokens.Color.gold`.** Every live call site is a gold CTA
  already (`goldCTA` is an alias of `gold` after PR 1); the two that pass nothing
  (`OnboardingChrome.swift:16`, `UsageStatsConsentCard.swift:42`) currently get
  `Tokens.Color.accent`, itself aliased to `gold`. One default, no behaviour change, and the
  Settings call site can pass nothing at all.
- **D4 — the sheet's Register button takes the default font.** The gate passes
  `titleFont: Tokens.Font.heading` (LicenseGateViewController.swift:275) for its 560×440 stage;
  the sheet keeps the default `Tokens.Font.body` (OnboardingChrome.swift:101). A +3 pt semibold
  title in a 320 pt-wide sheet button row beside a stock Cancel is a size mismatch, and F4 asks for
  the gold fill and the ink, not a display face.
- **D5 — `registerButton` becomes `private var registerButton: ProminentButton!`,** built in
  `loadView`, mirroring the gate's own shape (LicenseGateViewController.swift:41, built at :148).
  `ProminentButton`'s init requires title/target/action, so the current stored-property
  initialiser (`private let registerButton = NSButton()`, LicenseSheetViewController.swift:36)
  cannot survive. Its three later uses are `isEnabled` reads/writes (:245, :266, :301) and are
  unaffected.
- **D6 — PR 6 does not retire the `goldCTA` alias, PR 7 does.** Grepped at HEAD: the code consumers
  are `LicenseGateViewController.swift:273`, `SetupRibbonView.swift:492` and
  `OnboardingViewController.swift:2253` (a resolved-colour comparison), all three PR 7's; the rest
  are doc comments in `AudioutPopoverUI/AlignmentPlateCell.swift` (:99, :180, :201, :242, :468,
  :470, :474), `AlignmentPlateButton.swift:75`, a test comment string
  (`AlignmentPlateCellTests.swift:56`) and the alias itself (`Tokens.swift:1082`). PR 6 introduces
  no `goldCTA` reference (D3 uses `gold`), so "last consumer deletes the alias" resolves to PR 7
  outright.
- **D7 — the About credit line is unconditional.** "Clash Display by Indian Type Foundry" renders
  whether or not the real face loaded (outside a `make-app.sh`-assembled `.app`,
  `Tokens.Font.wordmark` falls back to the system bold face — Tokens.swift:1221-1225). A
  conditional line would make the About window a different height in a dev build than in the
  shipped one, for 36 characters of attribution. The wording is the one PR 1's Owed checks settled
  against the `.otf`'s own name-table id 13.
- **D8 — no snapshot golden moves.** `settings-snapshot` mounts the three PANES only
  (`AudioutCore/Sources/settings-snapshot/main.swift`; the sheet and the About window appear
  nowhere in it — its only "license" mentions are the General pane's licence-SECTION comment at
  :125-128). Step 5's two token swaps DO change pane pixels: the buffer-override note goes from
  orange to `label2`, and the selected theme tile's ring from the macOS accent to gold. Both
  goldens are stale by eye, never regenerated — state that in the PR body.
- **D9 — the "no gold in these panes" rule is read narrowly and the rule line is reworded.**
  `AudioutSettingsUI/AGENTS.md:21` says "Controls stay stock and no gold appears in these panes;
  only the background is warm." A sheet is not a pane, and the precedent exists on the same action
  (the gate's Register, LicenseGateViewController.swift:148). Step 7 rewords it so the next agent
  does not read the exception as a violation.

## Pre-flight

Branch from `origin/main` AFTER PR 3 has merged (PR 3 gates PRs 4–8):

```bash
git worktree add .claude/worktrees/design-pr6-settings -b claude/design-pr6-settings origin/main
cd .claude/worktrees/design-pr6-settings
git push -u origin claude/design-pr6-settings
git config core.hooksPath .githooks
```

Guard greps — the first three must print, the last two must print NOTHING, or STOP:

```bash
grep -n "public static func wordmark" AudioutCore/Sources/AudioutSharedUI/Tokens.swift   # PR 1
grep -n "public static var inkOnFill" AudioutCore/Sources/AudioutSharedUI/Tokens.swift   # PR 1
grep -n "final class ProminentButton" AudioutCore/Sources/AudioutOnboardingUI/OnboardingChrome.swift
grep -rn "systemAccent" AudioutCore/Sources/AudioutSettingsUI/
ls AudioutCore/Sources/AudioutSharedUI/ProminentButton.swift 2>/dev/null   # PR 7 must not have landed first
```

Baseline observed during scoping (2026-09-03, HEAD `586bd8a2`, exit 0 both):

```bash
bash scripts/build.sh
#   build: compiled clean on remote alechamilton@SUMUP-M9Y197RFVG.local.
AUDIOUT_TEST_NO_CACHE=1 bash scripts/run-tests.sh --filter 'SettingsRootViewControllerTests|AboutSectionTests|SettingsAccentAndHintsTests|LicenseGateTests|PreviewPaletteTokenPinTests'
#   Test run with 88 tests in 6 suites passed after 1.526 seconds.
```

Re-run both on the fresh branch before editing and record the numbers; PR 3's merge may move the
count. Never a bare `swift build`/`swift test`. No dev build, no livetest slot in this PR.

## Verified facts (file:line, checked at `586bd8a2`)

1. `OnboardingChrome.swift` is 356 lines. `onboardingActionButton` occupies :13-33, `dynamicBlend`
   :46-54, the `// MARK: - Prominent (accent-filled) button` line is :56, the class doc comment
   :58-76, `final class ProminentButton: NSButton` :77 with its closing brace at :208, and the next
   symbol's doc comment (`bluetoothRuneImage`) starts at :210.
2. Inside the class: `let fill: NSColor` :80, `private let picksInkFromFill: Bool` :92,
   `private let titleFont: NSFont` :95, `init(title:target:action:fill:picksInkFromFill:titleFont:)`
   :98-127 with defaults `fill: Tokens.Color.accent` (:99), `picksInkFromFill: false` (:100),
   `titleFont: Tokens.Font.body` (:101), `bezelStyle = .rounded` :110, the
   `if picksInkFromFill { … }` observer block :114-125, `required init?(coder:)` :129,
   `acceptsFirstMouse` :143, `viewDidMoveToWindow` :145-158 (the key/resign observers),
   `viewDidChangeEffectiveAppearance` :160-163, `deinit` :165-169,
   `@objc private func resolvedFillChanged()` :171, `applyTitleColour()` :173-183 (the ink branch
   at :176), `measuredKeyInk()` :186-202, the `// MARK: Test-support hooks` at :204 and
   `var test_measuredKeyInk` :206-207.
3. The class reads only AppKit + `Tokens` (`Tokens.Color.accent`, `Tokens.Color.label`,
   `Tokens.accentStyleDidChangeNotification`, `Tokens.Font.body`) — nothing else from
   `AudioutOnboardingUI`. `dynamicBlend` and `onboardingActionButton` are separate symbols;
   `onboardingActionButton` CONSTRUCTS a `ProminentButton` (:16) and stays where it is.
4. `picksInkFromFill` is passed by exactly two call sites: `LicenseGateViewController.swift:274`
   and `SetupRibbonView.swift:492`. `OnboardingChrome.swift:16` and
   `UsageStatsConsentCard.swift:42` pass neither it nor `fill`.
   `OnboardingUITests.swift:1430` constructs `ProminentButton(title:target:action:)` — no argument
   to drop. Two comments name the parameter: the class doc at :75 and
   `SetupRibbonView.swift:489`. `test_measuredKeyInk` has no caller in Sources or Tests.
5. Cross-module use after the move: `OnboardingViewController.swift:2250-2253` casts to
   `ProminentButton` and reads `done.fill`; `LicenseGateViewController.swift:41-42, 271-278`;
   `UsageStatsConsentCard.swift:42`; `SetupRibbonView.swift:490-493`. All five files already carry
   `import AudioutSharedUI` (line 5 of each). `OnboardingUITests.swift` carries
   `@testable import AudioutSharedUI` (:9), so internal members stay reachable from tests without
   any `public`.
6. `AudioutSettingsUI` dependencies are `["AudioutCore", "AudioutSharedUI"]` (Package.swift:249-252);
   `AudioutOnboardingUI`'s are `["AudioutCore", "AudioutSharedUI", AudioutField]`
   (Package.swift:263-272). No cycle either way; SharedUI is below both.
7. `LicenseSheetViewController.swift` imports `AppKit` and `AudioutCore` only (:3-4) — no
   `AudioutSharedUI`. `registerButton` is declared at :36 and built at :121-125; it also appears in
   the button row (:130), the tab order (:158-159) and three `isEnabled` sites (:245, :266, :301).
   No test anywhere references `LicenseSheetViewController` (`grep -rln` over `AudioutCore/Tests`
   returns nothing).
8. `AboutView.swift:171-177` builds `nameLabel` (`SettingsForm.label(info.appName)`,
   `Tokens.Font.heading`, `Tokens.Color.label`) and `versionLabel` (`Tokens.Font.caption`,
   `Tokens.Color.secondaryLabel`), stacked in `identityText` at :179-182 (vertical, leading,
   spacing 0). The lockup comment runs :149-155; its last sentence, ":153-155", is the one that
   names "Display voice = `Tokens.Font.heading` … no new token; the spec names none for About".
9. `SettingsForm.label(_:)` returns a plain `NSTextField(labelWithString:)` with
   `translatesAutoresizingMaskIntoConstraints = false` (SettingsForm.swift:29-33). `hintLabel`
   additionally sets caption/secondary/wrapping and a `preferredMaxLayoutWidth` derived from the
   PANE width (:60-68) — wrong for a 460 pt About window lockup, hence Step 4 uses `label`.
10. `Tokens.Font.wordmark(size:)` is at Tokens.swift:1221-1225 and falls back to
    `.boldSystemFont(ofSize:)` outside an assembled `.app` (:1222; :1213-1216 explains that this is
    the normal path under `swift test`). The Name Only Rule is stated at Tokens.swift:1205-1207.
11. `Tokens.Color.label3` exists (`tertiaryLabel` is its alias, Tokens.swift:1056);
    `Tokens.Color.gold` at :471; `Tokens.Color.inkOnFill` at :627.
12. `AboutSectionTests.swift` holds 12 `@Test` functions and asserts no fonts and no colours. Its
    only string assertions are `versionLine` (:49, :111); :94 is inside the Reduce Transparency
    test and :177 inside `aboutWindowRendersOffscreenInLightAndDarkWithoutCrashing`. Nothing in the
    suite reads the lockup's labels.
13. `AppearanceSettingsViewController.swift` at HEAD has no `.systemAccent` reference and its
    `WarmPreviewPalette.light` literals are already the new light values — canvas `0xFA/0xFA/0xFB`,
    well `0xE9/0xEA/0xEC`, gold `0xA6/0x7C/0x1E`, ember `0x7A/0x5E/0x2A` (:337-345), matching PR 1's
    token table. Its one remaining alias is `Tokens.Color.accent.setStroke()` at :365, the SELECTED
    theme tile's 2.5 pt selection ring (the hover ring beside it is `Tokens.Color.separator`,
    :368).
14. `AudioSettingsViewController.swift:639` is `note.textColor = Tokens.Color.warningText` on a
    label whose string is "Your buffer is locked to <n> ms by a launch option for this session."
    (:637-638). That is a STATEMENT of fact about a launch option, not a problem the user must fix
    — so it takes `label2` and NO `failure` glyph. The comment at :641-644 explains it is "not
    `hintLabel` (wrong color: this one's `.warningText`, not `.secondaryLabel`)" and must be
    updated with the token.
15. `AudioutSharedUI/AGENTS.md` is 295 words (cap 300); its Purpose is :5-7, its `## Map` header
    :29 and Map bullets :31-33, each ≤ 12 words. `AudioutSettingsUI/AGENTS.md` is 317 words —
    already over the 300 cap before PR 6 touches it.

## Step-by-step

### Step 0 — prove PR 1's Appearance state (no edit)

Run the Pre-flight greps. If `systemAccent` appears under `AudioutSettingsUI/`, or the `.light`
palette literals at `AppearanceSettingsViewController.swift:337-345` are not the four hexes in
Verified fact 13, or `AudioutSharedUI/ProminentButton.swift` already exists, STOP and report.

### Step 1 — `ProminentButton`: move to `AudioutSharedUI` and land F4 in it

1.1 Create `AudioutCore/Sources/AudioutSharedUI/ProminentButton.swift` with the SPDX header line
every file in the folder carries, `import AppKit`, and `OnboardingChrome.swift:56-208` moved
across — the MARK line (:56), the class doc comment (:58-76) and the whole class (:77-208).
Access changes: `public final class ProminentButton`, `public init(...)`, and
`public let fill: NSColor` (:80 — `OnboardingViewController.swift:2253` reads it across the module
boundary). Everything else stays internal; `OnboardingUITests` reaches internals through
`@testable import AudioutSharedUI` (Verified fact 5). `required init?(coder:)` (:129) moves with
the rest, unchanged.

1.2 In the moved file, and ONLY here, apply F4 (D2, D3):
  - init default `fill: NSColor = Tokens.Color.gold` (was `Tokens.Color.accent`, :99).
  - delete the `picksInkFromFill` parameter (:100), its stored property and doc comment (:86-92),
    its assignment (:104), and the whole `if picksInkFromFill { … }` observer block (:114-125).
  - delete `@objc private func resolvedFillChanged()` (:171) and, in `deinit` (:165-169), the two
    `removeObserver(self)` calls that existed only for it — the `NotificationCenter.default` one
    that takes `self` and the `NSWorkspace.shared.notificationCenter` one. KEEP the
    `keyStateObservers.forEach { … removeObserver($0) }` teardown: the key/resign observers in
    `viewDidMoveToWindow` (:145-158) stay, and so does `viewDidChangeEffectiveAppearance`.
  - delete `measuredKeyInk()` (:186-202) with its doc line, and the `// MARK: Test-support hooks`
    section with `test_measuredKeyInk` (:204-207) — it has no caller (Verified fact 4).
  - in `applyTitleColour()` the key-window branch (:176) becomes `Tokens.Color.inkOnFill`; the
    non-key branch stays `Tokens.Color.label`. The ternary and the local `colour` can collapse to
    a single expression; keep it readable, keep the surrounding comment's meaning.
  - rewrite the class doc comment (:58-76) for what the class now is: a GOLD call-to-action button
    whose title is `inkOnFill` while its window is key. KEEP the white-on-white bug story verbatim
    in substance (:64-76 — AppKit drops a `bezelColor` fill to a plain bezel on resign-key without
    recolouring the title, which is why the class exists and why the non-key ink is `label`); drop
    only the sentences about forced white, the measured pick and the `goldCTA` opt-in. State the
    F4 rule in one line: every call to action is `gold` fill with `inkOnFill` ink.

1.3 Delete `:56-208` from `OnboardingChrome.swift`, leaving `onboardingActionButton` (:13-33),
`dynamicBlend` (:46-54) and `bluetoothRuneImage` (from :210) untouched and the file's blank-line
rhythm intact. The file already imports `AudioutSharedUI` (:5), so its `ProminentButton(...)` call
at :16 keeps compiling.

1.4 Drop the removed argument at its two call sites, and fix the two comments that name it — this
is the ONLY change PR 6 makes in these files:
  - `LicenseGateViewController.swift:272-275`: remove the `picksInkFromFill: true,` line. Leave
    `fill: Tokens.Color.goldCTA` and `titleFont: Tokens.Font.heading` exactly as they are (PR 7
    owns the `goldCTA` re-point).
  - `SetupRibbonView.swift:490-493`: remove `picksInkFromFill: true` from the argument list, and
    amend the comment at :486-489 whose last sentence is "Ink is measured off the resolved fill
    (see `ProminentButton.picksInkFromFill`)" — the ink is now `inkOnFill`, decided by the class.
  - `UsageStatsConsentCard.swift:42`, `OnboardingChrome.swift:16`, `OnboardingUITests.swift:1430`:
    verify by grep that they pass no such argument (Verified fact 4) and change nothing.

1.5 `AudioutSharedUI/AGENTS.md`: add ONE Map bullet after :33 in the existing style, at most 12
words and short enough to keep the file at or under 300 words (it is 295 today — Verified fact 15;
budget about five words, so trim an existing wordy line if needed rather than exceed the cap).
Wording to use: `` - `ProminentButton` → the gold call-to-action button, `inkOnFill` ink. `` Do NOT
widen the Purpose sentence and do not add rule bullets; the Map line is enough to find the class.

### Step 2 — the licence sheet's Register button

`AudioutCore/Sources/AudioutSettingsUI/LicenseSheetViewController.swift`:

2.1 Add `import AudioutSharedUI` to the import block (:3-4), alphabetically after `AudioutCore`.

2.2 Replace the declaration at :36 with `private var registerButton: ProminentButton!` (D5).

2.3 Replace the four build lines at :121-125 with a `ProminentButton` construction passing
`title: "Register"`, `target: self`, `action: #selector(registerTapped)` and `fill:
Tokens.Color.gold` (explicit even though it is now the default — the fill is the decision this PR
records), and NO `titleFont` argument (D4). Keep the existing
`registerButton.keyEquivalent = "\r"` line exactly as it is: Return still commits, as the gate does
at LicenseGateViewController.swift:151. The `bezelStyle` line goes — the init already sets
`.rounded` (OnboardingChrome.swift:110).

2.4 Add a comment above the construction, in the file's voice, carrying two things: (a) WHY the
gold arrives here — one action, one treatment, the first-open gate's Register is the same button
(cite `LicenseGateViewController.swift:148`), and a sheet is not a pane, so the folder's "no gold
in these panes" rule is intact; (b) WHY this view is the folder's exception to
"every view sets `translatesAutoresizingMaskIntoConstraints = false`"
(`AudioutSettingsUI/AGENTS.md:13`) — it is an arranged subview of `buttonRow` (`NSStackView`,
:130), which owns that flag, and setting it here would fight the stack. Precedent: the sheet's
four other buttons never set it either (:100-125), and `onboardingActionButton` sets it only for
the constraint-hosted card slot (OnboardingChrome.swift:17-21, whose comment makes the same
distinction). Do NOT set the flag.

2.5 Everything else in the file is unchanged: the tab order (:158-159), the three `isEnabled` sites
(:245, :266, :301), the Buy and Remove buttons, `refreshButtons()`.

### Step 3 — About: the wordmark name

`AudioutCore/Sources/AudioutSettingsUI/AboutView.swift`:

3.1 Line 172: `nameLabel.font` becomes `Tokens.Font.wordmark(size: 22)`. Line 173
(`Tokens.Color.label`) is unchanged.

3.2 Rewrite the last sentence of the lockup comment (:153-155), which currently justifies
`Tokens.Font.heading` as the display voice. It must name the wordmark face and the iPhone
companion's Name Only Rule (a wordmark sets the product name and nothing else —
`Tokens.swift:1205-1207`), and say the system bold face is the normal fallback outside an assembled
`.app` (`Tokens.swift:1213-1216`). Leave :149-152 (the icon/lockup reasoning) alone.

### Step 4 — About: the type credit

3.3 of the same file, kept separate because it is a different decision: after `versionLabel`
(:175-177), build a third label with `SettingsForm.label(...)` — NOT `hintLabel`, whose
`preferredMaxLayoutWidth` is derived from the pane width (Verified fact 9) — carrying the exact
string:

```
Clash Display by Indian Type Foundry
```

font `Tokens.Font.caption`, colour `Tokens.Color.label3`. Add it to `identityText`'s views array
(:179) after `versionLabel`; orientation, alignment and `spacing = 0` (:180-182) stay. One short
comment: the `.otf`'s own name table (id 13) asks for the credit even though the ITF licence does
not require it (PR 1's Owed checks).

### Step 5 — the folder's two alias call sites

5.1 `AudioSettingsViewController.swift:639`: `Tokens.Color.warningText` → `Tokens.Color.label2`.
The line is a statement about a launch option, not a problem message, so it gets NO `failure`
glyph and no other change (Verified fact 14). Update the comment at :641-644 that names
`.warningText` so it names `label2`.

5.2 `AppearanceSettingsViewController.swift:365`: `Tokens.Color.accent.setStroke()` →
`Tokens.Color.gold.setStroke()`. This is the SELECTED theme tile's ring; the hover ring at :368
(`Tokens.Color.separator`) is untouched. If the comment at :363 says "accent", make it say gold.

### Step 6 — alias deletion, by grep

For EACH of `warningText` and `accent`, run
`grep -rn "Tokens.Color.<name>" AudioutCore/Sources AudioutCore/Tests` after Step 5. Delete the
alias from `Tokens.swift`'s deprecated block ONLY if the grep returns nothing but the alias
declaration itself. Expected at the time of writing: `warningText` still has
`SetupCardView.swift:323` and `OnboardingViewController.swift:1380-1715` (PR 7's), and `accent`
still has `DeviceRowView.swift:2967` (PR 3's) and `OnboardingChrome.swift:99` — which PR 6 itself
removes in Step 1.2. So the likely outcome is that BOTH aliases stay and PR 6 deletes neither.
Whichever PR merges second deletes each one: PR 6/PR 7 for `warningText`, PR 3/PR 6 for `accent`.
Report what the greps actually said.

### Step 7 — the folder rule

`AudioutCore/Sources/AudioutSettingsUI/AGENTS.md:21`. REWORD the line in place at roughly the same
length — the file is 317 words and already over the 300-word cap (Verified fact 15), so it must not
grow. It must still say controls stay stock, and it must say the licence sheet's Register is the
one gold call to action. Add nothing else, touch no other line, do not touch `AGENTS-HISTORY.md`.
Note the over-cap file in the PR body for PR 9 to trim.

## Ratio table

Nothing new is measured in this PR; every value is quoted from PR 1's token table.

| pairing | value | source |
|---|---|---|
| `inkOnFill` on Full-gold, dark / light | 10.18 / 4.94 | PR1 token table, Gold family, `inkOnFill` row |
| `inkOnFill` on Subtle-gold, dark / light | 7.04 / 4.56 | same row |
| `label3` (the About credit) on the light flat ground / dark canvas | 5.60 / 6.59 | PR1 token table, Ink, `label3` row |
| `label2` (the buffer-override note) on the light flat ground / dark canvas | 5.97 / 8.81 | PR1 token table, Ink, `label2` row |

The About window's background is a system `NSVisualEffectView`, not a token ground, so the credit
line has no tokenised ground to measure against; the two ratios above are the nearest guaranteed
grounds and both clear the 4.5 text floor.

## Interim visible effects

This PR FINALISES for its surface: the CTA treatment on the licence sheet AND on every onboarding
prominent button (F4 — gold fill, `inkOnFill` ink, no measured pick anywhere), About's display face
and its type credit (F6), the buffer-override note's ink, and the selected theme tile's ring.

| what | until | what Alec sees |
|---|---|---|
| The About name renders in system bold under `swift run`/`swift test` | a `make-app.sh`-assembled `.app` | Clash Display appears only in a real build; the credit line is there either way (D7) |
| The gate and ribbon CTAs still fill from the `goldCTA` alias | PR 7 re-points them | Identical pixels (the alias resolves to `gold`), but the ink is already `inkOnFill` |

## Test plan

- `AboutSectionTests` (12 tests) — KEEP unchanged. It asserts window reachability, the Reduce
  Transparency cover (:94), the injected version line (:111), a `fittingSize.height < 520` bound
  that is on `GeneralSettingsViewController` rather than About, and offscreen rendering in both
  appearances (:177). A third label in the lockup and a different name font touch none of them. If
  `aboutWindowRendersOffscreenInLightAndDarkWithoutCrashing` fails, the wordmark fallback is
  broken — STOP and report rather than editing the test.
- `OnboardingUITests` — KEEP unchanged; it must still compile and pass after the move and the
  parameter deletion. That is the real test of Step 1. `test_measuredKeyInk` has no caller, so no
  test loses an assertion.
- `LicenseGateTests`, `SettingsRootViewControllerTests`, `SettingsAccentAndHintsTests`,
  `PreviewPaletteTokenPinTests` — KEEP unchanged. None references `LicenseSheetViewController`
  (Verified fact 7) and none pins the two tokens Step 5 swaps.
- NEW tests: none. There is no licence-sheet suite to extend, a button's fill is not behaviour, and
  the ink is a token the contrast suites already pin. If the executor believes a test is owed, say
  so in the report and do not add one.

## Verification (run in this order; paste each command's output)

```bash
bash scripts/build.sh
#   exit 0, "compiled clean"; deprecation warnings from PR 1's remaining aliases are expected
AUDIOUT_TEST_NO_CACHE=1 bash scripts/run-tests.sh --filter 'SettingsRootViewControllerTests|AboutSectionTests|SettingsAccentAndHintsTests|LicenseGateTests|OnboardingUITests|PreviewPaletteTokenPinTests'
#   every suite passes; report the real test count
AUDIOUT_TEST_NO_CACHE=1 bash scripts/run-tests.sh
#   the FULL suite, once, green (Guard 4 runs it again at commit)
grep -rn "picksInkFromFill\|measuredKeyInk" AudioutCore/Sources AudioutCore/Tests
#   expected: no output outside AGENTS-HISTORY.md (which is not edited)
grep -rn "ProminentButton" AudioutCore/Sources/AudioutOnboardingUI/OnboardingChrome.swift
#   expected: only the construction inside onboardingActionButton, plus its doc reference
grep -n "goldCTA" AudioutCore/Sources/AudioutSharedUI/Tokens.swift
#   expected: the alias at :1082 still there (D6)
wc -w AudioutCore/Sources/AudioutSharedUI/AGENTS.md
#   expected: <= 300
git status --short dev/notes/settings-snapshots/
#   expected: no output — no golden regenerated
```

Then:

```bash
git add -A AudioutCore dev/notes/design-migration-scoping/PR6-settings-work-order.md
bash scripts/self-review.sh      # Guard 7, on the exact staged bytes
git commit -m "Settings: gold Register on the licence sheet, wordmark name in About"
git push origin claude/design-pr6-settings
gh pr create --base main --head claude/design-pr6-settings --title "Design migration PR 6: Settings and About"
```

Do NOT merge the PR.

## Owed checks (eye-check list for Alec; do not block the PR)

1. Build an `.app` (`APP_NAME="Audiout Dev" BUNDLE_ID="com.audiout.Audiout.dev" bash scripts/make-app.sh`,
   holding the livetest slot) and open About: the product name must render in Clash Display, not
   system bold, with the credit line beneath the version.
2. Settings › General › Enter License…: the gold Register beside a stock Cancel, in light and dark,
   and with the window NOT key — the title must stay legible, which is the bug the class exists to
   fix (the moved doc comment tells the story).
3. The first-open gate and the Setup ribbon CTA: same gold, now with `#171104` ink instead of the
   measured white. Both are onboarding surfaces PR 6 changed the ink of.
4. Whether the sheet's Register at body weight reads too quiet next to the gate's heading-weight
   one (D4 is a judgement call).
5. Two stale settings goldens by eye: the buffer-override note is no longer orange
   (`settings-audio-*.png`) and the selected theme tile's ring is gold (`settings-appearance-*.png`).

## Requests to PR 3

None. PR 3 keeps `DeviceRowView.swift:2967` on the `accent` alias; whichever of PR 3 / PR 6 merges
second deletes that alias after grepping (Step 6).

## Hand-off to the remaining PRs

- **PR 7 (onboarding) — pre-flight gate: run
  `grep -rn "picksInkFromFill" AudioutCore/Sources` and STOP if it returns anything.** A hit means
  PR 6 has not merged and PR 7's plan is written against the old class. After PR 6,
  `ProminentButton` lives at `AudioutCore/Sources/AudioutSharedUI/ProminentButton.swift`: public
  class, public init, public `fill`, default fill `Tokens.Color.gold`, key-window ink
  `Tokens.Color.inkOnFill`, no `picksInkFromFill`, no `measuredKeyInk`, no `test_measuredKeyInk`.
  PR 7's Step 4.3 is therefore already done and should be struck; what remains for PR 7 is
  re-pointing `LicenseGateViewController.swift:273`, `SetupRibbonView.swift:492` and
  `OnboardingViewController.swift:2253` off `goldCTA`, then deleting that alias (D6). PR 7 also
  still owns `SetupCardView.swift:323` and `OnboardingViewController.swift:1380-1715` for
  `warningText`; whichever of PR 6 / PR 7 merges second deletes that alias after grepping.
- **PR 5 (Groups):** `SettingsSidebarViewController.swift:45` is still the second
  `SidebarWarmSurfaceView` call site and is untouched here; C6 deletes both.
- **PR 9 (DESIGN.md):** About's display face is `Tokens.Font.wordmark(size: 22)` plus a fixed
  credit line; the licence sheet's Register is the Settings surface's only gold; every prominent
  button in the app is now gold fill + `inkOnFill` ink from one class in `AudioutSharedUI`. Also:
  `AudioutSettingsUI/AGENTS.md` is 317 words, over the 300-word cap, and PR 6 deliberately reworded
  rather than added — it needs a trim.

## Execution plan

One track, and it must merge BEFORE PR 7. Six files of edits plus one file move; the whole risk is
in Step 1 (a cross-target move that also deletes a parameter five files reference).

- **Model: opus. Effort: medium.** Medium, not high: every design fork is closed in D1–D9 and the
  edits are small and local. Not sonnet, because Step 1 deletes a public-ish parameter and its
  machinery across module boundaries, where the failure mode is subtle — an observer teardown left
  behind, or a comment that still promises a measured ink — and Step 2 rewires a stored property
  whose three later uses must keep working. Judging "did I move exactly this and delete exactly
  that" is the job.
- Depends on PR 3 being merged (branch point). No uncommitted work is consumed: PR 6 forks from
  `origin/main`.

## Executor rules (copy verbatim into the handoff prompt)

> - Follow the steps in order. Do not add, merge, reorder, or skip steps.
> - Before editing in any folder, read the nearest AGENTS.md above it (and the root one) if the repo has them — folder rules and traps bind even when the work order doesn't repeat them.
> - If reality contradicts a Verified fact or a step is impossible as written, STOP and report the discrepancy. Do not improvise a workaround.
> - Before reporting progress, audit each claim against a tool result from this session. Only report work you can point to evidence for. If tests fail, say so with the output.
> - "Done" means the Verification commands were run in this session and passed. Paste their output.
> - Touch nothing in the Out-of-scope list.
> - Deliver what was asked, at the scope intended. If the spec seems mistaken or a better approach exists, say so in a sentence and continue as specified rather than quietly narrowing, widening, or transforming it.
