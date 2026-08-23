# HANDOVER — Alignment wizard (`claude/wizard-ui-handoff-a6ca38`)

Written 2026-08-23 for an agent with **no access to the working
conversation**; **§8 (2026-08-23, second session) is the newest state** —
§4's sheet plan is BUILT and five design passes have run on top. This file
supersedes `HANDOFF-wizard-v2.md` (kept only for its critique evidence and
earlier fix-list history). Read this top to bottom before touching anything.

---

## 1. Where you are

- **Worktree:** `.claude/worktrees/device-list-cleanup-opus-4a8ff0` (the
  directory name is historical), branch `claude/wizard-ui-handoff-a6ca38`
  (base `202dc4e4`, pushed to origin). **Everything below is UNCOMMITTED
  working-tree state.** Do not restore from HEAD — the tree is the truth.
  Nobody has committed on purpose: Guard 7 (staged-diff self-review) is
  Alec's step, and Alec has not yet given the go-ahead to commit.
  The old `.claude/worktrees/wizard-ui` tree holds the PRE-SHEET state
  untouched, as fallback only — never work there.
- `main` is **merge-only.** Work stays on this branch until Alec merges. The
  branch reaches `main` as BOTH a local `git merge` AND a GitHub PR.
- **Build & test through the wrappers ONLY** (`bash scripts/build.sh`,
  `bash scripts/run-tests.sh --filter <Suite>`) — never bare `swift
  build`/`swift test`. TRAP: piping build/test output to `| tail` returns
  tail's exit code (0) — check exit codes UNPIPED.
- Read `AGENTS.md` (root) and
  `AudiouterCore/Sources/AudiouterPopoverUI/AGENTS.md` before editing; they
  are binding and have already been updated for this work.
- **Design authority, in priority order:**
  1. `dev/notes/wizard-stage-v2-spec.md` — the binding spec. **§0b is the
     newest and wins**: the owner's rulings from the 2026-08-23 critique.
  2. `dev/notes/wizard-v2-handoff/wizard-mock-v2.html` — the approved v2
     mock (the "v2 · Two Voices, on the Plate" section is the target look;
     earlier sections are history). The BUILD has since moved past the mock
     on Alec's rulings (plates are now the hero, stage is a strip) — where
     they conflict, §0b wins over the mock.
  3. `dev/notes/wizard-v2-handoff/after-sheet/*.png` — the CURRENT renders
     (post-sheet, post-design-passes; see §8). `after/` is the pre-sheet
     history — note BOTH `after/` and the first `after-sheet/` set were
     missing the nameplate micro-labels and key chips (the
     `usesSingleLineMode` bug, §8), so the current set showing them is the
     fix, not a regression.
  4. `.impeccable/critique/2026-08-23T12-51-09Z__*.md` — the design critique
     that produced §0b.

---

## 2. What this feature is

A Bluetooth speaker-alignment wizard. The user answers "which speaker
clicked first?" ~15 times; a Bayesian posterior narrows; a proposal plays;
they confirm by ear. It measures the speaker's latency and writes a SYNC
trim so the speaker plays in time with the rest of the house.

The wizard was rehosted out of a cramped popover-anchored panel into a
dedicated floating window with a live "stage" visualization: two lights =
the two ends of the 95% credible interval riding one wire on a fixed dark
plate. **Sync Green `#2BFF8F`** = the target speaker, **Party Magenta
`#FF90E9`** = the reference. Confidence climbs a rung ladder with authored
transitions; the lock fuses the two lights to warm white `#FFF4E2`.

**Colour rule (Alec, 2026-08-23, now binding app-wide — see the memory
`feedback-secondary-colors-need-ask` and AGENTS.md):** gold is the app's
primary colour, ALWAYS. Sync Green / Party Magenta are the marketing site's
two secondaries and are sanctioned ONLY inside this wizard (two speakers need
two identities). Using either hue anywhere else requires asking Alec first,
with a clear rationale — never by analogy to this screen.

---

## 3. What has been done (timeline)

1. **v1 rehost** — panel → dedicated window; the wizard now survives popover
   close and dies with its own window or when the target device disappears.
2. **v2 "Two Voices, on the Plate"** — the rung ladder, the two-identity
   colour system, the drawn plate buttons, the lock sequence. Alec's live
   test: "technically right, visually amateur — doesn't match the mock."
3. **Fix pass** (first this session) — a four-agent visual critique found 6
   root causes (plate cell drawing outside its frame; keycap chip stacked
   not trailing; "They sound together" truncating to "T"; text right-aligned
   not centred; no bevel + wrong rim alpha; lock ring never turned white).
   All fixed; the snapshot tool was made headless so the lock's 1.44 s
   settle lands in the captured frame.
4. **`/impeccable critique`** (26/40) + **owner rulings** — the current
   state. Alec's rulings are in spec §0b and are all built:
   - **Answer plates are the hero** (236×88), stage is a 112 pt strip.
   - **The question is on the question screen**: readout = `Which clicked
     first? · <rung word>`; the interval moved to the stage's tooltip.
   - **Clock removed** → the top row's right slot carries the click count
     (since the 2026-08-24 owner batch: `Click n of about 15`, intro
     `About 15 clicks` — sentence-case caption, not the old mono-caps
     `CLICK n OF ABOUT 15` / `ABOUT 15 CLICKS`).
   - **Kept hero line**: `<Target> is ready to play with everything.`, with
     `Change it anytime from the SYNC control.` as a caption and `247 ms ·
     kept` staying the stage's caption. The number is kept visible on
     purpose (users may edit it later without re-running the wizard).
   - **Full-strength rims/keycaps in dark** (was 0.45 alpha → measured olive/
     mauve); light keeps the Deep companions at 0.9.
   - **Intro stage stamps each speaker's name under its light** so the
     colour→speaker mapping is taught before the first tap.
   - **Neutral armed span + neutral locked wire** (no identity before there's
     a belief; none after the two have fused).
   - **"Set it by hand" → "Set it manually"**; offered on the PROPOSAL corner
     row (beside Stop) and as an unsettled SECONDARY, never a primary. All
     three bow-outs share one layout: sentence · `Try again` (gold default) ·
     `Done`.
   - **`Back ⌘Z` → `Undo ⌘Z`**; disabled Start wears no keycap; locked halo
     enlarged (56 @ 0.55) to carry the fusion statically for Reduce Motion;
     light-mode room spill turned OFF (measured invisible: <1% neutral).
   - Short screens now centre in the band under the readout (killed the
     58 pt intro dead-band).

### Current build state — GREEN
- `bash scripts/build.sh` — exit 0.
- Six suites via `run-tests.sh`, **210 tests pass**: AlignmentStageViewTests
  22 · AlignmentPlateCellTests 9 · AlignmentTokenContrastTests 5 ·
  PopoverBTAlignmentUITests 50 · PopoverLocalSyncTrimTests 6 ·
  PopoverControllerTests 119. (Wrapper counts vary ±; the run reports 210 in
  6 suites.)
- **Live build ready:** `build/Audiouter Wizard v4.app`
  (`com.audiouter.Audiouter.wizardv4`). Wizard entry: right-click a Bluetooth
  row (or the Mac's row) in the popover → "Align speaker…".
- 18 renders in `dev/notes/wizard-v2-handoff/after/` are the current look.

### Key files
All in `AudiouterCore/Sources/AudiouterPopoverUI/` unless noted:
- `AlignmentStageView.swift` — the stage: rung ladder, look table,
  transitions, lock sequence, name stamps.
- `BTAlignmentWizardView.swift` — window content: bands, plates, copy,
  keyboard, the locked strings.
- `AlignmentPlateCell.swift` + `AlignmentPlateButton.swift` — the drawn
  tactile plate buttons.
- `AlignmentWizardWindowController.swift` — the window + room-spill washes.
  **This file is what the sheet work replaces (§4).**
- `AudiouterSharedUI/Tokens.swift` (8 stage tokens) +
  `PopoverColumnGrid.swift` (`alignPlateCornerRadius`).
- `AudiouterCore/BTAlignmentWizardSession.swift` — 2 tiny accessors only
  (the session logic is on `main` already, from roadmap 056).
- `Sources/wizard-snapshot/` — the offscreen PNG renderer (`swift run
  wizard-snapshot <dir>`); renders 18 states headless.
- Tests: the four `Alignment*Tests` + `PopoverBTAlignmentUITests`.

---

## 4. ~~THE MAIN REMAINING WORK~~ — convert the window to a SHEET — **DONE, see §8**

Alec's decision (2026-08-23, approved): **the wizard should be a modal
sheet, not a separate floating window.** A discovery pass validated it. His
mental model ("a modal for a new task, the rest goes inert, a clear dismiss")
is exactly a macOS sheet; the half that's iOS/web (dimmed backdrop +
click-outside-to-dismiss) is deliberately NOT done — click-outside would
throw away ~15 answers and hiccup every speaker twice, so a sheet's
"click-outside beeps, doesn't dismiss" is the correct behaviour. **Do not
build a scrim or click-outside dismissal.**

### The plan (Option 2 from the discovery)
Present the wizard content as a **view controller via `presentAsSheet`** on
the popover/pinned surface — the SAME idiom the Groups "New Group" editor
already uses on this exact shell.

**Precedent to copy:** `MixerWindowController.swift:344-352`
(`splitViewController.presentAsSheet(sheet)`), and its host protections:
- The shell already blocks resign-key dismissal while a sheet is attached:
  `ControlPanelWindowController.swift` rule R7 `hasAttachedSheet`
  (around `:688-690`).
- The menu-bar click fronts the surface instead of closing it while a sheet
  is up: `AppSurfaceController.swift:335-342`.
- `NSAlert.beginSheetModal` precedents: `GroupEditorViewController.swift:701,
  850`.

**Why it works both pinned and unpinned:** the sheet rides the bubble; the
host CANNOT `performClose` while a sheet is attached (AppKit refuses), so the
whole "wizard survives popover close" contract becomes moot — the popover
can't close under it. App-switch tuck-away (`hidesOnDeactivate`) hides both
and AppKit restores both; audio keeps running.

**A latent bug this fixes:** today `AlignmentWizardWindowController.present()`
calls `makeKeyAndOrderFront` (`:105-115`), and the UNPINNED popover dismisses
on `windowDidResignKey` when another of our windows takes key
(`ControlPanelWindowController.swift:709-757`, condition 4). So launching the
wizard from the unpinned bubble currently closes the bubble. A sheet removes
that entirely.

### Concrete edits
- `AlignmentWizardWindowController.swift` → an
  `AlignmentWizardViewController`: the `WarmCanvasView` + `RoomSpillView`
  become its `view`; `reframeSpillLayers()` moves into `viewDidLayout()`;
  `fitToContent()` becomes `preferredContentSize` (AppKit animates sheet
  resizes for you — the wizard's per-screen height changes are free).
- `PopoverController.swift`: `startBTAlignmentWizard`/`present` path
  (`:3705-3727`) → `presentAsSheet`; `tearDownBTWizard`/`closeSilently`
  (`:4029-4053`) → `dismiss(_:)`. Delete the `onUserClose`/✕ path — a sheet
  has no ✕; **Stop is the close** (Esc/⌘. already map to `session.cancel()`).
- `PopoverBTAlignmentUITests`: drop the close-survival test
  (`popoverCloseLeavesTheWizardRunningInItsOwnWindow` and the ✕-close
  simulation), KEEP the "deselecting the reference kills the run" test and
  all the screen/copy/keyboard tests. Add: presenting attaches a sheet;
  Stop/Done dismiss it; the host can't close while it's up.
- AGENTS.md: update the wizard's lifecycle bullet (it no longer "survives
  popover close in its own window" — it's a sheet that keeps the host open).
- `wizard-snapshot`: today it renders `AlignmentWizardWindowController`'s
  window content view directly; after the change, render the view
  controller's `view` at its `preferredContentSize`. Keep it headless. This
  is how you re-verify the 18 states.

### Risks / traps for the sheet work
- **Headless runs have no window.** Keep a `view.window?.isVisible`-style
  gate anywhere presentation is triggered (MixerWindowController already does
  this) so tests/snapshots don't try to attach a real sheet.
- The beak/backing window is itself a child window — **check z-order live**
  once (the sheet must sit above the beak).
- The wizard's `performKeyEquivalent` key map (←/→/Space/⏎/⌘Z/Esc) works
  unchanged: the sheet is its own key window and the responder chain walks
  the view. Verify Esc still reaches `session.cancel()` and doesn't get eaten
  as "cancel the sheet" before the view sees it.
- Reduce Motion: sheets animate in; that's fine and system-standard.
- ~1 day of work. It is a re-host, not a redesign — every screen, string,
  colour, and test outcome from §3 must survive it unchanged.

### Three open questions Alec should confirm at build time (recommended
### defaults in brackets — proceed on these if he's unavailable, flag them):
1. Past ~5 answers, should Stop confirm ("Discard 9 answers?") or stay
   immediate? [**Recommend: stay immediate** — matches today; a confirm adds
   a second modal over a modal.]
2. While the sheet is up, the menu-bar click fronts the surface and beeps
   instead of closing it (New Group behaves this way today). Acceptable?
   [**Recommend: yes** — consistent with the existing sheet.]
3. Target lost mid-run currently vanishes the wizard silently. With a sheet,
   add a one-line bow-out ("Kitchen HomePod went away" · Done)? [**Recommend:
   yes** — a silent vanish inside a modal is more jarring than out of a
   window.]

---

## 5. Roadmap entries added this session (on this branch, in `ROADMAP.jsonl`)

Both are UNCOMMITTED and numbered past `main`'s highest id (062) and
ios-staging's 063, so the merge is a clean union:
- **065** — Unsynced Bluetooth speaker = ALERT state on the SYNC chip; click
  offers guided (wizard) vs manual (SYNC drawer). This is Alec's other big
  point: nobody right-clicks, so the wizard is invisible; an unsynced BT
  device should wear an alert (not error) state and offer both paths on
  click. Depends on 056. **The §4 sheet work should land first** — it changes
  what "guided" opens into.
- **066** — Alignment wizard: remaining critique findings backlog (ruler unit
  labels, kept screen names which speaker is delayed, ±5 ms nudge on "Still
  off", stock pop-up chrome on the intro, WarmCanvasView grain, answer-grammar
  parallelism, magnitude phrasing). Owner-approved-copy / design calls to run
  as a scoped pass after the sheet decision. Depends on 056.

---

## 6. Everything else owed to close out this worktree

- **Commit** (Alec runs Guard 7 self-review) → merge + PR per the repo
  workflow (local `git merge` into `main` AND a GitHub PR so origin/main and
  local main stay in sync).
- **Live hardware pass**, including one real Stop/close mid-run on actual
  speakers (the re-anchor cost of a cancel is only headlessly tested).
- **Figma design-system mirror** of the new wizard screens (house rule; not
  started).
- **Purge test-build residue:** bundle ids `com.audiouter.Audiouter.wizardv1`
  through `.wizardv4` and the `build/Audiouter Wizard v2/v3/v4.app` bundles
  (`scripts/purge-dev-installs.sh`, dry-run first). v4 is the current live
  build — keep it until the sheet build replaces it (as `wizardv5`).
- When the sheet work is done, **re-render the 18 states**, eyeball vs the
  `after/` set + §0b, run the six suites, and hand over a FRESH-bundle-id
  build (`Audiouter Wizard v5` / `.wizardv5` — TCC grants are pinned to
  id+signature; never reuse a launched id).

---

## 7. Traps already learned — do not relearn

- `NSButton` is **FLIPPED** — all `AlignmentPlateCell` y-math is in flipped
  coords; the name stamps in `AlignmentStageView` are un-flipped (the view
  itself isn't flipped).
- `AlignmentPlateButton.alignmentRectInsets` is zeroed — the `.push` bezel's
  ~7 pt insets otherwise inflate a 220 pt plate to 234 and collapse every row
  gap.
- `NSButtonCell.attributedStringValue` is the cell's STATE, not its title —
  measuring it handed the together bar 4 pt and drew "T". Measure
  `attributedTitle`.
- `isBordered` must stay `true` on the plates or `drawFocusRingMask` is
  silently discarded (openradar 29465363).
- Explicit `CATransition` ignores `setDisableActions` and is filed under the
  literal key `"transition"` whatever key you pass — gate it manually.
- The stage keeps its **settled model values** under every transient so
  `cacheDisplay` snapshots are deterministic — never animate without also
  writing the settled value.
- The snapshot tool MUST run headless (`AIRPLAY_HEADLESS=1`, set before
  AppKit loads) or the lock's 1.44 s settle races the runloop drain and the
  `· kept` readout doesn't land in the captured frame.
- Roadmap ids: `main` is at 062, `ios-staging` reserves 063 — always number
  new entries past both to keep the union merge clean.

---

## 8. SESSION 2 (2026-08-23, `claude/wizard-ui-handoff-a6ca38`) — sheet built + five design passes

### The sheet conversion (§4's plan, executed as written)
- `AlignmentWizardWindowController.swift` → **`AlignmentWizardViewController.swift`** (NSViewController; canvas + room-spill; `fitToContent()` publishes `preferredContentSize`, AppKit animates the attached sheet; `dismissSilently()` only when hosted; `test_isHostedOverride` for headless tests). The ✕/`onUserClose` path is DELETED — Stop/Done/Esc are the exits.
- `PopoverController`: mount presents via `panel.presentAsSheet(sheet)` gated on a visible host (the Mixer create-sheet idiom; headless keeps the reference and drives the view). `tearDownBTWizard(targetLost:)` — open question 3 was built on its recommended default: a target lost under a LIVE sheet bows out in place (`BTAlignmentWizardView.showTargetLost()`, "<name> went away." · Done) instead of vanishing; headless/unhosted tears down as before. Questions 1 (Stop stays immediate) and 2 (menu-bar click fronts + beeps) kept their recommended defaults — no code needed.
- Tests: ✕-path tests deleted; `appSwitchTuckAwayLeavesTheRunAlive`, `escapeReachesTheWizardThroughTheSheetContent`, target-lost bow-out tests added; hook renamed `test_btWizardSheet()`.
- `wizard-snapshot` renders the controller's view; 22 shots now (all four bow-outs, both appearances).

### Five /impeccable passes (Alec-directed, sequential; each verified its §0b ruling landed, then fixed residue only)
1. **clarify · question** — ruling landed. Residue: readout now two voices (question emphasized, rung word subordinate); `closing` word → "closing in"; AX asks the printed question; **"They sound together" → "Both at once"** (parallel replies — JUDGMENT CALL: changes a spec §4 verbatim string §0b didn't rule on; one-constant revert if disliked).
2. **clarify · kept peak-end** — ruling landed, no jargon left. Residue: Mac-run caption "the popover" → "SYNC control"; Keep's VoiceOver announcement leads with the ready line. DEFERRED to Alec: 066's "name which speaker is delayed" (direction flips between run types — needs owner copy).
3. **colorize** — all three rulings landed in code AND pixels (rims measure full-strength; stamps 11.2:1; locked wire neutral). Docs-only fixes (four stale 0.45-alpha sites). FLAG: intro lights measure 2.98/2.45:1 vs the 3:1 non-text floor — inherent to brightness-encodes-certainty; name stamps carry the teaching.
4. **harden · bow-outs** — ruling landed. Fixes: `unreachableCopy` "by hand" → "manually"; **intro gained a corner-row Stop (ESC chip)** — the sheet's missing-✕ left it Esc-only; target-lost spacing conformed. **ROOT-CAUSE FIND: `applyMicroVoice` labels had no `usesSingleLineMode`, so `CLICK n OF ABOUT 15` / `ABOUT 15 CLICKS` / the ESC chip rendered 4 pt wide — invisible in EVERY earlier render including the approved sets.** One-line fix; trap recorded in AGENTS.md bullet 44.
5. **layout** — chassis verified fixed (all 22 sheets 560×413, stage at identical y). Fixes: key chips baseline-aligned (were 4 pt low in every corner row); nameplate overprint defect (name could draw through the click count past ~57 chars) — pinned + truncation + regression test.

### State at close of session 2
- `bash scripts/build.sh` exit 0; the six wizard suites green after every pass; full-suite run + fresh renders + fresh bundle: see the final session summary in the conversation, or re-run yourself.
- Handover builds: `build/Audiouter Wizard v5.app` (`.wizardv5`) predates passes 1–5 — superseded. Current build should be cut as **v6 / `.wizardv6`** (never reuse a launched id).

### Owner visual batch — session 3, 2026-08-24 (live-directed, implemented as ruled)
Six owner instructions off a live run of `.wizardv7`, all built and rendered:
1. **The mono-caps nameplate is retired here.** `ALIGN · <NAME>` → a plain
   sheet title `Align <device name>` (`bodyEmphasized`/`label`), with the click
   count restyled as a quiet sentence-case caption on its right
   (`caption`/`inkSecondary`). Wizard-ONLY — roadmap 059 owns the rest of the
   app; the stage's in-plate name stamps deliberately keep the micro-caps voice.
2. **Wire centred in the stage plate** — `wireYFraction` 0.62 → 0.5.
3. **Intro breathing room** — the empty readout row now collapses to zero
   height on the four caption-less screens, the intro's band is top-pinned
   instead of centred, and a full 28 pt band break sits between the reference
   line and Start. The plate's own size never changed; it was missing air.
4. **Primary CTA = bright gold + black ink, one value in both appearances** —
   `Tokens.Color.gold` resolved under `.darkAqua` and pinned, plus a new
   `Tokens.Color.inkOnGold`. `goldCTA` (deepened for white ink) keeps the Setup
   finale and nothing here. Measured 11.4:1.
5. **Plate titles centred in the PLATE** — the keycap chip no longer displaces
   them (`titleRect` reserves symmetrically). Every big plate on every screen,
   the two answer plates included.

Renders in `dev/notes/wizard-v2-handoff/after-sheet/` are current for this
batch. Queue items 4 and 6 below predate it and should be re-judged against the
new renders.

### Owner decision queue (flagged by the passes, deliberately not acted on)
1. "Both at once" wording (pass 1 — revertible in one constant).
2. Kept screen naming the delayed side (066; needs owner copy — direction flips).
3. Intro lights under the 3:1 non-text floor (would invert the certainty ladder to fix; stamps mitigate).
4. Bow-outs carry ~95 pt of empty ground (fixed chassis working as ruled; most visible on target-lost in dark).
5. `11-intro-no-option`: stage lights a magenta reference with no name while copy says no second speaker exists.
6. Stop shifts vertically between question → proposal screens (band centring; consistent with ruling).
7. Target-lost AX label states situation only (visible string is locked copy; Done is the only step).

### Still owed to close the worktree (updates §6)
- Alec review of the queue above → commit (Guard 7 is Alec's step) → local merge + GitHub PR.
- Live hardware pass, now INCLUDING sheet-specific checks: sheet z-order above the beak, Esc reaching the view (not cancelling the sheet), tuck-away/restore with a run live, pinned + unpinned launch, one real Stop mid-run.
- Figma mirror of the final screens (house rule; not started).
- Purge test bundles `.wizardv1`–`.wizardv5` after v6 verifies (`scripts/purge-dev-installs.sh`, dry-run first).
- NOTE for the eventual merge: `main` has since renamed the app (AudiouterCore → Audiout, license-key merge `2b523c4f`) — this branch still uses Audiouter paths; expect rename-scale conflicts at merge time.
