# PLAN — One-surface app (roadmap 032)

Owner decisions locked 2026-08-07. Execution plan produced the same day by a
research-grounded planning pass (every file:line verified against this branch
at commit 82cab605). Supersedes punch-list items W1–W5
(`PLAN-UI-CONSISTENCY-PUNCHLIST.md`); W6+W10 shipped separately (5ae36594).

## End state

One window replaces five. A single panel — the evolved
`ControlPanelWindowController` — hosts three screens (Mixer = today's popover
content, Groups, Settings) behind a **tab-bar-style switcher** (owner
addendum 2026-08-07, supersedes the earlier segmented-control choice): three
icon+label tabs in the macOS toolbar-tabs idiom — SF Symbols with text
labels, the native Mac translation of the HIG's tab-bar pattern (the HIG
scopes literal tab bars to iOS/iPadOS; on the Mac this role belongs to
toolbar tabs). A **Pin** button sits beside Quit in the header.

**Header material (owner addendum 2026-08-07): translucent, three tiers.**
The header strip (tabs + pin + quit) is the app's floating controls layer
per current Apple guidance — Liquid Glass on macOS 26+, with content
scrolling edge-to-edge beneath it:
1. macOS 26+: `NSGlassEffectView` with the header controls as its
   `contentView` (never a sibling — the system needs to own legibility
   treatments). Corner radius matched to the bubble; a subtle warm tint is
   allowed via the tint property. On 26+ the PINNED mode's standard title
   bar is already glass for free; the header's glass must visually merge
   with it, not stack under it (one glass layer per view — never
   glass-on-glass).
2. macOS 14–15: `NSVisualEffectView` fallback with
   `blendingMode = .withinWindow` — frosts the app's own content scrolling
   under the header. `.behindWindow` is deliberately NOT used here: it
   composites the desktop through the window, which fights the opaque Warm
   Signal canvas and reads as a different effect entirely.
3. Reduce Transparency (any OS): opaque warm header — reuse the A1
   fallback pattern; the `rendersOnGlass` flag idiom already in
   `SidebarViewController` is the precedent for OS-gating.
The content layer (Mixer/Groups/Settings screens) stays opaque Warm Signal
canvas — glass is chrome-only, never the bubble body. Unpinned
(default): anchored under the status item with the beak, click-outside
dismisses, menu-bar click toggles. Pinned: normal movable window, remembers
its frame across launches, can sit behind other apps; menu-bar click always
fronts it; **closing it does NOT unpin — the next click reopens it at its
remembered position**. The app stays menu-bar-only (`.accessory`) in both
modes. **Per-screen sizes, animated** (top edge anchored): Mixer exact-fit
(~623), Groups 560×505, Settings per-tab. The standalone Settings window, the
standalone Groups window, the `AIRPLAY_CONTROL_PANEL` flag fork, and the
NSPopover are all deleted. Setup stays its own floating window. **About stays
its own window** (owner call — the one deliberate exception).

Copy decisions: Groups uses "Speakers" in both panes; the permission flow is
named "Setup" everywhere ("Check Permissions…" → "Open Setup…", window title
"Setup"); Settings › Audio buffer applies immediately (Apply button deleted).

## Architecture: one host, manners flip

Retire NSPopover; evolve the shell. Reasons (probed, not guessed):
1. No public API detaches an NSPopover into a window; re-assigning
   `window.contentViewController` snaps to a 500×500 fallback
   (`ControlPanelWindowController.swift:184-193`) and the Mixer view tree is
   heavily stateful (`PopoverController.swift:182, 343, 280-293`) — pin/unpin
   must never re-host content. One window whose *manners* flip never does.
2. NSPopover can't do frame persistence or sit-behind-other-apps — keeping it
   means two hosts forever.
3. The shell already replicates the popover's tricks: anchor/clamp
   `show(anchorRect:)` :266-340, beak (`ControlPanelBackingView`), fades with
   Reduce Motion :357-391, Esc-close :453-457, headless gating :317-320,
   size-preserving content swap :194-208, 14 green tests.

Shell gains: unpinned close-on-`windowDidResignKey` (with a status-click race
guard — see R1), and a pinned profile (`isMovable = true`,
`hidesOnDeactivate = false`, `level = .normal`, real title bar, beak hidden,
frame autosave via the `setFrameUsingName`-first pattern from
`MixerWindowController.swift:244-259`).

New `AppSurfaceController` lives in **AudiouterPopoverUI** (library ⇒
testable; `AudiouterApp` is invisible to tests — R9). That target gains deps
on `AudiouterWindowUI` + `AudiouterSettingsUI` (`Package.swift:170-174`).
Screens: Mixer = `PopoverPanelViewController` via a host-agnostic
`PopoverController`; Groups = `MixerWindowController.contentController`
(:315-318); Settings = `SettingsRootViewController` made public, tabs moved
to an in-content style, `onFittedContentSizeChange` drives surface height
(`SettingsWindowController.swift:335-342`).

## Task list

One agent per task; strictly serial in this worktree; every task ends with
its scoped verification, then the full suite green, then one commit + push.

### Wave 1 — pre-unification punch-list foundations

- **T1 · V10 Tokens.Layout** — corner radii + animation durations into
  `Tokens.Layout` (`AudiouterSharedUI/Tokens.swift:739-758`); per-surface
  width/margin constants declared once per module. Consumers:
  `PopoverPanelViewController.swift:104` (623), `SettingsForm.swift:16,132-135`,
  `OnboardingViewController.swift:40` + five `contentWidth − 56` sites,
  `ControlPanelBackingView.swift:31`, `AppDelegate.swift:1501`,
  `SilenceFallbackBannerView.swift:37`, `SystemAirPlayNoteBannerView.swift:116`,
  `GroupedSectionView.swift:53`, `PermissionRowView.swift:497`,
  `AppearanceSettingsViewController.swift:353`, `DeviceIconWellView.swift:66`,
  `DeviceRowView.swift:2117`, `GroupRowView.swift:372`,
  `AudioSettingsViewController.swift:210-213`. ZERO visual change.
  Model **sonnet**. Verify: `swift run popover-snapshot` byte-identical PNGs;
  full suite.
- **T2 · V1 buffer applies immediately** — delete Apply Settings/Apply &
  Reconnect (`AudioSettingsViewController.swift:129-134, 452-462, 495-500`);
  popup change fires the apply path directly; reconnect cost in the hint.
  Model **sonnet**. Verify: `--filter AudioSettingsLatencyTests`; full suite.
- **T3 · V7 one bezel family** — `PopoverPanelViewController.swift:477-484`
  `.smallSquare` → `.accessoryBar` + `showsBorderOnlyWhileMouseInside`
  (matching `PopoverHeaderView.swift:206-208`); fix the lying comment and
  `AudiouterSharedUI/AGENTS.md:19`. Model **haiku**. Verify:
  `--filter PopoverPanelHeaderTests`; full suite.
- **T4 · V4/V5/V6/V12 raw-color eliminations** — `GroupRowView.swift:370-379`
  → tokens + `PopoverColumnGrid` alphas (:472,476) +
  `selectionHighlightCornerRadius`; `AppearanceSettingsViewController.swift:318-324`
  dark preview derives from `Tokens.Color.well` (or a pinning test);
  `DeviceIconWellView.swift:87-88,228-231` badge → tokens, re-stamp on
  appearance change; `SilenceFallbackBannerView.swift:40-41,67-68` →
  `Tokens.Color.warning`; `SystemAirPlayNoteBannerView.swift:40-42` new
  `Tokens.Color.info` case (light/dark/Increase-Contrast trio + written
  contrast rationale). Depends: T1. Model **sonnet**. Verify:
  `--filter GroupRowViewTests`, `--filter DeviceIconWellViewTests`; full suite.
- **T5 · V2/V3/V8/V9/V14 copy pass** — "Devices"→"Speakers"
  (`SidebarViewController.swift:295,352,377-381,612` — R8: update the node
  key and every test literal together); Setup naming
  (`OnboardingWindowController.swift:60`, `GeneralSettingsViewController`
  "Check Permissions…" → "Open Setup…"); ellipsis + Title Case
  ("New Group…" `MixerWindowController.swift:764` +
  `SidebarViewController.swift:192,196`; "Delete Group…"
  `GroupEditorViewController.swift:214`; "Add App…"
  `AudioSettingsViewController.swift:702`; Title Case
  `AppearanceSettingsViewController.swift:519,521`; ellipsis
  `PermissionRowView.swift:258,265`); V8 plain-words hint
  (`AudioSettingsViewController.swift:432-438`); V9 §5.9 empty states
  (`MixerWindowController.swift:751-752` + `PopoverController.swift:941,999`,
  incl. "Looking for speakers…"); V14 colon
  (`DeviceDetailViewController.swift:144`). Depends: T2, T4 (shared files).
  Model **sonnet**. Verify: full suite; grep for old strings returns nothing.

### Wave 2 — unification (strictly ordered)

- **U1 · shell pin/transient manners** — `setPinned(_:)` profile flip;
  unpinned close-on-resign-key with dismissal-timestamp seam (R1); autosave
  `setFrameUsingName`-first. Appearance bits only — NEVER flip
  `.titled`/`.closable` (R6, :87-100). Additive; Groups-in-shell unchanged
  this commit. Files: `ControlPanelWindowController.swift`, its tests,
  `AudiouterSharedUI/AGENTS.md`. Model **opus**. Verify:
  `--filter ControlPanelWindowControllerTests`; full suite.
- **U2 · PopoverController host-agnostic** — visibility from a host-set flag
  (`isEffectivelyShown` reads it ∨ `test_isShownOverride`);
  `popoverDidShow/DidClose` bodies → host-callable `surfaceDidShow/Hide`;
  `setPopoverAnimates` behind a resize seam. Preserve the hidden-rebuild
  gates (R4: :546-565, :2696). NSPopover stays alive this commit — all 117
  `PopoverControllerTests` pass untouched. Model **opus**. Verify:
  `--filter PopoverControllerTests`; full suite.
- **U3 · AppSurfaceController + switcher + pin button** — new
  `AudiouterPopoverUI/AppSurfaceController.swift`; `Package.swift:170-174`
  deps; `PopoverHeaderView.swift` Groups/Settings buttons → the tab-bar
  switcher + Pin (keep Quit) per the End-state addendum: three icon+label
  tabs (SF Symbols — e.g. `slider.horizontal.3` Mixer,
  `hifispeaker.2` Groups, `gearshape` Settings; verify names exist at the
  deployment target), hosted on the three-tier translucent header
  (`NSGlassEffectView` on macOS 26+ via `#available`, `NSVisualEffectView`
  `.withinWindow` below, opaque warm under Reduce Transparency — see End
  state). Tab selection is the screen switch; keyboard: ⌘1/⌘2/⌘3.
  Switcher rendering detail (owner nitpick 2026-08-07, Apple Music as the
  reference): render the tabs as the toolbar-item-group idiom — capsule
  segments sharing one glass lozenge, the selected segment getting the
  filled capsule (in the pinned title bar this is `NSToolbarItemGroup`
  with `selectionMode = .selectOne`; the unpinned header's custom row
  mimics the same capsule geometry). And NO hard border/hairline on the
  glass tiers — Liquid Glass defines its edge by refraction, so stroked
  edges belong only to the opaque Reduce-Transparency fallback.
  `AppSettings` gains `surfacePinned`;
  `SettingsRootViewController` public + in-content tabs; per-screen sizing
  bridge (Mixer exact-fit channel `panelContentDidChangeHeight`; Groups
  560×505 — R2: the shell's 720×460 at `AppDelegate.swift:1043` /
  `ControlPanelWindowController.swift:103` is stale; Settings
  `onFittedContentSizeChange`); every swap routes through the shell's
  `setContent` (R3 — never assign `contentViewController` directly). App not
  yet cut over. New `AppSurfaceControllerTests`. Model **fable**. Verify:
  `--filter AppSurfaceControllerTests`; full suite.
- **U4 · AppDelegate cutover + click policy** — click handler :302-348 →
  surface policy (transient toggle / pinned always-front / pinned-closed
  reopen at remembered frame / Setup-open still re-fronts Setup :304-307;
  permission checks :330-347 preserved); `showPopoverHome` :939; menus/⌘,
  :951-999; open paths :1005-1096; `openSettings` :1101-1127 → Settings
  screen; event fan-out :1410-1419; `docs/SPEC.md` §9;
  `AudiouterApp/AGENTS.md`. Policy lives in `AppSurfaceController` ⇒ directly
  testable (the W9 answer). Old windows compile but unreachable. Model
  **opus**. Verify: click-policy tests (transient / pinned-open /
  pinned-closed / Setup-open); `AIRPLAY_BACKEND=mock swift run` smoke; full
  suite.
- **U5 · retire standalone Settings window** — delete the NSWindow half of
  `SettingsWindowController.swift` (keep panes + sizing machinery; the four
  sizing traps :27-96 survive as surface rules — R5); retarget its 16 tests
  at rootVC seams; `settings-snapshot/main.swift`;
  `AudiouterSettingsUI/AGENTS.md`. Model **sonnet**. Verify:
  `--filter SettingsWindowControllerTests`; `swift run settings-snapshot`;
  full suite.
- **U6 · retire standalone Groups window + kill the flag** —
  `MixerWindowController.swift:156-260, 297-303` window half deleted (becomes
  screen controller); `AppDelegate.swift:242,247-255` (`useControlPanel`,
  `controlPanelSessionActive`, `controlPanel`) die;
  `scripts/make-app.sh:524-533` LSEnvironment entry removed;
  `window-harness/main.swift:98`; `window-snapshot` fixtures; retarget
  `MixerWindowControllerTests` (38) + `GroupsWindowTextColorLockTests` +
  `GroupsHeaderParityTests`; `AudiouterWindowUI/AGENTS.md` +
  `AudiouterApp/AGENTS.md`. Model **sonnet**. Verify:
  `--filter MixerWindowControllerTests`; `swift run window-harness`;
  `bash scripts/make-app.sh` plist check; full suite.
- **U7 · retire NSPopover** — drop `popover`, `NSPopoverDelegate`,
  `toggle(relativeTo:)` from `PopoverController.swift`;
  `AudiouterPopoverUI/AGENTS.md`. Pure delete (tests use `test_` seams only).
  Model **sonnet**. Verify: `swift run popover-harness`; full suite.
- ~~U8 About tab~~ — DROPPED (owner: About keeps its own window).

### Wave 3 — post-unification punch list

- **P1 · A1 Reduce Transparency + W8 quit HUD** — RT fallbacks at the
  Settings background effect view (post-U5 home), `AboutView.swift:203-205`,
  `SidebarViewController.swift:503-534` (wash reads RT or the comment stops
  claiming it); quit HUD `AppDelegate.swift:1489-1502`: `Tokens.Color.clear`,
  `Tokens.Material.popover` (resolves `.menu` — deliberate look change,
  `Tokens.swift:777`), `collectionBehavior`, RT fallback, T1's radius token.
  Model **sonnet**. Verify: `--filter SidebarWarmSurfaceTests`; full suite.
- **P2 · V11 draw-override whys** — one-clause "why" in the nearest AGENTS.md
  for `DeviceRowView.swift:2102`, `AppRowView.swift:666`,
  `GroupRowView.swift:370`, `MixerWindowController.swift:591,610`,
  `IconPickerViewController.swift:481`, `AudioSettingsViewController.swift:962`.
  Model **haiku**.
- **P3 · W7 restoration decision** — surface window `isRestorable = false`;
  `applicationSupportsSecureRestorableState → true`; one AGENTS line. Depends
  P1 (AppDelegate contention). Model **haiku**. Verify: full suite.
- **P4 · V13 + snapshots + bookkeeping** — `window-snapshot/main.swift:374-442`
  composites the frame view (close affordance visible); rerun all four
  generators; annotate `PLAN-UI-CONSISTENCY-PUNCHLIST.md` (W1–W5 superseded,
  done markers); update this doc's execution log; roadmap 032 note. Model
  **sonnet**. Verify: generators exit 0; fresh PNGs; full suite.
- V15: no task — owed on the signed build only.

## Risks (verified in code)

- **R1** status-click race: close-on-resign fires before the button action →
  never-closes flicker. Dismissal timestamp or event-monitor guard; U1's
  hardest part. No existing coverage.
- **R2** Groups size: shell opens 720×460 (stale) vs designed 560×505.
- **R3** `contentViewController` reassignment snaps 500×500 — always route
  through `setContent`.
- **R4** hidden-rebuild gates (`PopoverController.swift:546-565, :2696`;
  `MixerWindowController.swift:285-289`) must survive or backend events
  become hidden rebuild storms (B8 class).
- **R5** Settings sizing traps 1–4 (`SettingsWindowController.swift:27-96`)
  transfer to the surface; keep the probe notes alive.
- **R6** never flip `.titled`/`.closable` — kills `windowWillClose`/Esc
  (`ControlPanelWindowController.swift:87-100`).
- **R7** Setup interplay: Setup is `.floating` (5ae36594); unpinned surface
  closes on resign-key when Setup takes focus — acceptable, but suppress
  close-on-resign while a SHEET is attached (`GroupCreationSheetController`)
  or the sheet dies mid-edit. If "Open Setup…" dismissing the transient reads
  badly live, suppress while Setup is open too.
- **R8** copy pass: sidebar tests pattern-match `.header("Devices")`
  (`SidebarViewController.swift:381`) — update key + literals together.
- **R9** `AudiouterApp` target is test-invisible — all testable behavior goes
  in library targets.

## Execution rules (every agent)

Work in this worktree on branch `claude/foreman-roadmap-002-f7273b` — never
switch branches, never merge, never touch `ROADMAP.jsonl` (orchestrator owns
it). Read root `AGENTS.md` + the nearest `AGENTS.md` of every folder you
edit; docs land in the same commit as code. Stock AppKit only; Warm Signal
owns backgrounds/gold. Headless tests: `test_` seams, never
visibility/draw-cycle assertions; never de-serialize a `@MainActor` suite.
Before committing: stage everything, run `bash scripts/self-review.sh`, fix
what it surfaces, commit once (imperative subject, body says why), push.
Scoped tests first, the commit's guard runs the full suite.

## Execution log

- 5ae36594 — W10+W6 shipped (Setup window floating; pre-program).
- (append per task)

## Live verification owed to Alec before merge

Pin/unpin transitions; click-outside vs status-click; frame memory across
relaunch; pinned-closed reopen; Setup-over-surface; sheet-over-transient;
per-screen resize feel; bundled build without the LSEnvironment flag
(`make-app.sh`); Reduce Transparency + Increase Contrast passes; the V9
empty states.
