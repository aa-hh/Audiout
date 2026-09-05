# One-frame surface — handoff (2026-08-22)

Written for whoever picks this up next, with no access to the session that did the work.

## Current state — nothing is broken, nothing is uncommitted

As of this note, the working tree in this worktree
(`.claude/worktrees/one-frame-surface`, branch `claude/one-frame-surface`) is
**clean**. Everything described below is already committed and pushed:

- Commit `eee1c27f` on `claude/one-frame-surface`, pushed to
  `origin/claude/one-frame-surface`.
- PR open: **https://github.com/aa-hh/Audiout/pull/29** (`claude/one-frame-surface` → `main`), not merged.
- Full test suite green at commit time: 2539 tests / 149 suites.
- `main` is untouched.

If you were told "the agent failed" — nothing failed on the implementation
side. The only open item is a **live, by-eye check on real hardware**, which
no agent can do from a terminal. That's the actual "what remains."

## What this branch does

Implements `dev/notes/one-frame-surface-brief.md` (the design brief, confirmed
by the owner, committed at `4c0dd0ae`). Summary: the one-surface window
(`AppSurfaceController`) used to resize its width on every screen switch
(Mixer/Groups/Settings), which visibly slid the toolbar tab strip out from
under the cursor. Owner ruled that "reads as the surface twitching." Fix: one
fixed 623-wide frame for the whole open session; height is measured once per
open from the Mixer's fit (floor 600, capped to the screen) and never changes
again until the window closes.

Key pieces (all in the merged commit):
- `AppSurfaceController.minimumContentSize` / `sessionContentSize` /
  `measureSessionContentSize()` / `applySessionFrame()` — the new frame
  policy. No animation, no re-centring, ever, after open.
- `AudioutSharedUI/SurfaceLayout.swift` — shared width/sidebar constants.
- `AudioutSharedUI/SidebarWarmSurfaceView.swift` — moved out of
  `SidebarViewController.swift` so both Groups and the new Settings sidebar
  can use it.
- Settings screen rewritten: `NSTabViewController` → `NSSplitViewController`
  (`SettingsRootViewController` + new `SettingsSidebarViewController`), a
  Groups-style source-list sidebar (General/Appearance/Audio) replacing the
  old in-content tab strip.
- `GroupsPaneLayout.contentMaxWidth` now derived from `SurfaceLayout` instead
  of a hand-picked literal.
- `Telemetry.Category.surface` — logs once per open if Mixer content is
  taller than the fixed frame (never asserts, never clips silently — that's
  intentionally deferred to roadmap 039).

Full list of touched files is in the commit / PR description.

## How this was built (context for judging the diff)

Run through `/scope-and-run` (Fable scopes → Opus executes → Fable reviews).
Three execution tracks, run as isolated git worktrees off the same commit,
then folded back by patch (no real conflicts):
- **Track C** (sonnet) — shared constants (`SurfaceLayout`,
  `SidebarWarmSurfaceView`).
- **Track A** (opus) — the frame policy in `AppSurfaceController` + tests.
- **Track B** (opus) — the Settings sidebar rewrite.

One retry: a Swift `#expect` compile error (string concatenation isn't legal
in that argument position) surfaced only after the tracks were merged; fixed
in place. A Fable review pass afterward found no code defects, only two
stale doc comments (also fixed). Final full-suite run — 2539/149 green — was
after all of that.

The three throwaway track worktrees (`one-frame-track-a`, `one-frame-track-b`)
are marked `.prunable` — `scripts/housekeeping.sh` will remove them on the
next build. Their branches (`claude/one-frame-track-a/b`) are pushed but
inert; safe to delete on GitHub whenever.

## What remains — the actual open work

1. **Live check on real hardware.** A build with its own bundle id
   (`Audiout OneFrame v1`, `com.audiout.Audiout.oneframev1`) was
   launched during the session that did this work — it may or may not still
   be running depending on whether the machine has restarted since. If not,
   rebuild:
   ```bash
   cd ~/"Projects/AirPlay Controller/.claude/worktrees/one-frame-surface"
   APP_NAME="Audiout OneFrame v2" BUNDLE_ID="com.audiout.Audiout.oneframev2" bash scripts/make-app.sh
   open "build/Audiout OneFrame v2.app"
   ```
   (Bump the suffix — every build needs its own bundle id, see root
   `CLAUDE.md`.) Then check, by eye:
   - Switch Mixer → Groups → Settings → Mixer, both pinned and unpinned. The
     tab strip, Pin button and Quit button must not move a single point; the
     window frame must not change size or position.
   - On the Mixer: collapse a card (e.g. Output Devices) and open a sync
     drawer. Frame must stay unchanged — rows should move inside it, not the
     window.
   - Settings: the new sidebar should visually read like the Groups sidebar
     (same header treatment, same row height/icon spacing, same warm wash
     background).

2. **Merge decision.** PR #29 is open and green but not merged — that's
   the owner's call per this repo's "no merge without explicit go-ahead" rule.
   Merge only after the live check above passes.

3. **Nothing else is known to be broken or incomplete.** The brief's two
   "assumed defaults" (height floor = Mixer fit at 600; Groups drops its
   drag memory) were both confirmed correct during implementation — the
   floor test (`theSevenDeviceEditorFitsTheMinimumFrame`) passed at 600
   without needing to be raised, and the Groups sidebar test
   (`noGroupsPaneAsksForMoreThanTheFrameWidth`) also passed, so the sidebar
   stayed at its existing 210pt (a "200pt" note in the old code turned out to
   be a stale comment, not the real constraint — see the PR description for
   detail).

## If something on the branch DOES look broken

Re-run verification from scratch before assuming code regressed — it may be
environment drift (stale `.build` cache, disk pressure, a hung remote test
mule; see the `remote-test-mule`/`build-stalls` memories in this project):

```bash
cd ~/"Projects/AirPlay Controller/.claude/worktrees/one-frame-surface"
bash scripts/build.sh
AUDIOUT_TEST_NO_CACHE=1 bash scripts/run-tests.sh
```

If the full suite doesn't reproduce 2539/149 green, that's the actual
regression to chase — not something this note anticipated.
