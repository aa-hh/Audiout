# UI & window-management consistency — prioritized punch list

> **STATUS (2026-08-07, one-surface program — roadmap 032):** `W1`–`W5` are
> **superseded**: the surfaces they arbitrate no longer exist. The standalone
> Settings and Groups windows, the `AIRPLAY_CONTROL_PANEL` flag fork, and the
> NSPopover were all deleted; the app runs on one `AppSurfaceController`
> hosted by the evolved shell. See `PLAN-ONE-SURFACE-032.md` (execution log at
> the bottom). Every other item shipped through that program — per-item
> "Shipped in" markers below. Only `V15` remains, owed on the signed build.

Roadmap entry `002`. Audit only; no fixes applied. Every item names its surface,
its code area, what is wrong and what "done" looks like, so any one of them can
be lifted into its own bounded roadmap task without re-reading this file's
neighbours.

**Scope:** the five window/panel surfaces — menu-bar popover (**POP**), Settings
(**SET**), Groups (**GRP**), onboarding (**ONB**), Control Panel shell
(**SHELL**) — on (a) visual consistency and (b) window-management behavior.

Paths are relative to the repo root. Line numbers are against `main` at
`c8cb1fd7`.

---

## Ground truth established by this pass

Verified against current source, not against the task's premise.

- **`docs/plans/phase-3-findings/window-panel.md` is largely superseded.** It was
  written at `bcd6086`. Three of its five "top by user impact" items have since
  shipped: every window now sets `.moveToActiveSpace + .fullScreenAuxiliary`;
  the shell's close button is visible; the status-item click toggles the panel
  rather than only re-fronting it; Groups' frame autosave works; the onboarding
  tone no longer replays on refocus. That file now carries a superseded banner.
- **The Control Panel is the shipping chrome, not a dormant prototype.**
  `scripts/make-app.sh:531` writes `LSEnvironment.AIRPLAY_CONTROL_PANEL = "1"`
  into every bundled build. The old finding "the fix ships switched off" is
  inverted — see **W2**.
- **Several visual seams are decided, not drifted.** `dev/notes/warm-signal-v3.md`
  §5.2 puts Settings on stock macOS chrome with no warm canvas and no gold; §5.3
  keeps Groups' chrome stock with only the content pane warm, and puts the New
  Group sheet on Apple's own styling; §5.1 gives the popover its uppercase
  section micro-labels; decision m keeps "AirPlay" wording in device context.
  `dev/notes/warm-signal-screens-followup.md` locks Groups' 28pt rows against
  the popover's 42pt. All excluded below.
- Visual evidence comes from all four snapshot generators regenerated against
  current `HEAD`, plus source reads.

---

# P1 — a user hits it, or a house rule is broken

### W1 — While a Groups session is open, the menu-bar icon can no longer reach the popover

**Surface:** SHELL + POP.
**Code:** `AudiouterCore/Sources/AudiouterApp/AppDelegate.swift:302-323`
(`onButtonClicked`), `:1074` (`controlPanelSessionActive = true`), `:1065-1069`
(only `onClose` clears it).

`controlPanelSessionActive` stays true for the whole life of a Groups session,
including while the panel is tucked away by `hidesOnDeactivate` after an
app-switch. The click handler tests that flag *before* the popover, so every
left-click during that session either closes the panel or restores it — never
opens the popover. A user who opened Groups once, switched to Safari, and now
wants to change a volume must click the icon (Groups reappears), then click it
again (Groups closes, popover appears). Two clicks and a surprise, to reach the
app's primary surface.

**Done when:** a menu-bar click while the panel is tucked away has a chosen
outcome — restore Groups, or go home to the popover — and a test pins it. Today
the behavior is a side effect of flag lifetime.

### W2 — The chrome that ships is not the chrome that dev and tests exercise

**Surface:** GRP, both hosts.
**Code:** `scripts/make-app.sh:531`; `AppDelegate.swift:242` (`useControlPanel`),
`:1005-1022` (standalone branch) vs `:1029-1044` (panel branch);
`AudiouterCore/Sources/AudiouterWindowUI/MixerWindowController.swift:244-260`,
`:297-303`.

Bundled builds always set the flag, so users only ever see Groups in the
floating panel. `swift run`, `swift test`, `window-harness` and six of the seven
`window-snapshot` fixtures run with the flag unset, so they exercise the
standalone `NSWindow` path — its title bar, traffic lights, frame autosave,
`showWindow()`, minimum size, resizability. That path is fully maintained, fully
covered, and reaches no shipping user.

**Done when:** one of — the standalone path is deleted and its tests retargeted
at the panel; or dev/test defaults flip to match release; or the fork is written
down as intentional with its reason. Any of the three. The current state is a
silent fork.

### W3 — The Control Panel floats above Settings and onboarding, so opening either can look like nothing happened

**Surface:** SHELL vs SET vs ONB.
**Code:** `AudiouterCore/Sources/AudiouterSharedUI/ControlPanelWindowController.swift:109`
and `:155` (`level = .floating` on the panel and its backing window);
`AudiouterCore/Sources/AudiouterSettingsUI/SettingsWindowController.swift:177`
(normal level); `AudiouterCore/Sources/AudiouterOnboardingUI/OnboardingWindowController.swift:58-70`
(deliberately normal level).

Nothing hides or closes the panel when a sibling surface opens.
`openSettings()` (`AppDelegate.swift:1101-1126`) and `presentSetup()`
(`:874-942`) never consult `controlPanel`, and `hidesOnDeactivate` fires only on
an *app* switch — opening a sibling window is not one. So with Groups showing,
choosing Settings from the popover gear or the right-click menu makes Settings
key underneath a 720×460 gold bubble. `presentSetup`'s own comment ("the window
is normal-level, so Settings stays clickable") shows the two-normal-level case
was reasoned about; the floating third surface was not.

**Done when:** opening Settings or Setup over a showing panel has a decided
outcome — tuck the panel, close it, or drop its level — with a test.

### W4 — A buried Settings window is not recoverable by the app's primary gesture

**Surface:** SET.
**Code:** `AppDelegate.swift:302-338` (`onButtonClicked` consults
`onboardingWindowController` and `controlPanel`, never `settingsWindowController`);
`SettingsWindowController.swift:212-228`.

The surviving half of the old `C1`. The app is `.accessory` — no Dock icon. Two
recovery paths do work: right-click the status item → "Settings…", or open the
popover and click the gear; both re-front correctly. ⌘, does not help while
Settings is buried, because the app is not active. So a plain left-click on the
icon — the app's primary gesture — is the one path that cannot bring Settings
back.

**Done when:** the click handler re-fronts an open-but-not-key Settings window,
mirroring `OnboardingWindowController.appDidBecomeActive`; or the decision to
rely on the secondary paths is recorded.

### A1 — Reduce Transparency is honored in exactly one view, and one surface promises it without delivering

**Shipped in `c8df2082` (P1).**
**Surface:** SET, GRP, quit indicator.
**Code:** the app's only read of `accessibilityDisplayShouldReduceTransparency`
is `AudiouterCore/Sources/AudiouterSharedUI/WarmCanvasView.swift:71`.
No fallback at `SettingsWindowController.swift:371-373` (`.windowBackground` /
`.behindWindow`), `AudiouterCore/Sources/AudiouterSettingsUI/AboutView.swift:203-205`,
or `AppDelegate.swift:1496-1497` (`.popover`, `state = .active`, forced on
regardless of key state).
`AudiouterCore/Sources/AudiouterWindowUI/SidebarViewController.swift:503-508`
subscribes to `accessibilityDisplayOptionsDidChangeNotification` with a comment
saying it reconciles "Reduce Transparency / Increase Contrast"; the handler at
`:518` only sets `needsDisplay`, and `draw(_:)` at `:530-534` branches solely on
`rendersOnGlass` (an OS-version flag). Increase Contrast does arrive, through
`Tokens.Color.sidebarWarmTint`'s dynamic provider — Reduce Transparency does
nothing, so the 0.30-alpha warm wash (`:494`) stays translucent over a
now-opaque system sidebar.

Root `AGENTS.md` house rule 6 requires respecting Reduce Transparency. POP and
ONB comply (they retired their effect views for `WarmCanvasView`); SHELL is
opaque and needs nothing. SET, GRP's sidebar and the quit HUD do not.

**Done when:** each `NSVisualEffectView` has an opaque fallback under Reduce
Transparency, and the sidebar wash either reads the flag or its comment stops
claiming it does.

### V1 — Settings › Audio has a manual "Apply Settings" button among immediate-apply controls

**Shipped in `50e5302d` (T2).**
**Surface:** SET.
**Code:** `AudiouterCore/Sources/AudiouterSettingsUI/AudioSettingsViewController.swift:129`,
`:454-459`, `:498`.

macOS preferences apply on change, and this pane does that for the excluded-apps
list, the connect-volume slider and the sync-offset slider. Then it puts a push
button labelled "Apply Settings" / "Apply & Reconnect" at the bottom right of
the pane for the audio-buffer popup alone. Two commit models in one pane, with
nothing on screen saying which control belongs to which.

**Done when:** the buffer change applies immediately like its neighbours (with
the reconnect cost in its hint), or the button is visibly bound to that one
control instead of sitting at pane level.

### W10 — Owner-reported: the Setup window drops behind other windows after a permission is granted

**Shipped in `5ae36594` (with W6, pre-program).**
**Surface:** ONB.
**Code:** `OnboardingWindowController.swift:65-71` (deliberate normal level — an
earlier `.floating` version was reverted because it hovered over every app),
`:84-91` (re-front fires only on `didBecomeActive`);
`OnboardingViewController.swift:125-132` and `:536-546` (post-Allow re-fronts:
`NSApp.activate(ignoringOtherApps: true)` + `makeKeyAndOrderFront`).

Owner report (2026-08-07): after adding a permission, the Setup window ends up
behind other windows instead of staying in front. The recovery design covers
two paths and each has a hole: the System-Settings path re-fronts only when the
app next becomes active, i.e. nothing recovers the window until the user
manually clicks back to the app; the prompt path relies on
`activate(ignoringOtherApps:)` being honored, and under macOS 14's cooperative
activation the system can decline that request while another app is frontmost —
`makeKeyAndOrderFront` then orders the window within an inactive app, which
still leaves it behind. (Hypothesis — confirm which path the report hits before
fixing.) Desired behavior, per owner: the window stays in the foreground for as
long as it is open.

**Done when:** after each grant — prompt path and System-Settings path — the
Setup window is frontmost again without the user clicking the app, verified
live. Either fix the re-activation path, or revisit the level decision (e.g.
elevated only while setup is open or a grant is in flight) — the earlier
revert's "keeps popping up over everything" objection must be answered, not
ignored. Pairs with W6: the same re-front is too eager in one direction and
too weak in this one, so fix them together.

---

# P2 — visible inconsistency, no dead end

### V2 — One window calls the same list two things; one flow has three names

**Shipped in `9bc5a3da` (T5).**
**Surface:** GRP, SET, ONB.
**Code:** `AudiouterCore/Sources/AudiouterWindowUI/SidebarViewController.swift`
(sidebar header "Devices") vs
`AudiouterCore/Sources/AudiouterWindowUI/GroupEditorViewController.swift:204`
and `GroupCreationSheetController.swift:123` ("Speakers");
`AudiouterCore/Sources/AudiouterSettingsUI/GeneralSettingsViewController.swift:69`
("Setup") + `:64` ("Check Permissions…") →
`OnboardingWindowController.swift:60` (window title "Welcome") →
`AudiouterCore/Sources/AudiouterOnboardingUI/OnboardingViewController.swift:340`
("Welcome to Audiouter").

Groups heads its sidebar list "Devices" and heads the identical set "Speakers"
two inches to the right, both on screen at once (`mixer-3-edit-group-*.png`).
Separately, one permission flow carries three names across two surfaces. The
popover's "Output Devices" and onboarding's plain "speakers" are both decided in
Warm Signal §5.1 and §5.8 — these two are not decided anywhere.

**Done when:** Groups uses one noun in both panes, the setup flow uses one name
end to end, and both are noted beside Warm Signal decision m.

### V3 — Button titles disagree on capitalization and on the ellipsis rule

**Shipped in `9bc5a3da` (T5).**
**Surface:** GRP, SET, ONB.
**Code:** `MixerWindowController.swift:764` and `SidebarViewController.swift:192,196`
("New Group"); `GroupEditorViewController.swift:214` ("Delete group…");
`AudioSettingsViewController.swift:702` ("Add app…");
`AudiouterCore/Sources/AudiouterSettingsUI/AppearanceSettingsViewController.swift:508`
("Match System") vs `:519,521` ("Full gold", "Follow system accent");
`AudiouterCore/Sources/AudiouterOnboardingUI/PermissionRowView.swift:258,265`
("Open Settings") vs `AudiouterCore/Sources/AudiouterOnboardingUI/PTPHelperRowView.swift:148`
("Open Login Items…").

Three contradictions, each inside a single pane:

- Groups: "New Group" is Title Case with no ellipsis; "Delete group…" is
  sentence case with one. Both open something — the creation sheet
  (`MixerWindowController.swift:396`) and the delete alert
  (`GroupEditorViewController.swift:695`) — so both need the ellipsis.
- Settings › Appearance: the theme tiles are Title Case, the accent radios
  directly beneath them are sentence case.
- Onboarding: two adjacent rows of the same card, both opening System Settings,
  one with an ellipsis and one without.

`docs/plans/phase-3-findings/copy.md` issues 28 and 29 raised the pattern in
July; the snapshots show it unchanged.

**Done when:** every button that opens a sheet, window, picker or external app
ends in "…", and button titles are Title Case app-wide. Mechanical, one pass.

### V4 — One popover list paints its rows with two different washes

**Shipped in `020d2819` (T4).**
**Surface:** POP.
**Code:** `AudiouterCore/Sources/AudiouterPopoverUI/GroupRowView.swift:370-379`
uses raw `NSColor.controlAccentColor` @ **0.15** and raw
`NSColor.selectedContentBackgroundColor` @ **0.12**; the sibling rows in the
same stack use `Tokens.Color.accent` @ `rowSelectionWashAlpha` (**0.18**) and
`Tokens.Color.selectedContentBackground` @ `rowHoverWashAlpha` (**0.10**) —
`AudiouterCore/Sources/AudiouterSharedUI/DeviceRowView.swift:2117-2122`,
`AudiouterCore/Sources/AudiouterSharedUI/AppRowView.swift:657-659`, alphas at
`AudiouterCore/Sources/AudiouterSharedUI/PopoverColumnGrid.swift:472,476`.

Selected rows and hovered rows are visibly different shades depending on which
card they are in, inside one scrolling popover. Because `GroupRowView` bypasses
`Tokens`, it also misses whatever Increase Contrast treatment those token cases
carry.

**Done when:** group rows read the same two token cases and alphas as device and
app rows.

### V5 — The dark theme preview shows a color the product stopped drawing

**Shipped in `020d2819` (T4).**
**Surface:** SET.
**Code:** `AppearanceSettingsViewController.swift:321` hard-codes the dark
preview's `well` as `0x2B2620`; `AudiouterCore/Sources/AudiouterSharedUI/Tokens.swift:186-188`
gives `Tokens.Color.well` a dark value of `0x100D0A`.

The Appearance tiles exist to depict the actual product — that is the stated
justification for the only sanctioned raw-color block outside `Tokens`
(`AppearanceSettingsViewController.swift:244-246`). The dark well was re-tuned
in the fader-legibility pass and the preview was not, so the Dark tile now
advertises a shade the app has not drawn since.

**Done when:** the preview palette derives from `Tokens.Color`, or a test pins
the two together so the next re-tune cannot drift them apart again.

### V6 — The Groups icon badge renders identically in light and dark

**Shipped in `020d2819` (T4).**
**Surface:** GRP.
**Code:** `AudiouterCore/Sources/AudiouterWindowUI/DeviceIconWellView.swift:87-88`
(`NSColor(white: 0, alpha: 0.55)`, `NSColor(white: 1, alpha: 0.25)`), stamped
into a `CALayer` at `:138-140`; `viewDidChangeEffectiveAppearance` at `:228-231`
only calls `needsDisplay`, which repaints `draw(_:)` but never re-stamps the
layer. The pencil glyph is a static `.white` at `:~146`.

A 55%-black badge with a 25%-white rim on a warm-cream light background and on a
near-black dark background. Also the only pair of raw color literals outside
`Tokens` that is not the theme preview, so it sits outside Increase Contrast
too.

**Done when:** the badge fill and rim come from `Tokens.Color` (or are re-stamped
on appearance change).

### V7 — The popover's two icon-button families contradict each other and their own docs

**Shipped in `fab9cd9a` (T3).**
**Surface:** POP.
**Code:** `AudiouterCore/Sources/AudiouterPopoverUI/PopoverHeaderView.swift:206-208`
uses `bezelStyle = .accessoryBar` with `showsBorderOnlyWhileMouseInside`;
`AudiouterCore/Sources/AudiouterPopoverUI/PopoverPanelViewController.swift:482`
uses `.smallSquare` for the card accessory a few points below. The comment at
`:477-479` says the two use "the same stock bezel (`bezelStyle = .smallSquare`)",
and `AudiouterCore/Sources/AudiouterSharedUI/AGENTS.md:19` says the header
buttons are `.smallSquare`. Both are wrong.

One family shows its border only on hover, the other always. They sit within
about 30pt of each other in the popover's top-right region, and two documents
assert they match.

**Done when:** the two families genuinely use one bezel, and the comment plus
`AudiouterSharedUI/AGENTS.md:19` say what the code does.

### V8 — Settings shows a user an environment-variable name

**Shipped in `9bc5a3da` (T5).**
**Surface:** SET.
**Code:** `AudioSettingsViewController.swift:435` —
"Overridden by AIRPLAY_START_BUFFER_MS (120 ms) for this launch."

The only environment-variable name shown to a user anywhere in the app, in a
pane whose other hints are plain sentences. The spec's copy voice is warm,
concrete, second person.

**Done when:** the hint says what happened in plain words (or the row is hidden
outside dev builds).

### V9 — Groups' empty state does not say what a group is

**Shipped in `9bc5a3da` (T5).**
**Surface:** GRP.
**Code:** `MixerWindowController.swift:751-752`.

Current: "No groups yet." / "Music first — rooms can come later."
Warm Signal §5.9 specifies for this exact state: "Save a set of speakers as a
group, then switch to it in two clicks from the menu bar." The shipped line is
atmosphere; the spec'd line teaches the feature at the one moment the user is
looking at nothing else. §5.9's sibling empty states — devices "Looking for
speakers…", applications "Route one app somewhere else…" — have no
implementation in `AudiouterPopoverUI` at all.

**Done when:** the three §5.9 empty states are implemented as specified, or the
spec is amended on purpose.

### W5 — Two config surfaces reached from the same header behave nothing alike

**Surface:** SHELL (Groups) vs SET.
**Code:** `ControlPanelWindowController.swift:110,112,134,138`, `:404-410`
(`windowWillClose` → `onClose`); `SettingsWindowController.swift:173-203` —
that file declares no `NSWindowDelegate` at all.

From one popover header the user reaches two windows with opposite manners.
Groups: cannot be moved, anchors under the menu bar, vanishes on app-switch and
returns on the way back, and re-opens the popover when closed. Settings:
movable, remembers its position across launches, stays put on app-switch, and
closing it leaves the user with nothing. Each is defensible alone; together they
teach no rule.

**Done when:** the intended model is written down ("Groups is a summoned panel,
Settings is a document window") and both surfaces are checked against it —
including whether Settings should also land home on close.

### W6 — Onboarding re-fronts itself on every app activation, over whatever else is open

**Shipped in `5ae36594` (with W10, pre-program).**
**Surface:** ONB.
**Code:** `OnboardingWindowController.swift:79-91` (`appDidBecomeActive` →
unconditional `makeKeyAndOrderFront`), `:97-104` (`present()` → unconditional
`center()`).

The re-front exists to recover the window after a system permission prompt
steals focus, which is right. But it is wired to every
`didBecomeActiveNotification` for as long as the window lives, so re-entering
the app for any reason pulls Setup above Settings — and Setup is reached *from*
Settings via "Check Permissions…" (`AppDelegate.swift:1121`), so both being open
is a normal state, not an edge case. Separately, `present()` re-centers on every
call, and `presentSetup`'s re-entrancy guard routes a repeat click through
`present()` — so re-fronting throws away a window the user had moved.

**Done when:** the re-front is scoped to returning from a permission prompt (or
to "not already frontmost within this app"), and re-presenting an already-open
window stops re-centering it.

---

# P3 — record-keeping, coverage, and nits

### V10 — Layout constants are minted per file, so no two surfaces can agree by construction

**Shipped in `6e6f86eb` (T1).**
**Surface:** all five.
**Code:** three un-tokenized content widths —
`PopoverPanelViewController.swift:104` (623),
`AudiouterCore/Sources/AudiouterSettingsUI/SettingsForm.swift:16` (460),
`OnboardingViewController.swift:40` (500). Eight corner radii, none in `Tokens`:
12 (`ControlPanelBackingView.swift:31`, `DeviceIconWellView.swift:66`,
`AppDelegate.swift:1500`), 11 (`SilenceFallbackBannerView.swift:37`,
`SystemAirPlayNoteBannerView.swift:116`), 10 (`GroupedSectionView.swift:53`,
`PermissionRowView.swift:497`), 9 (`AppearanceSettingsViewController.swift:353`),
7 (four sites), 6 (four sites). Five animation durations from 0.12 to 0.45.
`PopoverColumnGrid.selectionHighlightCornerRadius` exists and is honored by
`AppRowView.swift:672` but hard-coded as `7` at `DeviceRowView.swift:2117` and
`GroupRowView.swift:372`. `SettingsForm.swift:132-135`'s pane margins are
re-typed verbatim at `AudioSettingsViewController.swift:210-213`.
`OnboardingViewController.swift` uses `Self.contentWidth - 56` at five sites,
where 56 is an undeclared restatement of its own 28+28 edge insets (`:95`).

Nothing here is individually wrong; together they are why V4 and V7 exist.

**Done when:** corner radii and animation durations live in `Tokens.Layout`, and
each surface's content width and margins are declared once in its own module
rather than re-typed per pane. This is one bounded task, best done before any
other visual item so the fixes have somewhere to land.

### V11 — Six custom `draw(_:)` overrides carry no documented reason

**Shipped in `bf2bd38c` (P2).**
**Surface:** POP, GRP, SET.
**Code:** root `AGENTS.md:186,203` sanctions seven Warm Signal custom-drawn
pieces and requires any other deviation to record its "why" in the nearest
AGENTS.md. Six sites do not:
`DeviceRowView.swift:2102`, `AppRowView.swift:666`, `GroupRowView.swift:370`
(the three hover/selection pills), `MixerWindowController.swift:591`
(`WarmPanelView`) and `:610` (`HairlineView`),
`AudiouterCore/Sources/AudiouterWindowUI/IconPickerViewController.swift:481`
(`WarmPreviewTileView`), `AudioSettingsViewController.swift:962`
(`BorderedListView`).

Six others are properly documented, so the convention works — these are the gaps.

**Done when:** each has a one-clause "why" in its folder's AGENTS.md, or is
replaced by system chrome.

### V12 — Two banners with one design bypass the token that carries Increase Contrast

**Shipped in `020d2819` (T4).**
**Surface:** POP vs ONB.
**Code:** `AudiouterCore/Sources/AudiouterPopoverUI/SilenceFallbackBannerView.swift:40,41,67,68`
uses raw `NSColor.systemOrange` at 0.14 / 0.40; the visually identical onboarding
banner uses `Tokens.Color.warning` at 0.14 / 0.4
(`OnboardingViewController.swift:388-389`). Separately,
`AudiouterCore/Sources/AudiouterPopoverUI/SystemAirPlayNoteBannerView.swift:40-42`
returns raw `.systemBlue` / `.systemOrange` for its info tier, for which no
`Tokens.Color` case exists at all.

**Done when:** both banners read `Tokens.Color.warning`, and an info tier is
added to `Tokens` (with the light/dark/Increase-Contrast trio the module
requires).

### W7 — Window-restoration policy is decided on one window out of five

**Shipped in `c8df2082` (P3).**
**Surface:** all.
**Code:** `OnboardingWindowController.swift:61` is the app's only `isRestorable`;
`applicationSupportsSecureRestorableState` appears nowhere in
`AudiouterCore/Sources`.

Unchanged since the old `N2`. Behaviorally inert today (the delegate method
defaults to `false`), but it reads as unfinished rather than decided.

### W8 — The quit indicator is a sixth window with none of the fifth's rules

**Shipped in `c8df2082` (P1).**
**Surface:** quit indicator (outside the audited five; found in passing).
**Code:** `AppDelegate.swift:1466-1500`.

`QuittingIndicatorPanel` sets `level = .floating`, `hidesOnDeactivate = false`,
raw `NSColor.clear` (siblings route clear through `Tokens.Color.clear`), and a
raw `.popover` material while `Tokens.Material.popover` (`Tokens.swift:777`)
sits unconsumed by anything — note that token resolves to `.menu`, so adopting
it is a look change, not a refactor. Alone among the app's windows it sets no
`collectionBehavior`, so quitting from a fullscreen Space may put it on a
different Space or nowhere.

### W9 — No test covers which surface a menu-bar click produces

**Intent satisfied by U4's click-policy tests (`cd051a2d`)** — the arbitration
now lives in `AppSurfaceController`, where it is directly tested.
**Surface:** all.
**Code:** `AppDelegate.swift:302-338`; `AudiouterCore/Tests/AudiouterCoreTests/`
has no `AppDelegate` test file.

W1, W3 and W4 are one bug in three costumes: the arbitration between five
surfaces inside `onButtonClicked` and the `open*` methods. That logic has no
direct test — `MixerWindowControllerTests`, `SettingsWindowControllerTests` and
`ControlPanelWindowControllerTests` each cover their own controller in
isolation. **Doing this first makes W1, W3 and W4 cheap and safe.**

### V13 — The panel's only close affordance has no visual regression coverage

**Shipped in P4 (this program's final commit)** — `window-snapshot` now
composites the panel's frame view, so the close button is in the fixtures.
**Surface:** SHELL.
**Code:** `AudiouterCore/Sources/window-snapshot/main.swift:379-440` —
`snapshotControlPanel` composites `panel.contentView`, never the window frame
view, so `mixer-5-panel-chrome-*.png` cannot show the standard close button.
`ControlPanelWindowControllerTests.swift:108-117` does assert
`isHidden == false`, which is why this is P3 — but the one control that prevents
a user being stranded in a dockless app is invisible to the snapshot suite. (The
button's absence from the current fixtures is the tooling artifact, not a
defect.)

### V14 — Device detail puts a colon on one row out of five

**Shipped in `9bc5a3da` (T5).**
**Surface:** GRP.
**Code:** `AudiouterCore/Sources/AudiouterWindowUI/DeviceDetailViewController.swift:144`
— "In groups:" carries a colon; "Status", "Available", "Volume" and "Kind" do
not. Visible together in `mixer-4-device-detail-*.png`.

### V15 — Onboarding's header icon is a placeholder in unbundled runs

**Still owed — verify on the signed build.**
**Surface:** ONB.

`onboarding-light-initial.png` shows a generic system icon where the app icon
belongs. Expected for a non-bundled binary, and
`docs/plans/phase-3-findings/EXECUTION-REPORT.md` §3 already lists "real app
icon rendering" as owed on the signed build. Recorded so the next reader of the
snapshots does not re-file it.

---

## Suggested order

`W9` first — it is the harness for `W1`, `W3` and `W4`, which are the same
function. `V10` before any other visual item, so the fixes have somewhere to
land. `W6` and `W10` are two faces of the onboarding re-front — fix as one
task. Everything else is independent.

---

## Checked and explicitly not findings

Listed so they are not re-audited.

- Settings' stock grey chrome against the popover's warm canvas — Warm Signal
  §5.2, decisions i and j.
- Groups' grey sidebar against its warm content pane — Warm Signal §5.3.
- The New Group sheet's stock, unskinned name field against the editor's
  `WarmNameFieldCell` — §5.3 puts the sheet on Apple's styling.
- Groups' 28pt rows against the popover's 42pt — locked in
  `warm-signal-screens-followup.md`.
- The popover's uppercase section headers, unique among the five surfaces —
  Warm Signal §5.1 "section micro-labels".
- "AirPlay Devices" in the popover while onboarding bans the word — decision m
  keeps AirPlay wording in device context.
- The group master's stock unskinned slider beside three skinned faders —
  documented at `AudiouterSharedUI/AGENTS.md:32`.
- The Control Panel bubble fill — already repointed to `Tokens.Color.canvas`
  (`ControlPanelBackingView.swift:73-79`); Warm Signal §5.4 satisfied.
- `NSApp.activate(ignoringOtherApps:)` at six call sites — checked against the
  macOS 14 deployment target; not deprecated, compiles without warning.
- Every window's Space behavior — all five set
  `.moveToActiveSpace + .fullScreenAuxiliary`.
- Groups' and Settings' frame persistence — both restore before arming autosave.
- `PopoverHeaderView.swift:77`'s stale `width: 460` init frame — inert, the next
  line sets `translatesAutoresizingMaskIntoConstraints = false`.
- Increase Contrast — reaches every `Tokens.Color` consumer through the three
  dynamic providers (`Tokens.swift:805,847,911`). Only the raw literals in V5
  and V6 sit outside it.
