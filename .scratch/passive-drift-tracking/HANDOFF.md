# Handoff — passive drift tracking (roadmap 085)

Written 2026-09-13, 12:40 UTC. Read `spec.md` (13 decisions) and the ticket
files in `issues/` first; this file is only where things stand.

## What this is

The app keeps Bluetooth speakers aligned during playback by listening to the
music itself: the Mac's microphone records a few seconds, the recording is
compared against the audio the app actually sent, each speaker's arrival time
is found, and a speaker that has moved gets its stored measured latency
nudged back. AirPlay speakers are never adjusted; they are the fixed
reference (decision 13).

## Where the code is

- **Mac repo branch:** `claude/bluetooth-latency-drift-6c2d59`, worktree
  `.claude/worktrees/bluetooth-latency-drift-6c2d59`, pushed to origin.
  Not merged to main; main was merged INTO it three times, last at
  `99813077` (2026-09-13, full suite 3,879 passed), so the branch is level
  with main as of that merge. Nothing uncommitted.
- **audiout-shared:** everything committed on `main`. Tag `0.12.0`
  (`d4e96b2`) holds the bass filter and `analyzeWithCandidates`. The Mac
  branch now pins `from: "0.13.0"` (main's emitter-field constants), which
  is built on 0.12.0 and keeps the fix. That checkout has uncommitted changes
  that are NOT ours: `docs/analytics-events.md`, untracked
  `.github/workflows/`, `worktrees/`. Leave them.
- **Worktree `drift-correction-policy`:** obsolete helper worktree, reset to
  match origin and flagged `.prunable`; housekeeping removes it.
- **audiout-remote:** still pinned to shared 0.9.0; bump owed.

## Ticket state

| Ticket | State |
|---|---|
| 01 outgoing-audio ring | built, reviewed; live check owed |
| 02 correlator (shared) | built; 0.12.0 fixed a live defect (below) |
| 03 Mac mic sampler | built, reviewed |
| 04 Bluetooth keep-alive through silence | built, reviewed; **whether it prevents the latency re-roll is unverified on hardware** |
| 05 corrections | built, reviewed in 3 passes |
| 06 field logging | partly done ad hoc in `4b191c25` (see Logging); the ticket as written is still open. Read its Comments first: the PostHog correction event already exists, it fires too early for a slew, and a window-count event needs Alec's approval |
| 07 iPhone re-sync button | not started |
| 08 roadmap swap | done |

Suites at `99813077`: full suite 3,879 tests passed. Build clean.

The latest merge brought in main's wizard mic-permission focus fix and its
analytics (#196, #194). They touched `MicProbeSession.swift`, which this branch
also changed; it auto-merged, and the recorder-restart handling (timestamp
withheld after a restart) is intact.

Main's #193 (merged in) makes the alignment wizard lead with the automatic mic
measurement; it writes the same stored measured latency that drift
corrections adjust. Not a conflict, but the live test now runs on that wizard.

## The live test so far (2026-09-13, 01:12–01:53 UTC)

Owner played vocal pop music at decent volume on two Bluetooth speakers,
both mic-measured: `54-2A-1B-79-08-9E` (latency 285 ms) and
`C4-38-75-0E-BF-4A` (424 ms). Tracking turned on correctly with both
baselines at 538 ms, and the mic indicator showed on each window.

All 5 windows were unusable, so the tracker switched itself off (by design,
after 5) and **made no correction**:

| UTC | Result |
|---|---|
| 01:26 | too periodic |
| 01:29 | no convincing peak |
| 01:32 | too periodic |
| 01:35 | too periodic |
| 01:38 | too narrowband |

**Fixed in shared 0.12.0:** the periodicity check refused any bass-heavy
music. A pop mix is mostly bass, and at one bass period its self-correlation
is near ±1. Reference, capture and ambient slice are now band-limited to
300 Hz–8 kHz before the checks and the correlation. A bass-heavy test fixture
was red before the fix and green after; delays are unchanged to 0.002 ms.
500 Hz was tried first and dropped an existing fixture's quieter speaker to
2.89, under the threshold of 3.

**Not explained yet:** the 01:29 "no convincing peak" and the 01:38
"narrowband". The new build logs the best rejected candidate per speaker,
which tells a score just under 3 apart from an arrival outside the ±120 ms
search window.

**Also observed:** around 01:48 UTC the owner heard the speakers go out of
sync while tracking was already off. That is the real Bluetooth jump this
feature exists for. The log shows no cause; audio apps were starting and
stopping between 01:42 and 01:48.

The fixed build (`4b191c25`, before the second main merge) was built and launched at 01:53 UTC, but no
speakers were selected on it, and no window has run on it. **As of 12:40 UTC
the app is not running and the live-test slot is free.**

## Next steps, in order

1. `bash scripts/livetest.sh acquire --label <branch>`, then
   `APP_NAME="Audiout Dev" BUNDLE_ID="com.audiout.Audiout.dev" bash scripts/make-app.sh`
   and `open "build/Audiout Dev.app"`.
2. Owner selects both speakers and plays pop music. Confirm a
   `drift_tracking_state` line with `running:true` and two baselines.
3. Read each `drift_window_result`. The question it answers: are windows now
   usable, and what do `candidates` show for rejected ones?
4. If windows are usable and corrections land, check direction by ear and in
   `drift_correction_started`/`landed` (latency before and after).
5. Then the remaining live checks: pause longer than the 10-minute keep-alive
   timeout and resume; turn one speaker off and on; 20+ minutes continuous.
6. Proposed and not approved: only correct when two consecutive windows agree
   within about 1 ms, to guard against a false match from room noise. The
   owner asked whether this works with people talking; the answer given was
   "probably, not proven". Ask before building.
7. Then: ticket 06 properly, ticket 07, audiout-remote pin bump, merge to main
   (never without the owner's go-ahead).

## Logging (local only, `~/Library/Logs/Audiout/telemetry.jsonl`)

All `cat: localPlayback`:

- `drift_tracking_state`: tracking on/off, selected vs measured Bluetooth
  count, anchors, room delay, baselines
- `drift_window_started`, `drift_window_skipped` (reason),
  `drift_window_dropped` (reason)
- `drift_window_result`: `result`, `rejection`, `peaks`, `candidates` (best
  per speaker even when refused, `delay@confidence`), `errors`, `baselines`
- `drift_correction_started`, `drift_correction_landed`,
  `drift_correction_refused`

Watch live with:

```
tail -n 0 -F ~/Library/Logs/Audiout/telemetry.jsonl | grep --line-buffered '"evt":"drift_' | awk '{print substr($0,1,600); fflush()}'
```

## Traps hit this session

- **A Monitor pipeline ending in `cut` delivers nothing:** `cut` buffers.
  Finish with `awk '{...; fflush()}'`.
- **Helper agents leave CPU burners running.** Two `yes` processes sat at
  97% for 54 minutes after a flake reproduction. `pgrep -x yes` before trusting
  timings.
- **Unused listening windows count toward the blind limit.** 5 unusable in a
  row turns tracking off until baselines are reset (reselect speakers or
  relaunch).
- **The first window runs 3 minutes after tracking turns on**, not
  immediately.
- **Once, Audiout Dev exited with no crash report.** The log ended in its
  normal shutdown sequence (capture stop, aggregate destroyed) and nothing
  after. Cause unknown; the owner was not asked to confirm whether they quit
  it.
- **Guard 4 once refused a commit whose suite then passed** on an identical
  rerun. Run `AUDIOUT_FULL_SUITE=1 bash scripts/run-tests.sh` to warm the
  pass cache, then commit.
- **A shared version bump pulls in other sessions' protocol cases.** Shared
  0.11.0 added `CompanionCommand.activateLicenseKey`; the dispatcher refuses it
  as unknown with a `razor:` note. The licence-key branches replace that line.
- **Recorder restarts (from main's mic-probe fix) now withhold the mic
  timestamp**, so a window with a restart is dropped, not measured across the
  gap. There is no test for this; the recorder has no seam without real
  hardware.
- **The 188 `*.ptphelper` entries in the dry run are override-only records
  with no loaded job.** `--apply` cannot remove them and they are inert.
- **`com.audiout.Audiout.dev` has builds in three worktrees.** Don't run
  `purge-dev-installs.sh --apply` without asking.
