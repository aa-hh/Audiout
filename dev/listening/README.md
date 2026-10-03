# Unattended listening night

`unattended-night.sh` runs the measurable parts of
`dev/notes/bt-sync-discovery/runbooks/00-listening-evening-m1.md` on the second
Mac (`SUMUP-M9Y197RFVG.local`, user `alechamilton`) with nobody in the room. It
loops the click track, records the built-in mic during each block, and writes
`results/<date>_<time>/summary.md`. `launch-tonight.sh` starts it at a clock time.

| Block | Selection | Length | From the runbooks |
|---|---|---|---|
| A | both Moves | 25 min; the second Move is disconnected for 10 s at minute 20 | M1 Part 1 section 1 (fix 1) |
| B | Move 1 + This Mac | play 60 s, pause 90 s, play 60 s | runbook 1 Run B (M1 Part 2) |
| C (`--with-airplay`) | the AirPlay speaker + Move 1 | 60 min | runbook 2 Part A, AirPlay variant (M1 Part 4) |

Before each block the driver quits Audiout Dev, writes the speakers into
`~/Library/Application Support/com.audiout.Audiout.dev/routing.json`
(`{"schemaVersion":1,"state":{"mainOutKind":"selected","selectedDeviceIDs":[...]}}`),
sets the output volume to 50 and relaunches. Launch restores that file only with
"Reconnect last speakers when Audiout starts" on (`general.reconnectAtLaunch`,
off by default); the driver turns it on, notes it, and turns it off at the end.
90 s after launch the file and telemetry must both show exactly those speakers
(`set_output_set` count, Bluetooth sink lines and AirPlay `connect_requested` by
id). A speaker discovered after the restore is dropped, so a mismatch gets one
more relaunch, then the block is skipped.

## One-time setup on the second Mac

1. From the repo root, copy the scripts and runbook files outside Desktop and
   Documents (that Mac's Desktop is iCloud-synced):
   ```
   tar -cf - dev/listening/*.sh dev/listening/README.md dev/notes/bt-sync-discovery/runbooks \
     | ssh alechamilton@SUMUP-M9Y197RFVG.local 'mkdir -p ~/audiout-listening && tar -xf - -C ~/audiout-listening'
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
4. `brew install blueutil ffmpeg`, then `python3 -m pip install numpy` (or point
   `PYTHON=` at a Python that has numpy).
5. Grant permissions once while you are there, in Terminal, from
   `~/audiout-listening/dev/listening`:
   - `./unattended-night.sh --dry-run`; Allow Microphone, "Terminal wants to
     control QuickTime Player" and Bluetooth. About 2 minutes; no "DRY RUN
     FALLBACK" note in its summary means the mic and QuickTime work.
   - `osascript -e 'tell application id "com.audiout.Audiout.dev" to quit'` and
     click Allow on "Terminal wants to control Audiout Dev".
6. `./unattended-night.sh --list-devices`; paste the ids into `MOVE1_ID`,
   `MOVE2_ID`, `AIRPLAY_ID` at the top, or pass `--move1`, `--move2`, `--airplay-id`.
7. The room: quiet; speakers 1 to 2 m from the Mac, equidistant; AirPods and phone
   away; 5 GHz Wi-Fi, lid open, on mains; no Game Mode (moves Bluetooth latency 70 to 90 ms).
8. Nothing else may use that Mac during the blocks. It is also the remote test
   Mac; "Starting it tonight" says when to take its test permits away.

### Device ids

A Bluetooth id is the speaker's own hardware address with dashes plus
`:output` (`54-2A-1B-79-08-9E:output`), so it is the same on every Mac. An
AirPlay id is a colon-separated address; `--list-devices` marks the AirPlay entry
that shares a Move's address as that Move's Wi-Fi side. The alignment store
(`bt-sync-trims.json`) is per Mac, so the wizard has to run on the second Mac.
The driver refuses, by name, an id that neither that store nor `telemetry.jsonl`
has seen. No telemetry line carries an id and a name; names come from blueutil.

### Why it starts inside the logged-in session

macOS grants Microphone, Automation (one app scripting another) and Bluetooth
access to the app that started a process. A process started over ssh has no
logged-in session and never gets a prompt. So `launch-tonight.sh` loads a
one-shot LaunchAgent into `gui/$(id -u)` (the logged-in user's launchd domain)
that opens Terminal, which holds the grants from step 5, to run the driver.

## Rehearsal: `--smoke`

In the room, run `./unattended-night.sh --smoke` (same flags as the night): the
real run, relaunches included, with Block A 2 min (disconnect at minute 1), Block
B 20 s / 30 s / 20 s, Block C 2 min. Its summary starts with "SMOKE".

## The watchdog

Every 60 s during a block the driver writes one line to `status.log` and to
Terminal:
`OK <block> <time> rec=<bytes> rms=<dBFS> clicks=<n> clock_lines=<id:count,...> load=<load1>`.
Checks: the recording grew; the mic level over the last 10 s is above -80 dBFS;
`click-pair-spacing.py` finds at least 8 clicks in the last 30 s (not while Block
B is paused); every selected Bluetooth speaker logged `bt_clock_deviation` in the
last 90 s; the load is under 4. A failing check writes `ALERT <block> <time>
<check> <value>`; three in a row on one check write `ABORT` and end the block.
Then `BLOCK-START`, `BLOCK-END` and `DONE`. Before Block A a 20 s probe runs the
checks once and any ALERT stops the run with what to fix. The QuickTime recorder
has no file until it stops, so its mic and click checks show `n/a`.

Watch from another Mac (the driver prints the folder at start):

```
ssh alechamilton@SUMUP-M9Y197RFVG.local tail -F '<results path>/status.log' | grep --line-buffered -E 'ALERT|ABORT|BLOCK|DONE'
```

Your main Claude session can run that under a monitor and push a phone notification per line.

## Starting it tonight

In Terminal on the second Mac (Screen Sharing is fine), from `dev/listening`:

```
./launch-tonight.sh 23:30                 # Blocks A and B, about 35 min
./launch-tonight.sh 23:30 --with-airplay  # adds Block C, about 1 h 40 min
```

It runs `--check` first (missing tool, empty or unknown id, build without the
reconnect setting), loads `~/Library/LaunchAgents/com.audiout.listening-night.plist` with
`launchctl bootstrap`, and keeps the Mac awake with `caffeinate -dims` until the
agent fires, removes itself and runs the driver. It prints how to cancel.

Then, and never before the driver starts, on the development Mac:

1. At "Block A started at <time>; set remoteSlots to 0 on the dev Mac now" (in
   `driver.log`), run `git config audiout.remoteSlots 0`; tests then run locally, no wait.
2. At "Block C started", `git config audiout.remoteSlots 1` only if tests must keep flowing.
3. After the run ("done; set remoteSlots back to 2"): `git config audiout.remoteSlots 2`.

## The results folder

`results/<date>_<time>/`:

- `summary.md`: per block, the offsets from `click-pair-spacing.py` (Block B:
  before the pause, right after resume, one minute after; Blocks A and C: linear
  fit and jump count), counts of each telemetry line, the `bt_clock_deviation`
  slope per speaker, the load, and runbook 2's interpretation table.
- `blocks.tsv`: per block, telemetry byte offsets at start and end, marks
  (seconds into the recording) and ids.
- `block<X>-raw.wav` or `.m4a` (the recording), `block<X>.wav` (16-bit),
  `block<X>.txt` (the script's per-period output), `block<X>-telemetry.jsonl`
  (the block's lines matching `bt_clock_jump|bt_sink_anchored|bt_sink_release_overshoot|bt_sink_seek_clamped|tap_feed_gap|bt_clock_deviation|drift_window_result|drift_window_dropped|drift_correction|bt_room_term_changed|room_delay_changed`).
- `load.csv`: once a minute, time, block, 1-minute load from `uptime`, busiest
  process; `summary.md` gives each block's max and mean and warns above 4.
- `status.log` (the watchdog), `driver.log` (every step with times),
  `notes.txt` (skips, fallbacks and early block ends).

## What it does not cover

- M1 Part 1 sections 2 to 4 (drawer stepper, reselect, wizard, Try again, reset):
  they need a person at the popover.
- Listening by ear; the mic measures offsets only. M1 Part 3 (PR #228): the 950 ms store edit, steps 3 to 5, questions (a) and (b).
- Fix 7's PostHog check; runbook 1 Runs A and C; runbook 2 Part B (the drift meter).
- The minute between blocks: the mic records only while a block runs.
