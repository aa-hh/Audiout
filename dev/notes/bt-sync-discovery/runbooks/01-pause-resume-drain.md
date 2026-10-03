# Runbook 1: does a pause make a Bluetooth speaker lose its timing?

**Question.** When the music pauses long enough for the capture tap to idle and the
Bluetooth ring to drain, does the Bluetooth speaker come back at the wrong time?
The code says yes (nothing re-anchors on resume, `NativeCaptureCoordinator.swift:1769-1778`,
`BTSyncedSink.swift:930-950`); one 2026-08-23 listen suggested no. This settles it.

**Decides.** Whether the Bluetooth servo (discovery option 1.1) needs gap-fill on pause,
or only rate correction. About 20 minutes including the build.

**Needs.** Your Mac (lid open, so the built-in mic works), two Bluetooth speakers of
*different* brands or models (different latencies matter; two identical Moves would hide
the effect), the dev build, QuickTime Player, and the files next to this runbook:
`click-track-3s.wav` and `click-pair-spacing.py` (needs numpy: `python3 -c "import numpy"`).

## Setup (once)

1. Build and launch the dev id, from the main checkout on your Mac:
   ```
   bash scripts/livetest.sh acquire --label runbook-1
   APP_NAME="Audiout Dev" BUNDLE_ID="com.audiout.Audiout.dev" bash scripts/make-app.sh
   open "build/Audiout Dev.app"
   ```
   If `acquire` says busy, another session holds the dev id; wait for it rather than
   building over it.
2. In Audiout: Bluetooth keep-alive at its default (10 min) in Settings, so the A2DP
   stream itself stays up through the pause. This test is about the ring, not the link.
3. Connect both speakers and wait a full minute before anything else: the link's
   clock steps for up to ~40 s after connect and the Mac shows no indicator for it. Each must already have an alignment (measured or by ear) so the two have
   different stored latencies; if one has none, run "Align" on it first.
4. Put both speakers within ~2 m of the Mac, roughly equidistant from it, in the same
   room. Quiet room.
5. Note the telemetry file: `~/Library/Logs/Audiout/telemetry.jsonl`. Empty it or note
   the time, so the run is easy to find:
   ```
   date -u; tail -1 ~/Library/Logs/Audiout/telemetry.jsonl
   ```

## Run A: Bluetooth only (the telling case)

Selection in Audiout: **both Bluetooth speakers, nothing else** (Mac speakers off, no
AirPlay, no Cast).

1. Open `click-track-3s.wav` in QuickTime Player, View › Loop, press play. Let it run
   **60 s**. Listen: are the two speakers' clicks together? (They should be, given the
   stored alignments.)
2. Start a **QuickTime › File › New Audio Recording** on the built-in mic now and leave
   it running for the whole run.
3. Pause QuickTime playback. Wait **90 s** (longer than the 50 ms padder and long enough
   to drain a ring of up to 1.5 s; short enough to stay inside the 10 min keep-alive).
4. Resume playback. Listen for **60 s**. Are the two speakers still together, or do you
   now hear two clicks?
5. Stop the recording, save as `runA.m4a`.

## Run B: Bluetooth plus the Mac's own speakers

Selection: **one Bluetooth speaker plus This Mac** (the Mac's speakers stand in for a
network speaker here: `SyncedLocalSink` holds itself to the host clock the way AirPlay
does).

Repeat steps 1–5 with the Mac speakers at a moderate level, save as `runB.m4a`. Expected
size if the drain is real: the Bluetooth speaker comes back roughly `R − L` early, i.e.
several hundred ms, which you will hear as a clear double click.

## Run C (optional, 12 min): pause past the keep-alive

Same as Run A, pause **11 min** instead of 90 s. This is the case where the A2DP stream
itself idles and restarts, so a 20–90 ms re-roll is expected on top. It tells us how much
of the resume error is the ring and how much is the link.

## Reading the result

Convert and measure each recording:
```
afconvert -f WAVE -d LEI16 runA.m4a runA.wav
python3 click-pair-spacing.py runA.wav
```
The script prints, every 3 s, the offset between the two arrivals at the mic. Look at
the block before the pause and the block after it:

- **Same offset before and after (within ~5 ms):** the ring does not lose time on a
  pause. Gap-fill is not needed; the servo only has to track rate. (Then the 08-23
  observation was right, and we look for why the code reads otherwise.)
- **Offset jumps at the resume and stays jumped:** the drain is real. Run A's jump should
  be about the difference of the two speakers' stored latencies; Run B's about `R − L`
  (hundreds of ms). Gap-fill at enqueue goes into option 1.1.
- **Offset jumps then walks back over seconds:** something is re-anchoring after all;
  note how long it takes.

Then the log lines, to confirm what the code did during the pause and resume:
```
grep -E 'bt_sink_anchored|bt_sink_release_overshoot|tap_feed_gap|bt_clock_jump' ~/Library/Logs/Audiout/telemetry.jsonl | tail -40
```
- A `bt_sink_anchored` line at the resume time means the sink re-anchored (unexpected
  on main; if present, say so, it changes the diagnosis).
- No `tap_feed_gap` around the pause is expected: an unfilled hole is not logged.
- `bt_clock_jump` lines during the pause mean the link was doing something on its own;
  keep them, they matter for Runbook 2.

## Hand back

Reply in the thread with: the three offset numbers per run (before, right after
resume, one minute after), what you heard, and attach `runA.wav`/`runB.wav` (or just
the script output) plus the grep output. Release the slot: `bash scripts/livetest.sh done`.
