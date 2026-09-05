# Handoff — device detail pane redesign, in progress (2026-08-22)

Written for someone with no access to the conversation that produced this.
Everything described below is **uncommitted** in this worktree:
`~/Projects/AirPlay Controller/.claude/worktrees/device-detail-view-redesign-bf9547`
(branch `claude/device-detail-view-redesign-bf9547`). Nothing has been
committed at any point in this effort — that is deliberate; commit is the owner's
call, not the pipeline's.

## The big picture

The owner asked for the Groups screen's "device detail" pane (and its two sibling
pages — Main Audio, and the group editor) to be redesigned. That redesign
went through several rounds, each reviewed and approved, then the owner gave four
more pieces of feedback on the result. **All four are now done: the fourth
(EQ scope into the Advanced fold) finished 2026-08-22 — AGENTS.md trimmed
back under its cap (6239/6264), 264 tests in 10 suites green, build green,
all four snapshot renders eyeballed correct, full diff Fable-reviewed.
Remaining: the owner's own review + commit + live check.**

Read these two files for full context and rationale — they are the actual
specs this work followed:
- `dev/notes/device-detail-ia-brief-2026-08-22.md` — the original information-
  architecture brief (why the pane has the sections it has).
- `dev/notes/device-detail-framework-2026-08-22.md` — the "slot model" the
  redesign follows (Identity / Controls / Groups / About) plus the colour
  strategy (one raised "card" for the page's one instrument, everything else
  bare on the panel with hairline dividers).
- `dev/notes/eq-rendering-research-2026-08-22.md` — research behind the EQ
  scope's new home (this is what the in-progress work implements).
- `dev/notes/eq-advanced-toggle-evaluation-2026-08-22.md` — research behind
  the "Advanced" row redesign (already done, see below).

## Status of the owner's four feedback points

The owner's original four points, verbatim from the conversation:
1. "Not enough padding at the top of the equalizer section." **DONE, reviewed, approved.**
2. "Room for improvement in how we render this feature... look up best practices." **DONE 2026-08-22, verified and reviewed — see below.**
3. "Inside the section the buttons Loudness and Reset are semantically at the same level but not aligned vertically." **DONE, reviewed, approved.** (Investigation found they were already correctly aligned — see caveat below — but the owner separately asked for Reset to move to the "Equalizer" title line, which is now done.)
4. "The Advanced button disappears — make clear there's a whole other section hidden. Maybe a toggle." **DONE, reviewed, approved.**

### Points 1, 3, 4 — confirmed complete and approved

These landed through a `/scope-and-run`-style pipeline (scope → execute →
verify → review, with fix-and-re-review cycles where problems were found).
Final state, all APPROVED by a Fable review agent, all verification commands
run and pasted in the session:

- **Point 1 (padding):** `GroupsPaneLayout.cardContentInset = 14` added; the
  Equalizer card's editor content is now inset 14pt on all sides (was 6pt,
  the same value used for plain text-row lists — too tight for a solid
  instrument panel). Applies to both `DeviceDetailViewController` and
  `MainOutDetailViewController`.

- **Point 3 (Loudness/Reset + Reset relocation):** Investigation with real
  measured frames (headless, and cross-checked against rendered PNG pixels)
  found Loudness and Reset were ALREADY on one centre line — the "misaligned"
  impression was actually the "Loudness" title text starting 22pt right of
  the Bass/Treble/Balance caption column (because of the checkbox glyph) and
  being drawn in full-strength text vs the other rows' secondary colour. Once
  that was reported, the owner separately asked for Reset to move onto the
  "Equalizer" title line (a corollary of point 4's redesign — Reset is a
  card-level action, not a tone control). That is what actually shipped:
  - `EQEditorView.resetButton` removed entirely; the editor now exposes
    `public func resetToFlat()`.
  - Both hosts (`DeviceDetailViewController`, `MainOutDetailViewController`)
    now own an `eqResetButton` on the same line as their "Equalizer" sibling
    title label, trailing-aligned to the card's content edge, `.rounded`
    `.small` bezel, enabled iff `!eqEditor.currentEQ.isFlat`.
  - `loudnessRow()` in the editor is now just the checkbox, alone.

- **Point 4 (Advanced row):** The disclosure triangle now sits inside a real
  section row: a 1pt hairline divider above it (`HairlineView`, NOT `NSBox`
  — `test_hasBoxDivider` would fail), the word "Advanced" is itself a
  clickable `NSButton` (same idiom as `AudioutSettingsUI/AudioSettingsViewController`'s
  existing "Advanced" row), a `tertiaryLabel` hint "10 bands" beside it, and
  a trailing readout ("N set", blank when flat) showing how many of the ten
  hidden bands are non-zero — so a user can tell hidden shaping is active
  without opening the fold. **The expanded/collapsed state now persists
  across app launches** via a new `AppSettings.eqAdvancedExpanded` Bool
  (`UserDefaults` key `"eq.advancedExpanded"`), applied instantly (no
  animation) at `EQEditorView` init. A shaped band never force-opens the
  fold — the readout is the signal, not an auto-expand.
  - **Important side-effect of this work:** `EQEditorView` gained a
    `settings: AppSettings` initializer parameter (default `AppSettings()` =
    `.standard`). This had to be threaded all the way up: both host view
    controllers gained a `settings:` init parameter, and so did
    `MixerWindowController` (which constructs both hosts). Every test that
    constructs any of these three types was updated to pass isolated
    `UserDefaults` (via each suite's `TestIsolation`) so tests never read or
    write the real `.standard` defaults. This was caught and fixed in review
    — the first pass missed it and a reviewer proved it would make renders
    and tests machine-state-dependent.

All verification for points 1/3/4, last confirmed green:
```
bash scripts/run-tests.sh --filter EQEditorViewTests --filter DeviceDetailViewTests \
  --filter MixerWindowControllerTests --filter GroupsHeaderParityTests \
  --filter GroupsWindowTextColorLockTests --filter GroupRenameFieldTests \
  --filter MembershipRailTests
→ Test run with 206 tests in 7 suites passed
bash scripts/build.sh → Build complete!
```
(Those counts predate point 2's changes below — point 2's own executor
re-ran a subset and got 176 across a different filter set, which is
consistent, see below.)

### Point 2 — DONE (the account below was written mid-flight; the trim and every verification step it lists have since been completed)

**Research (already done, approved):** `dev/notes/eq-rendering-research-2026-08-22.md`
surveyed how Apple Music, Sonos, Bose, AirPods, Logic Pro, GarageBand, Roon,
Spotify, SoundSource, Boom 3D and eqMac render an EQ. Finding: consumer tone
pages (Sonos-like bass/treble/balance) never show a curve at all; every
product that DOES draw a curve bonds it to its controls on a shared x-axis
(the curve IS the control, or joins slider knobs). Our old layout put a
non-interactive scope over three sliders whose axis meant something
different — which is exactly why it read as "a black bar with a line
through it."

**Chosen direction (the owner approved "B, with A's dressing"):** move the scope
out of the resting card entirely. At rest the Equalizer card is just
Bass / Treble / Balance / Loudness / hairline / Advanced row (the Sonos
shape). Opening "Advanced" reveals the scope directly above the ten band
faders, full editor width, with each fader column's centre x pinned to
the scope's own grid line for that frequency band (the bands are
octave-spaced, so this lines up cleanly on the log frequency axis). The
scope itself gets "dressed" as an instrument: a dB ruler ("+12 / 0 / −12")
in a 28pt gutter on its left edge, a dotted 0 dB reference line, slightly
brighter grid (alpha 0.10 → 0.14), height 64pt → 80pt to fit the ruler. The
old centred caption row ("20 Hz / +12 dB · −12 dB / 20 kHz") is deleted —
the band labels under the faders now serve as the Hz axis, and the new
ruler serves as the dB axis.

**A full paint-by-numbers work order for this exists and was followed** —
see the Opus executor's session for the literal 16-step spec if you need
it verbatim; the summary of what it specifies and what actually landed is
below. (The work order document itself was not saved to a file — it only
exists as the prompt given to the executor agent, which is gone. If exact
wording is needed, this summary plus reading the diff should be sufficient;
regenerating an equivalent order from `dev/notes/eq-rendering-research-2026-08-22.md`
is straightforward if truly needed.)

**What actually happened:** an Opus executor worked through this 16-step
order serially and got through **steps 1–15 completely**, then was cut off
mid-step-16 (documentation) by the operator's session usage limit (hard
external cutoff, not a code failure — it had just reported "176 tests =
baseline 170 + 6. Now step 16 — docs." when it was killed). The verification
test run (170 baseline + 6 new = 176, all passing) was the LAST thing it
confirmed before being cut off, so **all code and test changes are
verified working**. Only the documentation step is incomplete, and it is
incomplete in a way that currently VIOLATES a hard constraint (see below) —
so this is not safe to hand off as "just write the docs", it needs a trim.

#### What's confirmed done in the code (steps 1–15 of 16)

Checked directly in the working tree just now, all present:

1. `EQResponseCurveView.swift`: `height` is now `80`; `gridAlpha` is `0.14`;
   `plotLeadingInset = 28`, `plotTrailingInset = 14` constants added;
   `zeroDashPattern = [1, 3]` added.
2. `public static let bandGridX: [CGFloat]` and
   `public static func bandCentreX(index:width:) -> CGFloat` added — the
   shared x-axis math both the scope's own grid and the editor's fader
   columns now use.
3. `drawScope()` shrinks its plot rect by the new leading/trailing insets so
   20 Hz starts at x=28 and 20 kHz ends at x=(width−14).
4. `drawRuler(beside:)` added — draws "+12" / "0" / "−12" in the left
   gutter, right-aligned, `secondaryLabel` colour, `Tokens.Font.caption`.
5. `drawGrid(in:)` now draws the 0 dB line as a **dotted** line (dash
   `[1,3]`) using `Tokens.Color.scopeFlatLine` instead of a solid
   `scopeZeroLine` fill.
6. `Tokens.swift`: the now-orphaned `scopeZeroLine` token was deleted
   cleanly (confirmed zero remaining references anywhere in `Sources` or
   `Tests`).
7. `EQResponseCurveView` type doc comment rewritten to describe its new home
   inside the Advanced fold and its role as the faders' shared x-axis.
8. `EQEditorView.swift`: `configureScope()` and `captionRow()` functions
   are gone entirely (confirmed via grep — no trace). The resting card no
   longer builds or shows the scope or the old caption row.
9. `configureAdvancedTier()`: `advancedContent` changed from a horizontal
   `NSStackView` to a plain `NSView`; the scope (`curve`) is now a subview
   pinned above the ten band faders; each fader column is centred via
   `NSLayoutConstraint` math using `bandGridX[i]`/`plotLeadingInset`/
   `plotTrailingInset` so it lands exactly on `bandCentreX(index:width:)`
   for the fold's actual width; the "Hz" legend sits in the ruler gutter,
   baseline-aligned with the band labels; the clip view's trailing
   constraint changed from `<=` to `==` so the fold spans the full editor
   width now that the scope needs it.
10. New test hooks confirmed present: `test_curveFrame`,
    `test_bandColumnCenterX(_:)`, `test_hzLegendFrame`, `test_bandSliderFrame(_:)`.
11. Host comment updates ("a solid scope panel" → "tone controls and,
    behind Advanced, a scope") — present in both
    `DeviceDetailViewController.swift` and `MainOutDetailViewController.swift`
    (comment-only, confirmed via `git status` showing both as modified).
12. `EQResponseCurveTests.swift`: the two new tests (ruler-text contrast
    floor check, `bandCentreX` math check) — present (file shows as
    modified, executor's report confirmed both written and passing).
13. `EQEditorViewTests.swift`: four new tests for the moved scope (resting
    card has none; opening Advanced reveals it above the faders; fader
    columns centre on the scope's grid lines; the Hz legend sits in the
    ruler gutter) — present.
14. `DeviceDetailViewTests.swift`: one message-string update (a test that
    checks card padding used to say "above the scope"; now says "above the
    editor's first row" since the scope no longer sits there at rest) —
    present.
15. `window-snapshot/main.swift`: a new snapshot state **4b** added,
    confirmed present at line 624 — opens Advanced via
    `test_detail.test_eqEditor.test_fireAdvancedClick()`, captures
    `mixer-4b-device-detail-eq-open-{light,dark}.png`, then closes Advanced
    again afterward (with a comment explaining why: this tool's hosts use
    real `.standard` defaults, so a left-open fold would leak into the next
    run's state-4 capture).

Last test run the executor completed before being cut off:
**"170 baseline + 6 new = 176 tests passing"** across
`EQEditorViewTests`, `DeviceDetailViewTests`, `MixerWindowControllerTests`,
`GroupsHeaderParityTests`, `GroupsWindowTextColorLockTests`,
`EQResponseCurveTests`. This was NOT re-verified by me after the cutoff —
the next step should re-run this exact filter set fresh before trusting it,
since step 16 hasn't touched source files but it's good hygiene.

#### What's NOT done: step 16 (docs) — and the actual blocker

Step 16 asked for two doc updates in
`AudioutCore/Sources/AudioutSharedUI/AGENTS.md`:
- The `EQEditorView` map-table row — **done**, confirmed present at line 67:
  > Tone editor hosted by the Groups detail panes: Bass/Treble/Balance/Loudness
  > + hairline + Advanced section row; the fold holds the scope above ten
  > faders centred on its grid lines; `apply(eq:bypassReason:)` in,
  > `EQEditorViewDelegate` out; Reset is the host's.
- The `EQResponseCurveView` map-table row — **done**, confirmed present at
  line 68:
  > The scope, inside the Advanced fold: approved custom-drawn instrument,
  > authored dark in both appearances, dB ruler in a 28 pt leading gutter +
  > dotted zero line, pure `Plan`, `bandCentreX` is the shared x-axis the
  > faders sit on, never `CALayer`.

**Both rows are written and present in the file.** The problem: this file
has a documented, previously-enforced hard cap of **6264 words**
(`wc -w`), and it currently measures:

```
$ wc -w AudioutCore/Sources/AudioutSharedUI/AGENTS.md
    6286 AudioutCore/Sources/AudioutSharedUI/AGENTS.md
```

**22 words over the cap.** This cap was hit and enforced exactly this way
earlier in the SAME redesign effort (a prior fix cycle trimmed this exact
file from 6294 → 6264 to satisfy it, and a reviewer explicitly checked the
count as a pass/fail gate). It is reasonable to assume it will be checked
again, and the repo may have a pre-commit hook (`AGENTS.md` symbol/word
guard, mentioned as "Guard 2" and an "agents-md-symbol-check.py" script
seen in this session) that would reject a commit while this file is over
cap — this was NOT independently re-confirmed post-cutoff, so treat it as
likely rather than certain.

### The one concrete next step

**Trim `AudioutCore/Sources/AudioutSharedUI/AGENTS.md` by at least 22
words**, without:
- deleting either of the two new EQ-related map rows just written,
- removing any named symbol the file's own self-check might verify exists
  (grep the file for backtick-quoted identifiers and confirm they're all
  still real if you're not sure what the guard checks),
- removing the "never regenerate the window-snapshot goldens" rule (this
  has been flagged repeatedly across this whole redesign effort as
  load-bearing and easy to accidentally delete during a trim pass).

The prior trim pass (documented in this same session, for points 3/4) cut
dated historical asides and parenthetical qualifiers rather than any rule
or map-row content — that is almost certainly the right pattern to repeat
here: skim the file for other stale/dated commentary unrelated to this
change and cut there first, before shortening the two rows just added.

### After the trim, resume the normal verification/review sequence

Once the word count is back at or under 6264:

1. Re-run the full verification set fresh (don't trust the pre-cutoff
   numbers blindly):
   ```
   bash scripts/run-tests.sh --filter EQEditorViewTests --filter DeviceDetailViewTests \
     --filter MixerWindowControllerTests --filter GroupsHeaderParityTests \
     --filter GroupsWindowTextColorLockTests --filter EQResponseCurveTests
   bash scripts/build.sh
   wc -w AudioutCore/Sources/AudioutSharedUI/AGENTS.md   # must be ≤ 6264
   ```
2. Render fresh snapshots and actually look at both new PNGs (this was
   planned but never executed — the scratchpad directory
   `.../scratchpad/snaps-eqb/` referenced by the work order does not
   exist, confirmed by `find`):
   ```
   cd AudioutCore && swift run --build-system native window-snapshot <some-scratch-dir>
   ```
   Then visually confirm: `mixer-4-device-detail-{dark,light}.png` shows
   NO scope and NO caption row at rest (card ends at the Advanced row);
   `mixer-4b-device-detail-eq-open-{dark,light}.png` shows the scope with
   the "+12 / 0 / −12" ruler on its left, the ten faders directly under
   their matching grid lines, and "Hz" sitting under the ruler gutter.
3. Get an independent review of the full diff (this whole effort has used
   a scope → execute → verify → review pattern throughout, with an
   Opus/Fable agent reviewing every completed unit before it was considered
   settled — points 1/3/4 above both went through exactly one fix-and-
   re-review cycle each before passing; expect this one might too).
4. `git status --short` should show changes confined to exactly the files
   listed under "confirmed present" above, plus the doc file. Nothing here
   has been committed — that is intentional; leave it for the owner to
   review and commit themselves once satisfied, per how this whole session has
   operated throughout (nobody in this pipeline ever runs `git commit`).

## Files touched by this whole effort so far (points 1–4, all uncommitted)

From `git status --short` at time of writing:

```
 M AudioutCore/Sources/AudioutCore/AppSettings.swift
 M AudioutCore/Sources/AudioutSharedUI/AGENTS.md              ← OVER WORD CAP, see above
 M AudioutCore/Sources/AudioutSharedUI/EQEditorView.swift
 M AudioutCore/Sources/AudioutSharedUI/EQResponseCurveView.swift
 M AudioutCore/Sources/AudioutSharedUI/Tokens.swift
 M AudioutCore/Sources/AudioutWindowUI/AGENTS.md
MM AudioutCore/Sources/AudioutWindowUI/DeviceDetailViewController.swift
 M AudioutCore/Sources/AudioutWindowUI/GroupEditorViewController.swift
 M AudioutCore/Sources/AudioutWindowUI/GroupedSectionView.swift
 M AudioutCore/Sources/AudioutWindowUI/GroupsPaneLayout.swift
 M AudioutCore/Sources/AudioutWindowUI/MainOutDetailViewController.swift
MM AudioutCore/Sources/AudioutWindowUI/MixerWindowController.swift
 M AudioutCore/Sources/window-harness/main.swift
 M AudioutCore/Sources/window-snapshot/main.swift
 M AudioutCore/Tests/AudioutCoreTests/AppSurfaceControllerTests.swift
MM AudioutCore/Tests/AudioutCoreTests/DeviceDetailViewTests.swift
 M AudioutCore/Tests/AudioutCoreTests/EQEditorViewTests.swift
 M AudioutCore/Tests/AudioutCoreTests/EQResponseCurveTests.swift
 M AudioutCore/Tests/AudioutCoreTests/GroupRenameFieldTests.swift
 M AudioutCore/Tests/AudioutCoreTests/GroupsHeaderParityTests.swift
 M AudioutCore/Tests/AudioutCoreTests/GroupsWindowTextColorLockTests.swift
 M AudioutCore/Tests/AudioutCoreTests/MembershipRailTests.swift
 M AudioutCore/Tests/AudioutCoreTests/MembershipWellContrastTests.swift
MM AudioutCore/Tests/AudioutCoreTests/MixerWindowControllerTests.swift
 M ROADMAP.jsonl
```

(`ROADMAP.jsonl` changes predate this whole effort — an earlier, unrelated
roadmap entry addition in this same worktree session — and are not part of
this redesign; leave as-is.)

Two related planning docs also live in `dev/notes/` from earlier in this
same effort, both already read/used above:
`device-detail-ia-brief-2026-08-22.md`,
`device-detail-framework-2026-08-22.md`,
`eq-rendering-research-2026-08-22.md`,
`eq-advanced-toggle-evaluation-2026-08-22.md`.

## Constraints that applied throughout (still apply)

- Nobody in this pipeline commits or pushes. That's the owner's decision to make.
- Never use `UserDefaults(suiteName:)` for test isolation — use each test
  suite's `TestIsolation` helper. This was a real bug caught in review once
  already this session (host constructors defaulting to real `.standard`
  defaults in tests) — be alert for the same mistake recurring.
- `window-snapshot` goldens under `dev/notes/window-snapshots/*.png` must
  NEVER be regenerated or compared against — they are documented as
  unreproducible on the current macOS version. Any fresh renders for this
  work go to a scratch/temp directory, not that folder.
- Stock AppKit only; no new custom `draw()` overrides beyond what's already
  approved (the scope, the icon well, a couple of named exceptions —
  documented in `AudioutCore/Sources/AudioutWindowUI/AGENTS.md` and
  `AudioutCore/Sources/AudioutSharedUI/AGENTS.md`).
- `AGENTS.md` files have hard word caps per-file that get enforced (see
  above) — check `wc -w` before considering any AGENTS.md edit done.
