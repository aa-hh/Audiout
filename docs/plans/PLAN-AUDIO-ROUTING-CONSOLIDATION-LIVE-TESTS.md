# Plan — Audio-routing consolidation: live test checklist (Alec-only)

Status: **NOT YET RUN.** Branch `claude/audio-routing-consolidation-92be71`
(worktree `.claude/worktrees/audio-routing-consolidation-92be71`), tasks T0–T9 of the
12-task consolidation plan (roadmap item 007). All code committed, hermetic suites green.
These are the LIVE gates that only Alec can run — Claude never plays or captures audio.
Nothing merges to `main` until these pass. See `docs/notes/architecture-review-audio-routing-2026-07-26.md`
for the four defects (A–D) this branch fixes and `git log --oneline main..HEAD` for the
full commit list.

## Why this branch owes MORE than its own new tests

This branch was deliberately started **without waiting** for the still-owed live
verification of earlier, already-landed work — see `PLAN-LIVE-TEST-HANDOFF-2026-07-25.md`
(the 25-minute per-app state-machine mystery, now resolved by T-DIAG below) and
`PLAN-MEMORY-LEAK-LIVE-TESTS.md` (Wave 4 combined-verify still pending). That was a
conscious call made upstream to keep momentum, not an oversight — but it means **this
session must re-verify that older, still-unverified work too**, not just the ten commits
listed below. Test 0 covers that; do it first, before anything T1–T9-specific, since a
regression there could otherwise be misattributed to this branch's new changes.

## Prerequisites (once per session)

1. **Check for a stale build in another worktree first** — PTP native audio uses
   exclusive ports 319/320; only ONE `Audiout.app` can live-test at a time.
   ```
   find .claude/worktrees -name Audiout.app
   ```
   If another one is running (menu-bar icon near the clock), quit it before continuing.
   Also check `/Applications` for an installed copy and quit it too.
2. **Toolchain** (only if a build fails with an `xcrun`/SDK error): confirm
   `xcode-select -p` points at full Xcode, not CommandLineTools. On this Mac's beta OS
   that's `/Applications/Xcode-beta.app/Contents/Developer` — that's correct, not a bug.
3. **Build + launch this worktree's app:**
   ```
   cd "/Users/alechenderson/Projects/AirPlay Controller/.claude/worktrees/audio-routing-consolidation-92be71" && scripts/make-app.sh ./build && open ./build/Audiout.app
   ```
   Always launch via `open`, **never** a raw shell/Terminal command — a shell-launched
   binary inherits the *terminal's* TCC grants instead of getting its own, which makes
   permission behavior unverifiable (see `AGENTS.md` and prior project history in
   `PLAN-LIVE-TEST-HANDOFF-2026-07-25.md`). It's a menu-bar app — no Dock icon, no window
   after setup; find it top-right near the clock.
4. First run of a fresh build may need permissions re-granted (System Settings →
   Privacy). If a toggle looks "on" but doesn't work, that's cdhash-pinning (see Test 4
   below, which specifically exercises this) — remove (−) and re-grant, don't just toggle.
5. **Telemetry file** (used throughout this checklist):
   `~/Library/Logs/Audiout/telemetry.jsonl` (rotates to `.1` at 5 MB). Always-on, JSONL,
   one object per line with `ts`/`sid`/`cat`/`evt` plus event-specific fields. Shared
   across every Audiout build on this Mac, not per-worktree — filter by time or `sid`
   if another build ran recently. A fresh line to confirm it's writing:
   ```
   tail -5 ~/Library/Logs/Audiout/telemetry.jsonl
   ```

## Test 0 — Re-verify prior, still-unverified work (do this FIRST)

This branch built on top of work whose live verification was still owed. Confirm none of
it regressed before testing anything new:

1. **Per-app pitch/judder + storm-guard** (`196e5b7`, `d415381` — memory-leak-live-testing
   session): redirect Music (or another native app) to an AirPlay speaker, let it play
   30+ seconds. **PASS:** correct pitch/speed, no cutoff, no judder.
2. **Silent-redirect-at-launch recovery** (`22a25f7`): quit Audiout with an app already
   redirected to an AirPlay device, relaunch. **PASS:** the redirect re-establishes itself
   within ~1s of the device being discovered, without you having to re-pick it. Confirm via:
   ```
   grep '"evt":"app_route_rebind_on_discovery"' ~/Library/Logs/Audiout/telemetry.jsonl | tail -5
   ```
3. **Per-app state-machine attribution** (T-DIAG, `7cc0f18`, this branch): this is the fix
   for the 25-minute "phantom idle" mystery in `PLAN-LIVE-TEST-HANDOFF-2026-07-25.md` — it
   was a telemetry mislabeling bug (two coordinator instances sharing one log stream), not
   a real capture failure, but it was never independently re-confirmed live. Open the
   popover (arms the metering coordinator) while an app is redirected (arms the routing
   coordinator) and confirm the two are now distinguishable:
   ```
   grep '"cat":"capturePA"' ~/Library/Logs/Audiout/telemetry.jsonl | tail -20
   ```
   **PASS:** every line has a `"coordinator"` field, either `AirPlayController` (routing)
   or `AudioutMeter` (metering) — confirms the fix that resolved the mystery is live and
   working, not just unit-tested.
4. **Firefox/Chrome per-app routing leak** (Wave 3 of the memory-leak audit, still Wave-4
   "combined verify" pending): redirect Firefox or Chrome (NOT Safari — known XPC scope
   limit, not a regression) to a speaker while it plays audio. **PASS:** audio comes out
   the speaker only, not also out the Mac's built-in speakers.

If any of these fail, stop and report — don't proceed to T1–T9 checks assuming the
regression is new when it might be pre-existing.

## Test 1 — Rate/device renegotiation (T1, T2, T5: shared `DefaultOutputDeviceMonitor`)

Covers: the whole-system tap, the per-app tap, and `LocalPlaybackEngine` all now
subscribe to one shared monitor instead of three independent HAL listeners on the same
system object (architecture review defect D). The risk this retires is a rebuild storm —
multiple listeners firing on the same real-world event.

1. **Whole-system tap + per-app tap, same trigger.** Route one app to "Play on this Mac"
   (exercises `LocalPlaybackEngine`) and select at least one AirPlay device for the whole
   system (exercises `captureWS`). Force a rate renegotiation — engage the built-in mic
   (e.g. open QuickTime's audio recorder) or plug/unplug a device that forces 44.1↔48kHz.
   **PASS:** all audio survives the renegotiation (no dropout beyond a brief expected
   blip), and exactly ONE rebuild fires per tap, not a storm:
   ```
   grep -E '"cat":"(captureWS|capturePA)".*"evt":"(rate_changed_rebuild_triggered|rate_rebuild)"' ~/Library/Logs/Audiout/telemetry.jsonl | tail -20
   ```
   A single real change should produce one `rate_changed_rebuild_triggered` (whole-system)
   and/or one `rate_rebuild` (per-app) per tap that was actually running — not a repeated
   burst of the same event.
2. **Bluetooth/USB output during local playback** (T5, `LocalPlaybackEngine`): with an app
   routed to "Play on this Mac" and playing, plug/unplug a Bluetooth or USB output device.
   **PASS:** audio follows the new default output, and exactly one repoint is logged:
   ```
   grep '"cat":"localPlayback".*"evt":"output_device_pinned"' ~/Library/Logs/Audiout/telemetry.jsonl | tail -10
   ```
3. **No-op check** (confirms the compare-before-rebuild guard, not just the rebuild path):
   trigger a duplicate/no-change notification if you can (e.g. toggle the same device
   selection off then immediately back on) and confirm a `rate_notification_no_op` or
   `rate_notification_skipped` line appears instead of a real rebuild:
   ```
   grep -E '"evt":"(rate_notification_no_op|rate_notification_skipped)"' ~/Library/Logs/Audiout/telemetry.jsonl | tail -10
   ```

## Test 2 — Per-app clock/format correctness (T3: cached clock-offset + format guard)

No new telemetry — this is a pure behavioral check (the fix ports the whole-system tap's
clock-offset caching and a NaN/zero-rate guard into the per-app path).

1. Redirect an app (e.g. Music) to an AirPlay speaker. Let it play at least a minute.
   **PASS:** correct pitch/speed throughout, no judder, no drift.
2. Put the Mac to sleep with the redirect still active, wake it, and let it keep playing
   (or re-trigger playback if the app paused on sleep). **PASS:** audio resumes at correct
   pitch/speed after wake — no lingering clock drift from before the sleep.

## Test 3 — Scope transitions (T6, T7: engine binding + `bindOutput` arbitration)

Covers: moving a device between "Selected Devices" (whole-system, stream 0) and a
per-app redirect target (stream ≥ 1) now asks the engine which stream it's REALLY on and
moves it if wrong, instead of silently no-op'ing and leaving audio written to a stream
the device never joined (architecture review defect B).

1. Pick a real AirPlay device. Add it to Selected Devices (whole-system). Confirm audio.
2. Redirect a specific app to that SAME device (moves it from stream 0 to a per-app
   stream). **PASS:** audio for the redirected app comes out the device; whole-system
   audio for other apps does not leak to it.
3. Remove the per-app redirect (moves it back to stream 0 / whole-system). **PASS:** the
   device goes back to carrying the whole-system mix, audibly.
4. Repeat steps 2–3 once more (twice total each direction, per the task's requirement).
5. Confirm each transition actually rebound the stream rather than silently no-op'ing:
   ```
   grep '"evt":"engine_scope_rebind"' ~/Library/Logs/Audiout/telemetry.jsonl | tail -10
   ```
   **PASS:** one `engine_scope_rebind` line (with `"from"` != `"to"`) per real scope
   change above — a same-stream request (no scope change) should NOT produce one.
6. **Basic engine-bind regression** (T6): while doing the above, also do a plain
   connect/disconnect of an unrelated AirPlay device with no scope games involved.
   **PASS:** normal connect time and audio, no regression:
   ```
   grep -E '"evt":"(engine_bind|engine_rebind)"' ~/Library/Logs/Audiout/telemetry.jsonl | tail -10
   ```

**Known, accepted residual risks (not fixed by T7, nothing to fail here on)** — flag if
you notice anything related, but these can't be pass/fail tested directly:
- Scope exclusivity (a device can't be in two scopes at once) is enforced only by the
  GroupController/UI layer, not the engine itself.
- Cross-FIFO ordering between the whole-system converge path and the per-app bind path
  during an IN-FLIGHT transition (not before/after one) is unarbitrated.

## Test 4 — Permission probe re-runs on rebuild (T8: code-identity gating)

Covers: the functional TCC probe used to trust a bare `.granted` read, which could be a
stale, cdhash-pinned grant from a previous build of the binary. It now re-runs the
audible tone probe whenever the running binary's code identity (cdhash) differs from the
one recorded at the last PROVEN grant.

1. Get the app running with audio-capture permission already granted (native backend,
   Selected Devices or a per-app redirect actually working).
2. **Rebuild and re-sign** the app without changing the granted permission in System
   Settings:
   ```
   scripts/make-app.sh ./build
   ```
   (ad-hoc signing produces a new cdhash on every build, even with no source changes).
3. Quit the old instance, `open ./build/Audiout.app` the freshly rebuilt one.
4. **PASS:** the probe actually RE-RUNS (you should hear/see the functional tone-probe
   check happen again, not a silent fast `.granted` pass-through) and correctly reports
   the true state:
   ```
   grep '"evt":"probe_verdict"' ~/Library/Logs/Audiout/telemetry.jsonl | tail -10
   ```
   Confirm the `"method"` field is `self_tap_tone` (the real functional probe), not
   `tcc_preflight` (the fast/skipped path), for this rebuild's first probe.
5. If permission was actually still valid, audio capture should still work after the
   probe completes — the fix must not falsely deny a genuinely-still-granted rebuild.

## Test 5 — Full rapid-toggle + mixed-selection checklist (T4: `TapRebuildLifecycle`)

Covers: the shared C6-coalescer and re-anchor-compare extracted from both taps' rebuild
paths (architecture review defect A, partial consolidation — the claim/teardown/commit
choreography itself deliberately stays two separate bodies, cross-linked by name only).

1. **Rapid toggle, whole-system:** with an AirPlay device selected and playing, rapidly
   toggle it off and back on in Selected Devices — at least 5 times in quick succession
   (faster than the device can fully connect/disconnect between toggles).
   **PASS:** no crash, no stuck "connecting" state, audio recovers to a stable state
   after the toggling stops (doesn't have to sound clean DURING the storm).
2. **Rapid toggle, per-app:** same but with a per-app redirect target instead — toggle an
   app's redirect between "no redirect" and an AirPlay device rapidly, 5+ times.
   **PASS:** same — no crash, no stuck state, recovers.
3. **Mac + AirPlay mixed-selection connect** (the specific scenario called out in the
   task): with an AirPlay device already selected and playing, ALSO add the Mac's
   built-in output to Selected Devices (a combined local + AirPlay selection).
   **PASS:** no dropout on either output when the combined selection is made.
4. **Confirm no rebuild storm** for all three sub-tests above:
   ```
   grep -E '"cat":"(captureWS|capturePA)".*"evt":"(rebuild_reanchored|device_change_coalesced|device_change_fired)"' ~/Library/Logs/Audiout/telemetry.jsonl | tail -40
   ```
   **PASS:** the coalescer is visibly doing its job — `device_change_fired` events during
   a rapid-toggle burst should mostly resolve to a much smaller number of
   `device_change_coalesced`/`rebuild_reanchored` events, not a 1:1 rebuild-per-toggle
   storm.

**Known, flagged-not-tested gap:** per-app taps have no device-identity-compare
equivalent to the whole-system tap's dropout-prevention check. Nothing to specifically
pass/fail here — just note if a per-app redirect seems to drop audio on a device-identity
change (as opposed to a rate change) during any of the above, since that's the scenario
this gap would show up in.

## Test 6 — Dead code sanity (T9)

`AppRelauncher.swift` was deleted as unused dead code (`a4e2d07`). No live test needed —
confirm the app still launches and runs normally (covered implicitly by every test above
having gotten this far).

## After all pass

Report results per test above (pass/fail, plus anything flagged as "known risk, watch
for"). Only then discuss merging this branch to `main` — Alec's explicit go-ahead
required, passing tests is not itself sufficient.
