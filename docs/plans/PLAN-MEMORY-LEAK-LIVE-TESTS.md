# Plan — Memory-leak fixes: live test checklist (Alec-only)

Status: **NOT YET RUN.** Branch `claude/memory-leak-investigation-396ac3` (main merged in,
2-parent merge `893938d`). All code committed + hermetic suites green (AudiouterCore full
parallel + AirPlayEngine 156/156). These are the LIVE gates that only Alec can run — Claude
never plays or captures audio. Nothing merges to `main` until these pass.

## Why these exist
The fixes target **coreaudiod-side memory growth during per-app redirect churn** (worst during a
broken double-audio redirect). Hermetic tests prove the logic; only real audio proves the leak
is gone and nothing regressed. See `PLAN-MEMORY-LEAK-AUDIT.md` for the findings (L1–L5, storm
C-A/C-B, T16/T17) and `PLAN-FIREFOX-ROUTING-LEAK.md` for the routing fix.

## Prerequisites (once per session)
1. **Quit every other Audiouter** (menu-bar icon → Quit; check `/Applications`, other worktrees).
   Native audio uses exclusive PTP ports 319/320 — only ONE copy can live-test at a time.
2. **Toolchain** (only if a build fails with an `xcrun`/SDK error): `xcode-select` must point at
   full Xcode, not CommandLineTools:
   ```
   sudo xcode-select -s /Applications/Xcode-beta.app/Contents/Developer
   ```
3. **Build + launch this worktree's app** (the `CPATH=…` workaround is NO LONGER needed — main's
   `5c55386` fixed the include paths):
   ```
   cd "/Users/alechenderson/Projects/AirPlay Controller/.claude/worktrees/memory-leak-investigation-396ac3" && scripts/make-app.sh ./build && open ./build/Audiouter.app
   ```
   Launch via `open` (not from a shell/Xcode) so it gets real TCC permissions. It's a **menu-bar
   app** — no Dock icon, no window after setup; find it top-right near the clock.
4. First run of a fresh build may need permissions re-granted (System Settings → Privacy). If a
   toggle looks "on" but doesn't work, that's cdhash-pinning — remove (−) and re-grant, don't just
   toggle.

## Test 1 — Wave 1 smoke (bounded-object leak fixes: L1/L2/L4/L5)
1. Redirect **Music** (native Apple Music) to an AirPlay speaker, then un-redirect. Repeat **×3**.
2. Route an app to **"Play on this Mac"**, then **quit that app** while it plays.
3. Open the popover; watch the T5 diagnostic handle counters (taps/aggregates/IOProcs).

**PASS:** no audio glitch beyond the redirect itself; counters return to **zero** after each
cycle (no upward creep); quitting a routed app leaves nothing stuck.

## Test 2 — Wave 2 device-flip (storm damping: C-A rebuild loop)
1. Route **2 apps** to AirPlay devices, both playing.
2. Flip the Mac's output device mid-playback (toggle Bluetooth, or change Sound output).

**PASS:** no audio gap > **1 s** on either app; `PAC.handleDeviceChange FIRED` in Console fires a
**bounded** number of times (not endlessly); coreaudiod CPU settles < **10 s**.

## Test 3 — Wave 3 (Firefox/Chrome per-app routing leak)
**Run the silent diagnostic FIRST, while the browser is actively playing audio:**
```
cd "/Users/alechenderson/Projects/AirPlay Controller/.claude/worktrees/memory-leak-investigation-396ac3/AudiouterCore" && swift run process-audio-dump
```
It dumps live audio process objects (pid/parent) — confirms the browser's audio child is a
ppid-descendant of its main process on this machine (the assumption the fix rests on).

Then: redirect **Firefox or Chrome** (NOT Safari) playing audio to a speaker.

**PASS:** the speaker gets the audio AND it is **not** also leaking out the Mac's own speakers.

- **Safari is a known, accepted scope limit** — its audio runs in launchd-owned XPC processes the
  ppid-walk can't reach; it never worked before either (not a regression). Test Firefox/Chrome.
- **Expected, not a bug:** one brief extra glitch ~300 ms after switching outputs while a "Play on
  this Mac" app plays (self-limiting). And on a Mac with NO built-in speaker + AirPlay default,
  "Play on this Mac" comes out the AirPlay device (pre-existing, needs a product decision).

## Test 4 — Measurement kit (T19: prove the leak is actually gone)
Leave this running in its own Terminal the whole session (logs to Desktop):
```
while true; do
  echo "$(date '+%H:%M:%S') $(ps axo rss=,comm= | grep -E '(coreaudiod|Audiouter)' | grep -v grep | tr '\n' ' | ')"
  sleep 5
done | tee ~/Desktop/audio-mem-log.txt
```
Run with the **popover closed** (reads cleanest):
- **Phase A (~10 min):** redirect Music → speaker, 30 s, un-redirect, 30 s — **×10**. Note
  start/end times. PASS = memory flat, no permanent per-cycle step-up.
- **Phase B (5 min):** redirect Firefox → speaker, hands off 5 min. PASS = flat (the old
  worst-offender: retry-storm churn).
- **Phase C (2 min):** remove redirect, 30 s, **quit Audiouter**, watch 2 more min. PASS = no big
  coreaudiod drop on quit (a drop = process-held leaked objects only freed at quit).

Deliverable: `~/Desktop/audio-mem-log.txt` + phase times — hand back for a second read.

## Post-merge extra (recommended, low cost)
Since `main` merged in with overlapping audio changes (dropout-fix/telemetry), during Test 2 also
confirm: no new dropouts on a single-AirPlay connect, and no pitch shift (main's
`reconciledFormat` + our rate/device listeners now coexist — Test 3/4 exercise both triggers).

## After all pass
Report results; only then discuss merging this branch to `main` (Alec's explicit go-ahead
required — passing tests ≠ ready). Remaining non-live work: Wave 4 (T18 combined verify + docs,
deferred B1 `airplay_events.c` teardown nits).
