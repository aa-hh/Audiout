# Listening evening M1: the 1.2.0 fixes, runbook 1 Run B, then AirPlay

One evening on the two Sonos Moves, the MacBook and the AirPlay speaker. Part 1
decides whether fixes 1 to 6 land (see `../../bt-sync-workstream-2026-09-26.md`).
Part 2 decides whether a pause makes a Bluetooth speaker lose its timing. Part 3
decides whether draft PR #228 can leave draft. Part 4 is optional.

## Setup

The build is **Audiout Dev** from the integration worktree:
`.claude/worktrees/bt-sync-integration/build/Audiout Dev.app` (branch
`claude/bt-sync-integration-2026-09-26`). It now also contains draft PR #228
(a Bluetooth speaker slower than AirPlay's start buffer makes AirPlay wait for
it). It uses the standing dev bundle id,
`com.audiout.Audiout.dev`, because nothing tonight touches permissions, so the
grants already given to that id apply and no prompts appear.

Hardware: both Moves, the MacBook, and the AirPlay speaker. The AirPlay speaker
is only needed for Parts 3 and 4; leave it off until then.

1. Take the live-test slot before opening it:
   `bash scripts/livetest.sh acquire --label m1-listening`. Exit 2 means
   someone else holds the dev id; don't open the build until they are done.
2. Quit any running Audiout Dev, then open the `.app` above.
3. Turn off AirPods and every other Bluetooth device.
4. Connect both Moves and **wait a full 60 seconds** before anything else. The
   link's clock steps for up to about 40 s after connecting, and the Mac shows
   no sign of it.

## Part 1: the fixes test script

Copied from the fixes handoff's "Test steps for Ali". Section 5 is moved to
the end.

**0. Setup.** Open Audiout Dev and select both Moves. Play music at the usual
level (Spotify volume 85). Keep this running in a Terminal:

```
tail -n 0 -F ~/Library/Logs/Audiout/telemetry.jsonl | grep --line-buffered -E '"evt":"(bt_clock_jump|bt_sink_seek_clamped|bt_sink_anchored|bt_alignment_reset|drift_window_result|drift_window_dropped|drift_correction|wizard_keep|tap_feed_gap|bt_room_term_changed|room_delay_changed)' | awk '{print substr($0,1,300); fflush()}'
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

## Part 2: runbook 1, Run B only

Run A is skipped. It compares two Bluetooth speakers with different stored
latencies, and two identical Moves have the same latency, so a drain on pause
would move both by the same amount and the recording would show nothing.

Run B pairs **one Move with This Mac** (the Mac's own speakers hold to the host
clock the way AirPlay does). Follow `01-pause-resume-drain.md`:

1. Its setup steps 2 to 5 (skip step 1; the build is already running). Stop
   the Terminal tail from Part 1 first. The second Move can be switched off.
2. The Run B section: repeat Run A's steps 1 to 5 with the Mac speakers at a
   moderate level, and save the recording as `runB.m4a`.
3. "Reading the result": convert `runB.m4a`, run `click-pair-spacing.py` on it,
   and run the `grep` over `telemetry.jsonl`.

This build carries fix 1, which moves a sink's read position when wall time
and pulled frames drift 20 ms apart and writes no log line when it does. If the
offset jumps at the resume and then walks back over seconds, fix 1 may be the
cause rather than main's behaviour. Say so in the reply.

## Part 3: a slow Bluetooth speaker holds AirPlay back (PR #228)

PR #228 counts a Bluetooth speaker's stored latency only, never its trim. The
sync drawer's typed field sets the trim, so it cannot set this up.

1. Restart the Terminal tail from Part 1. Turn on the AirPlay speaker. Check
   its start buffer is 1000 ms.
2. Give one Move a stored latency of 950 ms by editing the store, the way the
   2026-09-14 drift test forced a latency jump. Quit Audiout Dev, then open
   `~/Library/Application Support/com.audiout.Audiout.dev/bt-sync-trims.json`.
   It has a top-level `"latencyMs"` object keyed by device id, which is the
   Move's Bluetooth address with dashes plus `:output`, for example
   `"54-2A-1B-79-08-9E:output"` (System Information › Bluetooth shows the
   address). Set that Move's value to `950`, adding the key if it is missing,
   and touch nothing else. Relaunch Audiout Dev.
   Fallback, the wizard: select that Move only, with the AirPlay speaker
   deselected (with AirPlay selected the wizard stops at 500 ms; alone it goes
   to 1500 ms), steer the answers until it proposes more than 900 ms, and Keep.
   The 950 stays stored until you reset the Move's alignment in step 5.
3. Select the AirPlay speaker as well, so the selection is AirPlay plus that
   Move, and play music. Pass: one audible gap on every speaker, then all in
   sync. The tail shows `bt_room_term_changed` and a `room_delay_changed` line
   with `airplay_pre_ms` above 0.
4. Deselect the Move. Pass: AirPlay jumps forward, and a `room_delay_changed`
   line shows `airplay_pre_ms` back at 0.
5. Regression check. Reset the Move's alignment from the drawer, run the
   wizard on it normally (its real latency is well under 1000 ms), then select
   AirPlay plus that Move. Pass: it behaves as on `main` (no extra gap,
   AirPlay not held back), and no `bt_room_term_changed` line appears.

Two questions only your ears can settle:

- **(a)** If the slow Move is re-measured lower, so it fits under the buffer
  again, should the room delay fall back (one more gap) or stay at its highest
  value until the Move is deselected? Today it falls back.
- **(b)** With two slow Moves, deselecting the slower one leaves the delay at
  that Move's value while the other still clears the buffer. Acceptable, or
  should it drop to the remaining Move's value?

## Part 4 (optional, 60 min, mostly unattended): runbook 2 against AirPlay

Follow `02-bt-vs-host-hour.md` Part A with one change: in step 3 select **the
AirPlay speaker plus one Move** instead of This Mac plus the Move. This Mac's
speakers run on the Mac's built-in audio clock, which sits tens of ppm off host
time; AirPlay plays on host time, so the slide this measures leaves that clock's
own offset out of the number. Everything else, the scripts included, is the same.

## Afterwards

Fix 7 (drift analytics) has nothing to listen for: check PostHog for
`bt_sync:drift_window_ended` and `bt_sync:drift_window_skipped` from this
machine (it is marked internal). Then release the slot:
`bash scripts/livetest.sh done`.

## What to send back

- Part 1: pass or fail per section, and the time of anything that sounded
  wrong.
- Part 2: the three offsets from the script (before the pause, right after
  resume, one minute after), what you heard, and the script and `grep` output.
- Part 3: pass or fail for steps 3, 4 and 5, and your answers to (a) and (b).
- Part 4, if run: the script's last line, the deviation slope, and `hour.txt`
  and `dev.txt`.
- `telemetry.jsonl` if anything failed, plus `runB.wav` if the offsets look
  odd.
