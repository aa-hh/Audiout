# Handoff: build, live-test and land the 1.2.0 Bluetooth sync fixes (2026-09-26)

Self-contained. Read the repo's `CLAUDE.md` and `AGENTS.md` first, and the
`AGENTS.md` nearest each file you touch. Everything below was checked against
origin at 12:35 UTC on 2026-09-26.

## The ask

Ali wants the seven fixes below built as **Audiout Dev** on the MacBook,
handed to him with step-by-step test instructions, and live-tested on the two
Sonos Moves. After his verdict, the ones that pass get merged to `main`.

Nothing is compiled yet. The build has not run because the MacBook refused a
Remote Control session: every open Claude desktop-app session holds one, and
ten were connected, four of them already archived. If you are running on the
Mac, that no longer matters. If you are in the cloud, ask Ali to close a few
archived desktop sessions first.

## Where the code is

- **Build branch: `claude/project-thread-c0eru9`** on origin. It is
  `origin/main` at `ea56587` plus `--no-ff` merges of the seven branches
  below, in the order listed. All seven merged cleanly with no conflicts
  (checked in a Linux container: textual merge only, **no compile, no
  tests**). The diff against main is 21 files, +1214 / −85.
- The seven source branches are `worktree-agent-*` on origin. None is on
  main, and each is 5 to 7 commits behind it.
- The session that produced them ("Bluetooth sync issues across versions",
  run on the Mac) worked on local branch
  `claude/bluetooth-sync-version-comparison-57ba82`, which was **never
  pushed**. Its notes are in the Mac's Claude memory at
  `~/.claude/projects/-Users-alechenderson-Projects-AirPlay-Controller/memory/trial-mac-bt-sync-session-2026-09-25.md`.
- A cloud review of all this is in the project files as
  `bt-sync-version-comparison/report.md`.

## The seven fixes

All seven come from one customer log: app 1.2.0, session D4C23DD3, two Sonos
Moves.

| # | Branch | Commit | What it changes | Risk |
|---|---|---|---|---|
| 1 | `worktree-agent-a2a761b2a16d4c277` | `ed6f00a` | **Sink re-timing.** After release, `BTSyncedSink` was a plain FIFO, so every second a device pulled short or long left a permanent offset (up to +293 ms in the replayed storm, plus a 45 ppm creep). The render path now compares wall time since release with frames pulled, and once they are `pullRealignThresholdMs` (20 ms) apart, moves the read position behind the trim crossfade. | **High.** Audio path. Proven only by replay in `BTSinkClockStormTests` (held within 16 ms). Never heard on real speakers. |
| 2 | `worktree-agent-a3233199cfc7d4cea` | `4c82ef4` | **Refused trims.** A drawer trim the sink could not seek to (`bt_sink_seek_clamped appliedMs=0.0`) was still saved, so a reselect later anchored at delay 0 (the Move 205 ms early). A negative trim now counts as latency when the BT-only floor is chosen, so a committed one raises the floor and every sink re-anchors. | Medium. Changes when all sinks re-anchor. |
| 3 | `worktree-agent-ae5fc1d4b52d6b034` | `2977e56` | **Mic calibration correlator.** `MicProbeSession` searched the whole capture, so with the BT sweep missing, the loudest earlier sound won (Δ −778 to −3748 ms at confidence 5.9 to 7.9). It now searches from 0.25 s before the sweeps enter the feed, dated from the recorder's first sample (`firstSampleHostNanos`). Such a listen reads `failed`, never `implausible`. A raised gate was rejected: the stray score grows with loudness (5.3 to 44). | Low. ProbeKit and the gate are unchanged. |
| 4 | `worktree-agent-a4507b0b0d7890fc5` | `abc7007` | **Try again listens.** "Couldn't get a clean reading, Try again" went straight to by-ear questions. It now listens again while the per-run mic budget allows. Adds `bt_sync:mic_retried`, plus `value_ms_bucket` on `bt_sync:listening_ended`. | Low. |
| 5 | `worktree-agent-a8e8b0fbcfbeb1d24` | `090064a` | **Reset log.** Logs `bt_alignment_reset` (uid, source drawer\|phone, the deleted latency and trim). The session's "reselect anchors at 0" premise was refused: that was fix 2's bug. | Log only. |
| 6 | `worktree-agent-aa415409a92f0efc2` | `0bd29bf` | **Drawer stepper.** Holding − / + or an arrow key applied and committed on every 60 ms repeat. Ticks now go out as `committed: false`, and the release sends one `committed: true`. | Low. |
| 7 | `worktree-agent-ac04f32835da4ea92` | `52eb525` | **Drift analytics.** New PostHog events `bt_sync:drift_window_ended` and `bt_sync:drift_window_skipped`. `bt_sync:drift_corrected` now fires when the move lands. | Needs the shared doc rows first (see below). |

**Not covered by any branch:** the session's "bug 4", an engine restart
failure (−10851). It found and fixed an ordering defect (a deselected speaker
had its engine restarted on the way out) and reported the full suite green,
but that fix was never pushed. Look for it in the Mac's
`.claude/worktrees/agent-*` worktrees. If you find it, add it to the build
branch the same way; if you don't, say so.

## Steps

1. **Worktree.** `git fetch origin claude/project-thread-c0eru9`, then
   `git worktree add .claude/worktrees/bt-fixes-dev claude/project-thread-c0eru9`.
   Never edit the main checkout. `git config core.hooksPath .githooks` if
   the clone doesn't have it.
2. **Slot.** `bash scripts/livetest.sh acquire --label bt-fixes-dev`. Exit 2
   means someone holds it: report who, and do not build the dev id.
3. **Build.** `APP_NAME="Audiout Dev" BUNDLE_ID="com.audiout.Audiout.dev" bash scripts/make-app.sh`.
   A merge-level compile fix belongs on this branch as its own commit. Two
   likely hotspots: fixes 1 and 2 both edit `BTSyncedSink.swift`, and fixes 2
   and 5 both edit `NativeBackend+Bluetooth.swift`.
4. **Tests.** Run the suites the merge touched:
   `bash scripts/run-tests.sh --filter "BTSyncedSinkTests|BTSinkClockStormTests|MicProbeSessionTests|BTAlignmentWizardSessionTests|NativeBackendBTAlignmentInterceptTests|BTSyncDrawerViewTests|SyncDrawerMountedKeyTests|SyncValueFieldLiveKeyTests|PassiveDriftSamplerTests|DriftCorrectionApplierTests"`.
   Then run the full suite once before any merge. The known flaky test is
   `aSlewLeavesNoStepBiggerThanTheProgrammesOwn`
   (`DriftCorrectionApplierTests`, timing-sensitive). Report it separately,
   and never skip it.
5. **Launch.** Quit any running Audiout Dev, then open
   `build/Audiout Dev.app` from the worktree. Confirm
   `~/Library/Logs/Audiout/telemetry.jsonl` is being written.
6. **Hand to Ali.** Give him the test steps below, and say which bundle id
   you picked and why (CLAUDE.md requires this): the standing dev id, because
   none of this touches permissions.
7. **After his verdict**, release the slot (`bash scripts/livetest.sh done`).
   Then merge what passed to `main`, both as a local `git merge --no-ff`
   (a fast-forward skips the full-suite merge hook) and as a GitHub PR (CLAUDE.md "Critical workflow rules"). Merge in this order:
   3, 4, 5, 6 (low risk, independent), then 2, then 1 last and only if it
   passed the listening test. 7 waits for the shared doc.
8. **Shared analytics rows.** audiout-shared branch
   `claude/analytics-rows-bt-sync` (`e90d3ff`) holds the doc rows for fix 7
   and fix 4's `value_ms_bucket`. CLAUDE.md says an event goes in
   `docs/analytics-events.md` before any code sends it, so merge that
   branch in audiout-shared before fix 7 lands on main. It is docs only, so
   no tag or pin bump is needed.

## Test steps for Ali

The same text is in the project files as
`bt-sync-version-comparison/dev-build-test-steps.md`. Hardware: the two Sonos
Moves, with AirPods and other Bluetooth devices off.

**0. Setup.** Open Audiout Dev and select both Moves. Play music at the usual
level (Spotify volume 85). Keep this running in a Terminal:

```
tail -n 0 -F ~/Library/Logs/Audiout/telemetry.jsonl | grep --line-buffered -E '"evt":"(bt_clock_jump|bt_sink_seek_clamped|bt_sink_anchored|bt_alignment_reset|drift_window_result|drift_window_dropped|drift_correction|wizard_keep|tap_feed_gap)' | awk '{print substr($0,1,300); fflush()}'
```

**1. Sink re-timing (fix 1), the one that matters.**
- Play for 20 minutes untouched and listen every few minutes. Pass means no
  echo or smear at any point.
- If a burst of `bt_clock_jump` lines appears, listen through it. They
  should stay together.
- Turn one Move off, wait 10 s, turn it back on. It should rejoin in time.

**2. Nudges stick (fixes 2 and 6).**
- In one Move's sync drawer, hold − for about 2 s. The speaker should move
  while held and save once, at release.
- Keep pressing − to about −100 ms. It should move every time. If
  `bt_sink_seek_clamped appliedMs=0.0` appears, all speakers should briefly
  re-anchor and the Move should still end up early.
- Deselect and reselect the Move. It should come back at the same offset,
  where 1.2.0 came back about 205 ms off.
- Set the trim back to 0.

**3. Mic calibration (fixes 3 and 4).**
- Run the wizard on one Move in a quiet room. It should propose a value.
- Run it again with that Move nearly silent. It should say it couldn't hear
  and offer by-ear questions or Try again. A confident number like
  −778 ms, or an "implausible" dead end, is a fail.
- On "Couldn't get a clean reading", press Try again. It should listen with
  the mic again.
- Restore the volume, run it once more and Keep. Both Moves should still
  sound together.

**4. Reset log (fix 5).** Reset one Move's alignment from the drawer.
Exactly one `bt_alignment_reset` line naming `drawer` should appear.

**5. Drift analytics (fix 7).** Nothing to listen for. After the session,
check PostHog for `bt_sync:drift_window_ended` and
`bt_sync:drift_window_skipped` from this machine (it is marked internal).

**What to send back:** pass or fail per section, the time of anything that
sounded wrong, and `telemetry.jsonl` if anything failed.

## Still open after this lands

- The passive tracker can't hear in the customer's room: its windows scored
  under 1 against a gate of 3. The session wanted raw windows from the mule
  (defaults key `audiout.driftDumpWindows`) to tune it, and was waiting on Ali
  for that.
- With AirPlay present, the Bluetooth budget drops from 1500 ms to 500 ms.
  Ali ruled on 2026-09-26 for delay-to-worst (see the project's
  `sync-architecture/sync-clock-architecture.md`). Not built.
- The Mac accepts any finite confidence from the phone; the phone's floor of
  25 is the only guard.
- AirPlay send stalls during calibration (222 to 232 ms gaps) are still
  undiagnosed.
- The iPhone app pins audiout-shared 0.14.0; the Mac is on 0.15.1.
