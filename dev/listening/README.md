# Unattended listening night

`unattended-night.sh` runs the measurable parts of
`dev/notes/bt-sync-discovery/runbooks/00-listening-evening-m1.md` on the second
Mac (`SUMUP-M9Y197RFVG.local`, user `alechamilton`) with nobody in the room. It
plays a 75-minute click file with `afplay`, records the built-in mic, and writes
`results/<date>_<time>/summary.md`. `launch-tonight.sh` starts it at a clock time.

| Block | Selection | Length | From the runbooks |
|---|---|---|---|
| A | both Moves | 25 min; the Move that is not `--c-move` (Move 2 by default) is disconnected for 10 s at minute 22 | M1 Part 1 section 1 (fix 1) |
| B | the `--c-move` Move (Sonos Move 089E by default) + This Mac | play 60 s, pause 90 s, play 60 s | runbook 1 Run B (M1 Part 2) |
| C (`--with-airplay`) | Move 1 on Bluetooth (`--c-move`) + the other Move in Wi-Fi mode (`--airplay-id`) | 60 min | runbook 2 Part A, AirPlay variant (M1 Part 4) |

Selection is by hand: three clicks a night (four with Block C). The app's
launch-time restore leaves Bluetooth speakers selected but not connected (third
smoke run, 2026-10-03), so the driver never quits Audiout Dev and needs it open.
At each block it stops `afplay`, writes `WAITING <block>` naming the exact rows,
and waits for Enter or `~/listening/go-block-<a|b|c>` (30 min, then that block is
aborted). It then plays and, within 35 s, needs the app's selection
(`set_output_set`), a Bluetooth output line per Move, `connect_requested` for
the AirPlay row, and audio (`stream_health`) to match; otherwise it says what
differs and shows `WAITING` again, three times at most.

## One-time setup on the second Mac

1. From the repo root, copy the six files side by side into `~/listening/` (not
   Desktop or Documents; that Mac's Desktop is iCloud-synced):
   ```
   tar -cf - -C dev/listening unattended-night.sh launch-tonight.sh README.md .gitignore \
     -C ../notes/bt-sync-discovery/runbooks click-track-3s.wav click-pair-spacing.py \
     | ssh alechamilton@SUMUP-M9Y197RFVG.local 'mkdir -p ~/listening && tar -xf - -C ~/listening'
   ```
2. Install the dev build under `~/Applications` from the checkout whose `build/`
   holds it. The iCloud-synced Desktop adds extended attributes that break the
   code signature, so stream it and strip them:
   ```
   tar -C build --no-xattrs --no-mac-metadata -cf - "Audiout Dev.app" \
     | ssh alechamilton@SUMUP-M9Y197RFVG.local 'mkdir -p ~/Applications && tar -xf - -C ~/Applications && xattr -cr ~/Applications/"Audiout Dev.app"'
   ```
   Open it once at the screen and grant its own prompts.
3. Pair and connect both Moves; run the wizard once on each to store an alignment.
   `brew install blueutil ffmpeg`; `python3 -m pip install numpy` (or set `PYTHON=`).
4. In Terminal in `~/listening`, run `./unattended-night.sh --dry-run` and Allow
   Microphone and Bluetooth (2 minutes; no "DRY RUN FALLBACK" note = mic works).
5. `./unattended-night.sh --list-devices`; paste the ids into `MOVE1_ID`,
   `MOVE2_ID`, `AIRPLAY_ID` at the top, or pass `--move1`, `--move2`, `--airplay-id`.
6. The room: quiet; speakers 1 to 2 m from the Mac, equidistant; AirPods and phone
   away; 5 GHz Wi-Fi, lid open, on mains; no Game Mode (moves Bluetooth latency 70 to 90 ms).
7. Nothing else may use that Mac during the blocks. It is also the remote test
   Mac; "Starting it tonight" says when to take its test permits away.

### Device ids

A Bluetooth id is the speaker's hardware address with dashes plus `:output`
(`54-2A-1B-79-08-9E:output`), the same on every Mac; an AirPlay id is colon hex.
`--list-devices` marks AirPlay ids sharing a Move's first three octets "(a Sonos
Move in Wi-Fi mode)"; such a Move must have been selected once so the log knows
its id. The alignment store is per Mac, so the wizard runs on the second Mac. The
driver refuses an id that store and `telemetry.jsonl` have never seen. `WAITING`
names Moves as the app does, "Move 2 (SONOS BF4A)": the last two address bytes.

### Why it starts inside the logged-in session

macOS grants Microphone and Bluetooth to the app that started a process; a
process started over ssh never gets a prompt. So a one-shot LaunchAgent in
`gui/$(id -u)` (the logged-in user's launchd domain) opens Terminal (step 4's grants).

## Rehearsal: `--smoke`

`./unattended-night.sh --smoke` (same flags as the night) is the real run with
Block A 2 min (disconnect at 1:30), B 20 s / 30 s / 20 s, C 2 min; "SMOKE" on top.

## The watchdog

Every 60 s during a block it writes to `status.log` and Terminal:
`OK <block> <time> rec=<bytes> rms=<dBFS> clicks=<n> clock_lines=<id:count,...> load=<load1>`.
Checks: the recording grew; the mic level over the last 10 s is above -80 dBFS;
`click-pair-spacing.py` finds at least 8 clicks in the last 30 s (not while Block
B is paused); every selected Bluetooth speaker logged `bt_clock_deviation` in the
last 90 s; the load is under 4. A failing check writes `ALERT <block> <time>
<check> <value>`; three in a row on one check write `ABORT` and end the block.
Then `BLOCK-START`, `BLOCK-END` and `DONE`. Before Block A a 20 s probe runs the
checks once and any ALERT stops the run with what to fix. An `audio` check reads
the app's newest `stream_health` line (peak above -60 dBFS or `silent_s` 0); on
failure it starts a fresh `afplay`, which follows the current default output.

Watch from another Mac (the driver prints the folder at start):
```
ssh alechamilton@SUMUP-M9Y197RFVG.local tail -F '<results path>/status.log' | grep --line-buffered -E 'ALERT|ABORT|BLOCK|WAITING|DONE'
```
Your main Claude session can run that under a monitor and notify your phone per line.

## Starting it tonight

In Terminal on the second Mac (Screen Sharing is fine), from `~/listening`:

```
./launch-tonight.sh 23:30                 # Blocks A and B, about 35 min
./launch-tonight.sh 23:30 --with-airplay  # adds Block C, about 1 h 40 min
```

It runs `--check` first (missing tool, empty or unknown id, Audiout Dev not
running), loads `~/Library/LaunchAgents/com.audiout.listening-night.plist` with
`launchctl bootstrap`, and keeps the Mac awake with `caffeinate -dims` until the
agent fires, removes itself and runs the driver. It prints how to cancel.

The clicks, each after its `WAITING` line, then Enter in that Terminal or
`ssh alechamilton@SUMUP-M9Y197RFVG.local touch ~/listening/go-block-a` (`-b`, `-c`):

1. A: select both Moves, nothing else.
2. B: select the `--c-move` Move (Sonos Move 089E by default) and This Mac (the
   MacBook Air Speakers row); deselect the Move that Block A disconnected.
3. C: press the other Move's button for Wi-Fi mode, wait for its AirPlay row, then
   select that row plus the Bluetooth Move, nothing else. A Move is Bluetooth or
   AirPlay, never both. The last line then says to switch it back.

Block A's minute-22 disconnect and reconnect are automatic. They come last, and
Block B uses the other Move, because in the 2026-10-03 smoke run the reconnected
Move stayed silent for the rest of the run: the app rebuilt and anchored its
output and logged clock lines, but no sound came out, not after a reselect in
Block B and not after a full capture rebuild. No output line within 60 s of the
reconnect is an `ALERT` and a finding, not a cue to click. From the disconnect to
the end of Block A, a `clock` alert for that Move is still written but does not
count toward `ABORT`. summary.md's Block A gives that Move's output lines, clock
lines and mic click pairs after the reconnect.

### When the app's restore works: `--relaunch`

`--relaunch` writes `~/Library/Application Support/com.audiout.Audiout.dev/routing.json`
(`{"schemaVersion":1,"state":{"mainOutKind":"selected","selectedDeviceIDs":[...]}}`)
with Audiout Dev quit, turns on "Reconnect last speakers when Audiout starts"
(`general.reconnectAtLaunch`, off by default, turned back off at the end),
connects the wanted Moves with blueutil, relaunches, and checks the file and
telemetry 90 s later. It needs Automation for Terminal to quit Audiout Dev.

Then, and never before the driver starts, on the development Mac:

1. At "Block A started … set remoteSlots to 0": `git config audiout.remoteSlots 0`.
2. At "Block C started": `git config audiout.remoteSlots 1`, only if tests must keep flowing.
3. At "done; set remoteSlots back to 2": `git config audiout.remoteSlots 2`.

## The results folder

- `results/<date>_<time>/summary.md`: per block, the `click-pair-spacing.py`
  offsets (B: before the pause, right after resume, one minute after; A and C:
  linear fit and jumps), telemetry line counts, `bt_clock_deviation` slope per
  speaker, load, and runbook 2's interpretation table.
- `blocks.tsv` (telemetry byte offsets, marks, ids per block); `block<X>-raw.wav`,
  `block<X>.wav` (16-bit), `block<X>.txt`, `block<X>-telemetry.jsonl`
  (the block's lines matching `bt_clock_jump|bt_sink_anchored|bt_sink_release_overshoot|bt_sink_seek_clamped|tap_feed_gap|bt_clock_deviation|drift_window_result|drift_window_dropped|drift_correction|bt_room_term_changed|room_delay_changed`).
- `load.csv` (load once a minute), `status.log` (watchdog), `driver.log`, `notes.txt`.

## What it does not cover

- M1 Part 1 sections 2 to 4 (stepper, reselect, wizard, Try again, reset): need a person.
- Listening by ear; the mic measures offsets only. M1 Part 3 (PR #228): the 950 ms store edit, steps 3 to 5, questions (a) and (b).
- Fix 7's PostHog check; runbook 1 Runs A and C; runbook 2 Part B (the drift meter); the minute between blocks (no recording).
