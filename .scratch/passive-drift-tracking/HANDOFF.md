# Handoff — passive drift tracking (roadmap 085)

Written 2026-09-13, 12:40 UTC; rewritten 21:00 UTC after live test 2. Read `spec.md` (13 decisions) and the ticket
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
  `99813077`. Head `69912ea2` (live test 2 fixes, scoped suites 397 passed;
  full suite not rerun since `99813077`). Nothing uncommitted.
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
| 02 correlator (shared) | built; 0.12.0 bass filter; scores marginal on real music at normal level — see brief |
| 03 Mac mic sampler | built, reviewed |
| 04 Bluetooth keep-alive through silence | built; ruled OUT as the cause of the link dips; re-roll prevention still unverified |
| 05 corrections | built; merged-peak rule added `69912ea2`; verify half of decision 7 is a no-op (see below) |
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

## Live test 2 (2026-09-13, 18:18–20:00 UTC) — what was learned

Owner played pop and dance music on two Sonos Moves over Bluetooth
(`54-2A-1B-79-08-9E` "Sonos Move 089E", `C4-38-75-0E-BF-4A` "Move 2 BF4A"),
Mac's built-in mic, normal listening level ≈ 50 dBA at the Mac. Commit
`69912ea2` holds every change below; branch pushed, level with origin.

**Not the feature: a bad Bluetooth link.** For the first hour one Move's
pacing clock stepped > 2 ms nearly every second, only while BOTH Moves were
selected (zero steps with either alone), audible as a volume dip that came
back re-timed. Production did the same. Keep-alive off and AirPods
disconnected changed nothing; a power cycle of the speakers cleared it.
The new `bt_clock_jump` line (uid, size) makes this visible next time.

**Defects found and fixed (all in `69912ea2`):**

1. *Wrong correction on a merged peak.* Two speakers trimmed into sync by
   ear arrive as ONE peak. Nearest-baseline assignment gave it to one
   speaker and slewed it −11.5 ms, then −47.6 ms, out of sync. Ruling
   (owner): a peak that is the only one inside more than one Bluetooth
   baseline's window is `.merged` — both baselines take it as the sync
   point, nothing is corrected. Test
   `speakersArrivingTogetherAreTakenAsTheSyncPointAndNeverCorrected`.
   Seen live afterwards: `merged` at 479.5 (score 4.18) and 526.8 (2.52).
2. *Wizard Keep never re-evaluated tracking* — the second speaker's
   measurement left tracking off until a trim nudge. Fixed in the keep path.
3. *Threshold.* True arrivals ON their baseline scored 2.5–2.9 at normal
   level, 3.1–4.2 at 60 dBA (75 % of the Moves' hardware volume — not a
   product answer); refused windows' best garbage scored ≤ 1.9, scattered.
   Ruling (owner): `PassiveDriftSampler.minPeakToSidelobe = 2.3` for this
   build. The research brief argues for gates instead (below).
4. *8-second windows scored no higher than 4* (2.49 vs 2.56): the score's
   background is the music's own structure, which grows with the window.
   Window stays 4 s.

**Still open, in order of weight:**

- *Scores are marginal on ordinary music at normal volume* (pop, not only
  loops). Input level 48 → 83 changed nothing. Moving the Mac closer changed
  nothing. The owner suspects a pipeline fault; nothing found by reading
  (ring source and rates check out) but NOT proven either way. The window
  dump exists for exactly this: `defaults write com.audiout.Audiout.dev
  audiout.driftDumpWindows -bool YES` (already set on this Mac) writes
  `~/Library/Logs/Audiout/drift-windows/<stamp>-{ref,cap}.f32` (Float32
  mono LE) + `-meta.json`. **No window was ever dumped** — the dump build
  was launched at 19:58 UTC but no speakers were selected on it. First job
  next session: get 3+ dumped windows and analyse them offline (numpy venv
  at the session scratchpad is gone; `python3 -m venv` + `pip install numpy
  scipy` takes a minute). Check: is the arrival there, how sharp, does the
  capture clip, what does partial whitening do to the score.
- *A real ≈ 11 ms desync at ~19:51 UTC was caught by nothing*: no clock
  step (threshold 2 ms/s), and the window at 19:53 was refused (1.29). The
  owner re-trimmed by ear. The cheap detector and the mic both missed it.
- *The verify half of spec decision 7 never runs.* `DriftCorrectionApplier`
  treats `.scheduleVerify` as a no-op ("ticket 06 logs these"), so a guessed
  correction is applied and never checked.
- *The Mac never passes `ambientNoise`* to the correlator, so its SNR
  weighting has never engaged. Recording ~1 s of room sound whenever
  `programIsSilent` and handing it to each window is a Mac-side ticket.
  The brief ranks it last for lag choice, but it is cheap.
- *A false merged peak would move the sync point* (2.3 lets more through).
  Guard idea, not approved: require two consecutive windows to agree.
- `dev/notes/drift-tde-algorithms-brief.md` (committed): ranked research.
  First in ProbeKit: partial whitening by the reference's own spectrum
  (exponent ≈ 0.5); second: peak vs second-best peak inside the ±120 ms
  window as an extra gate; third: sub-band agreement. It advises against
  the 2.3 threshold once those exist.
- Ticket 06 properly, ticket 07, audiout-remote pin bump, merge (owner's
  go-ahead only).

## Live test 3 (2026-09-13, 21:04–21:16 UTC) — the dumped windows

Four windows dumped (`windows-2026-09-13/` beside this file; harness
`dev/drift-window-analysis.py`, needs numpy+scipy). Findings, offline:

- **Pipeline is sound.** Reference and capture clocks agree (a stretch sweep
  peaks at 0 ppm); over the full lag range every strong peak sits at
  548–630 ms where the speakers are; a reversed-reference null scores ~1.
- **The mic hears the music well — as bass.** Correlation coefficient at the
  best lag: 0.67 (100–300 Hz) and 0.42 (300–1000 Hz) in window 1, 0.50/0.43 in
  window 3. In 1–8 kHz the capture is at −50 to −59 dBFS, the mic's floor.
- **Bass gives a comb, treble picks the tooth — and the treble is not there.**
  Bass-band peaks repeat every ~10 ms (558/569/579/588). Window 1's 1–8 kHz
  whitened correlation resolved 555.1 (local score 4.0); windows 2 and 3 had
  nothing in the treble at all (window 3's music had 5 dB less treble; window
  2 was near-field noise at the Mac, +6.6 dBFS peaks, correlation ~0.1).
- **Full whitening (exponent 1.0) is the lever, seen in this room.** Window 4
  (21:16:33, the quietest music: capture −48 dBFS): plain filter local score
  1.85, whitened 4.52, 38 % above the next peak, two of four sub-bands on it,
  at 570.6 ms. Window 1's four-band whitened product → 569.2 (1.9:1); window
  3's app answer 574.3. An arrival near 570 ms recurs in 3 of 4 windows once
  whitened; the plain filter the app runs never resolves it. Window 2 was
  noise. Four windows dumped, all in `windows-2026-09-13/`.
- **The 2.3 threshold accepted garbage within three windows** (21:13:33,
  `merged` at 574.3 @ 2.40; offline: 4 % above its neighbour, local 1.6) and
  moved the sync point to it. Recommend 3 again before any merge.
- Treble is noise-limited (not structure-limited), so longer windows DO help
  in that band specifically; the ensemble brief's plan stands, with these
  windows as fixtures; acceptance = repeatable arrival at normal level.
- `dev/notes/drift-ensemble-design-brief.md` (committed): ranked plan —
  labelled set first, whitening + second-peak gate, sub-band agreement,
  3-window accumulation, clock-step calibration, verify step.

## Live test 4 runbook (2026-09-14, unattended — Alec is out; agreed 2026-09-13 22:00 UTC)

Agreed with Alec: **2 hours of music maximum**, in 12-minute blocks with
silence between; his daily playlist `spotify:playlist:37i9dQZF1E35FDDWYtEKBa`;
first block at tonight's level (Spotify volume 100, Moves' app volumes as
left), then a few dB quieter for the neighbours (Spotify ~85) and keep it
there while windows still resolve. Log the level per block. Nothing else in
the house is touched: not the production app, not system settings, not the
Mac's position, not the mic input level (83).

Blocks: 5 × known-good at Alec's level → 1 × one Move muted (garbage) →
2 × forced jump (+40 ms trim on `54-2A…`, before/after) → 2 × validation of
whitening + gates once built. Every window is dumped
(`audiout.driftDumpWindows` is set) and copied to `windows-2026-09-14/`.

Commands (dev bundle id `com.audiout.Audiout.dev`; hold the live-test slot
first: `bash scripts/livetest.sh acquire --label bluetooth-latency-drift-6c2d59`):

```
# keep the Mac awake for a block (no settings change)
caffeinate -dims -t 800 &
# relaunch with both Moves self-selected (key already set; verified 2026-09-13 21:29 UTC)
defaults write com.audiout.Audiout.dev audiout.devSelectOnLaunch -array "54-2A-1B-79-08-9E:output" "C4-38-75-0E-BF-4A:output"
open "build/Audiout Dev.app"          # 2 s later: dev_select_on_launch selected=2, tracking running
# music
osascript -e 'tell application "Spotify" to set sound volume to 100'
osascript -e 'tell application "Spotify" to play track "spotify:playlist:37i9dQZF1E35FDDWYtEKBa"'
osascript -e 'tell application "Spotify" to pause'
# forced, labelled jump: quit the app, edit trims, relaunch (the hook reselects)
osascript -e 'tell application "Audiout Dev" to quit'
python3 - <<'PY'
import json;p='/Users/alechenderson/Library/Application Support/com.audiout.Audiout.dev/bt-sync-trims.json'
d=json.load(open(p)); d['trims']['54-2A-1B-79-08-9E:output']+=40; json.dump(d,open(p,'w'),indent=2)
PY
# if a Move drops off Bluetooth (Alec was asked to `brew install blueutil`)
blueutil --connect 54-2A-1B-79-08-9E
# analyse
python3 dev/drift-window-analysis.py      # needs a venv with numpy+scipy
```

Stop rules: pause music on any error line, on a clock-step storm (bad link:
stop, do not power-cycle anything), or when the 120-minute budget is spent;
quit the dev app and release the slot at the end. The first window is 3 min
after the hook selects; do not reselect mid-block (it restarts the timer).

## Logging (local only, `~/Library/Logs/Audiout/telemetry.jsonl`)

All `cat: localPlayback`:

- `drift_tracking_state`: tracking on/off, selected vs measured Bluetooth
  count, anchors, room delay, baselines
- `drift_window_started`, `drift_window_skipped` (reason),
  `drift_window_dropped` (reason)
- `drift_window_result`: `result` (`observations` | `aligned` | `merged` |
  `rebaselined` | `unusable` | `blind`), `rejection`, `peaks`, `candidates`
  (best per speaker even when refused, `delay@confidence`), `errors`,
  `baselines`; `merged` adds `devices`, `delayMs`
- `drift_correction_started`, `drift_correction_landed`,
  `drift_correction_refused`
- `bt_clock_jump`: `uid`, `ms` — every pacing-clock step > 2 ms, one poll
  per second per sink. A storm of these on one speaker = a bad link, not
  drift; power-cycle the speaker.

Watch live with:

```
tail -n 0 -F ~/Library/Logs/Audiout/telemetry.jsonl | grep --line-buffered -E '"evt":"(drift_window_result|drift_correction|bt_clock_jump)' | awk '{print substr($0,1,600); fflush()}'
```

## Traps hit (both sessions)

- **A Monitor pipeline ending in `cut` delivers nothing:** `cut` buffers.
  Finish with `awk '{...; fflush()}'`.
- **Helper agents leave CPU burners running.** `pgrep -x yes` before
  trusting timings.
- **Unused listening windows count toward the blind limit.** 5 unusable in a
  row turns tracking off until baselines are reset (reselect speakers or
  relaunch).
- **The first window runs 3 minutes after tracking turns on**, and EVERY
  reselect restarts that timer. Tell the owner not to touch the selection
  while waiting.
- **A clock-step storm triggers a window every 5 s** (no rate limit on
  event triggers), so a bad link blinds the tracker in ~25 s.
- **A wrong correction persists to disk** (`~/Library/Application
  Support/com.audiout.Audiout.dev/bt-sync-trims.json`, `latencyMs`). Quit
  the app, edit the number back, relaunch. The production app's store is a
  different file — don't read the wrong one.
- **Live-test slot was held by a finished session** (this worktree's
  earlier VM work); `livetest.sh done` from that worktree frees it.
- **Recorder restarts (from main's mic-probe fix) withhold the mic
  timestamp**, so a window with a restart is dropped (`reference_not_aligned`).
- **`com.audiout.Audiout.dev` has builds in several worktrees.** Don't run
  `purge-dev-installs.sh --apply` without asking.
