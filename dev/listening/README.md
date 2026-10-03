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

Before each block the driver quits Audiout Dev, writes the selection into the
dev-only defaults key `audiout.devSelectOnLaunch`, sets the Mac's output volume
to 50, relaunches with `open`, waits 60 s for the Bluetooth clocks to settle, and
checks that `routing.json` holds exactly the wanted speakers.

**The key is gone from main.** Commit e75068b5 (2026-09-20) deleted it, and the
integration build does not have it either. A real run checks the app binary for
the key and stops with that message until a build carries it again. A restored
key must replace the selection: every launch selects This Mac, and the old key
only added to that, so Block A would have played on This Mac too.

## One-time setup on the second Mac

1. From the repo root on your Mac, copy the scripts and the runbook files,
   keeping their layout, outside Desktop and Documents (that Mac's Desktop is iCloud-synced):
   ```
   tar -cf - dev/listening/*.sh dev/listening/README.md dev/notes/bt-sync-discovery/runbooks \
     | ssh alechamilton@SUMUP-M9Y197RFVG.local 'mkdir -p ~/audiout-listening && tar -xf - -C ~/audiout-listening'
   ```
2. Install the dev build under `~/Applications`, from the checkout whose `build/` holds it. Copying through the
   iCloud-synced Desktop adds extended attributes that break the code signature,
   so stream it and strip them:
   ```
   tar -C build --no-xattrs --no-mac-metadata -cf - "Audiout Dev.app" \
     | ssh alechamilton@SUMUP-M9Y197RFVG.local 'mkdir -p ~/Applications && tar -xf - -C ~/Applications && xattr -cr ~/Applications/"Audiout Dev.app"'
   ```
   Open it once at the screen and grant its own prompts.
3. Pair and connect both Moves. Run the wizard once on each, so both have a
   stored alignment.
4. `brew install blueutil ffmpeg`, then `python3 -m pip install numpy` (or point
   `PYTHON=` at a Python that has numpy).
5. Grant permissions once while you are there, in Terminal, from
   `~/audiout-listening/dev/listening`:
   - `./unattended-night.sh --dry-run` and click Allow on every prompt:
     Microphone, "Terminal wants to control QuickTime Player", and Bluetooth (for
     blueutil). The run takes about 2 minutes. If its summary has no
     "DRY RUN FALLBACK" note, the mic and QuickTime work.
   - `osascript -e 'tell application id "com.audiout.Audiout.dev" to quit'` and
     click Allow on "Terminal wants to control Audiout Dev".
6. `./unattended-night.sh --list-devices`, then paste the ids into the top of
   `unattended-night.sh` (`MOVE1_ID`, `MOVE2_ID`, `AIRPLAY_ID`) or pass
   `--move1`, `--move2`, `--airplay-id`.
7. The room: quiet; speakers 1 to 2 m from the Mac and the same distance from
   it; AirPods and phone off or out of range; the Mac on 5 GHz Wi-Fi, lid open,
   on mains; no full-screen game (Game Mode moves Bluetooth latency by 70 to 90 ms).
8. Nothing else may use that Mac during the blocks. It is the remote test Mac
   (`audiout.remoteHost`), so on your own Mac run
   `git config audiout.testPrefer local` for the night and
   `git config audiout.testPrefer permits` the next morning.

### Device ids

A Bluetooth id is the speaker's own hardware address with dashes plus
`:output`, for example `54-2A-1B-79-08-9E:output`, so it is the same on every
Mac. An AirPlay id is a colon-separated address. A Sonos Move shows up as both:
`--list-devices` marks the AirPlay entry that shares a Move's address as that
Move's Wi-Fi side. The alignment store (`bt-sync-trims.json`) is per Mac, which
is why the wizard has to run on the second Mac. The driver refuses an id that
neither that store nor `telemetry.jsonl` on this Mac has ever seen, and names
it. No telemetry line carries both an id and a name; `--list-devices` takes
names from `blueutil --paired`.

### Why it has to start inside the logged-in session

macOS gives Microphone, Automation (one app scripting another) and Bluetooth
access to the app that started a process. A process started over ssh has no
logged-in session behind it and never gets a prompt, so it cannot record or
drive QuickTime. `launch-tonight.sh` therefore installs a one-shot LaunchAgent
in `gui/$(id -u)` (the logged-in user's launchd domain) that opens Terminal at
the chosen time and runs the driver there, and Terminal holds the grants from
step 5.

## Starting it tonight

In Terminal on the second Mac (Screen Sharing is fine), from `dev/listening`:

```
./launch-tonight.sh 23:30                 # Blocks A and B, about 35 min
./launch-tonight.sh 23:30 --with-airplay  # adds Block C, about 1 h 40 min
```

It first runs `unattended-night.sh --check` and refuses to schedule on a missing
tool, an empty or unknown id, or a build without the select key. Then it writes
`~/Library/LaunchAgents/com.audiout.listening-night.plist`, loads it with
`launchctl bootstrap`, and starts `caffeinate -dims` so the Mac stays awake until
the start. When the agent fires it removes itself and runs the driver under its
own `caffeinate -dims`. It prints the cancel command.

## The results folder

`results/<date>_<time>/`:

- `summary.md`: per block, the offsets from `click-pair-spacing.py` (Block B:
  before the pause, right after resume, one minute after; Blocks A and C: linear
  fit and jump count), counts of each telemetry line, the `bt_clock_deviation`
  slope per speaker, and runbook 2's interpretation table.
- `blocks.tsv`: each block's telemetry byte offsets at start and end, marks
  (pause, resume, disconnect, reconnect, in seconds into the recording) and ids.
- `block<X>-raw.wav` or `.m4a` (the recording), `block<X>.wav` (16-bit),
  `block<X>.txt` (the script's per-period output), `block<X>-telemetry.jsonl`
  (the block's lines matching `bt_clock_jump|bt_sink_anchored|bt_sink_release_overshoot|bt_sink_seek_clamped|tap_feed_gap|bt_clock_deviation|drift_window_result|drift_window_dropped|drift_correction|bt_room_term_changed|room_delay_changed`).
- `driver.log` (every step with times), `notes.txt` (skips and fallbacks).

## What it does not cover

- M1 Part 1 sections 2 to 4: the drawer stepper, deselect and reselect, the
  wizard runs, Try again, and the reset log line. All need a person at the popover.
- Listening by ear in any block. The mic measures offsets; nobody hears an echo.
- M1 Part 3 (PR #228): editing the stored latency to 950 ms, steps 3 to 5, and
  questions (a) and (b).
- Fix 7's PostHog check in "Afterwards".
- Runbook 1 Run A (skipped by M1 too) and Run C (the 11-minute pause).
- Runbook 2 Part B, the drift meter on `claude/bt-multi-spike`.
- The minute between blocks: the mic records only while a block runs.
