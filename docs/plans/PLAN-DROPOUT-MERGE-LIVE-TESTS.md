# Plan — Dropout-investigation merge candidate: live test checklist (owner-only)

Status: **NOT YET RUN.** Branch `claude/dropout-merge-5c2a1f`, tip `6da525f` (worktree
`.claude/worktrees/dropout-merge-5c2a1f`). This branch reconciles
`claude/audio-dropout-investigation-5c2a1f` (F-SETTLE, F-REBIND, F-REANCHOR flush recovery,
make-before-break tap rebuild, `DefaultOutputDeviceMonitor` consolidation, new send-scheduling/
write-cadence/aggregate telemetry) with `main` at `866a8e0` (catch-all process attribution,
generalized echo guard, one-role-per-speaker, the per-app takeover gate, launch-reset). All code
committed, hermetic suites green. These are the LIVE gates that only the owner can run — Claude never
plays or captures audio. **This doc does not instruct anyone to merge.** After all steps pass,
report results and give the merge go-ahead separately.

## Prerequisites (once per session)

1. **Check for a stale build in another worktree or `/Applications` first** — native audio uses
   exclusive PTP ports 319/320; only ONE `Audiout.app` can live-test at a time.
   ```
   find .claude/worktrees -name Audiout.app
   ```
   `/Applications/Audiout.app` is the owner's live build — **do not overwrite it.** If you need to
   run this worktree's build side-by-side with an installed copy, give it its own identity so
   the two don't collide on bundle id or PTP daemon registration:
   ```
   APP_NAME=AudioutDropoutMerge BUNDLE_ID=com.audiout.DropoutMerge scripts/make-app.sh ./build
   ```
   Only one of the two may actually be *running* at a time regardless (PTP ports are exclusive)
   — the override just avoids LaunchServices/daemon-identity collisions if both are installed.
2. **Stale PTP helper daemons** — check before starting:
   ```
   launchctl print system 2>/dev/null | grep -oE '[A-Za-z0-9_.-]+\.ptphelper' | sort -u
   ```
   Expect only the currently-registered helper (matching whichever bundle id you're about to
   launch). If a stale label from an old build shows up, remove it:
   ```
   sudo launchctl bootout system/<label>
   ```
   The purge script (`scripts/purge-stale-ptp-helpers.sh`) is **not present in this checkout** —
   use the manual `bootout` above instead.
3. **Toolchain** (only if a build fails with an `xcrun`/SDK error): confirm `xcode-select -p`
   points at full Xcode, not CommandLineTools.
4. **Build + launch:**
   ```
   cd "$HOME/Projects/AirPlay Controller/.claude/worktrees/dropout-merge-5c2a1f" && scripts/make-app.sh ./build && open ./build/Audiout.app
   ```
   Launch via `open` **only** — a shell-launched binary inherits the terminal's TCC grants
   instead of getting its own, which breaks the system-audio capture tap. It's a menu-bar app —
   no Dock icon, no window after setup; find it top-right near the clock.
5. **TCC grants are pinned to this build's code hash.** If System Audio capture looks granted in
   System Settings → Privacy but no audio is actually captured, the grant is stale (pinned to a
   previous ad-hoc rebuild's hash). Remove it with the **−** button and re-grant — toggling the
   switch off/on does **not** fix this.
6. **Telemetry file**, used throughout this checklist:
   `~/Library/Logs/Audiout/telemetry.jsonl` (rotates to `.1` at 5 MB). Always-on, JSONL, one
   object per line with `ts`/`sid`/`cat`/`evt` plus event-specific fields, shared across every
   Audiout build on this Mac. Confirm it's writing:
   ```
   tail -5 ~/Library/Logs/Audiout/telemetry.jsonl
   ```
7. **Optional: live log windows**, one per Terminal tab, useful during steps 6 and 7 below:
   ```
   log stream --predicate 'subsystem == "com.airplayengine" AND category == "write-scheduling"'
   log stream --predicate 'subsystem == "com.airplayengine" AND category == "write-cadence"'
   ```

## Test 1 — F-SETTLE: settle window on device-change rebuilds

**What changed:** `DefaultOutputDeviceMonitor` used to fan every HAL default-output/rate
notification straight out to subscribers (the whole-system and per-app taps), so a Bluetooth
device's connect burst (four notifications in under a second while it negotiates HFP/A2DP) fired
four full tap rebuilds on transient, throwaway readings. It now delivers the FIRST notification of
a burst immediately, then coalesces anything more inside a 1.2s window to at most one trailing
delivery of whatever value actually settled.

1. Connect a Bluetooth output device (headphones or speaker) while Audiout is playing to an
   AirPlay speaker.
2. Listen through the connect.

**Expected:** at most a brief, single audio hiccup around the connect — not a stutter of several
rapid rebuilds/dropouts in the first second. Confirm in telemetry:
```
grep '"cat":"captureWS"' ~/Library/Logs/Audiout/telemetry.jsonl | tail -30
```
A single connect should show a small, bounded number of tap-rebuild/transition lines — not one
per HAL notification.

**PASS:** one clean settle, no audible multi-stutter. **FAIL:** you hear several distinct
glitches/rebuilds in rapid succession right after the connect.

## Test 2 — F-REBIND: device volume preserved across a rebind

**What changed:** a device-change rebuild that fires a session rebind (remove → re-add the
output) used to reseed the speaker to the configured connect-default volume every time, even
though the user never asked for a fresh connect — so a speaker set to, say, 80% would snap back
to the connect default (35%) on every Bluetooth-triggered rebuild. It now preserves the
in-session level across a rebind and only applies the connect default on a real user-initiated
connect (deselect → select).

1. Set an AirPlay speaker's volume to something clearly NOT the default (e.g. drag it to 80%).
2. Trigger a rebind without touching that speaker's own controls — e.g. connect/disconnect a
   Bluetooth device, or toggle the Mac's output device, while the AirPlay speaker keeps playing.
3. Listen to the speaker before and after.

**Expected:** the speaker's loudness is the SAME before and after — no jump up or down. This
respects Main Out: if Main Out was below 100 at the time, the speaker's absolute loudness stays
proportionally reduced, same as before the rebind (the code passes Main × Group × Device through
exactly once per push, so nothing double-applies or drops a stage).

**PASS:** volume unchanged by ear. **FAIL:** the speaker gets audibly louder or quieter right
after the rebind with no slider touched.

## Test 3 — F-REANCHOR / FLUSH-recovery: no accumulating latency, no UI flash

**What changed:** recovering a whole-system tap rebuild used to always tear the AirPlay session
down and rebuild it from scratch (a fresh RTSP/RTP session — the audible drop). It now tries an
in-place RTSP FLUSH first, which re-anchors the receiver's timeline without dropping the session;
only on a FLUSH failure/no-op does it fall back to the old teardown+re-add.

1. While an AirPlay speaker is actively playing, repeatedly toggle its selection or switch which
   device/route is active — at least 5–6 times in a row, a few seconds apart.
2. Listen for **click-to-sound latency** each time (how long after your action before you hear
   audio again) across the repeated toggles.
3. Watch the popover UI while you do this.

**Expected (KEY CHECK):** click-to-sound latency stays roughly flat across repeated toggles — it
should NOT visibly grow toggle after toggle (that would mean a rebind is accumulating an RTSP
teardown cost instead of the flush re-anchoring in place). Also confirm the popover does **not**
flash a "taking over" strip during these toggles, and the Mac's own system output does **not**
switch, during this test — the takeover gate now only fronts the teardown fallback, not the flush
path.

**PASS:** flat latency across repeats, no "taking over" strip, no system-output switch.
**FAIL:** latency visibly grows with each toggle, OR you see the "taking over" strip / system
output change during a toggle that should have been a plain flush.

## Test 4 — Make-before-break tap rebuild on whole-system device-identity changes

**What changed:** switching the Mac's default output device used to briefly leave the NEW device
completely unmuted before the whole-system tap's mute engaged (break-before-make: tear the old
tap down, then build the new one) — audible as a brief blast out of the new device (e.g. AirPods
disconnect → built-in speakers blast for a moment). It now builds and starts the new tap on the
new device FIRST (muting it immediately), then tears the old one down. Note: this fix applies to
the **whole-system** tap only — a later adversarial-review pass reverted the equivalent change on
the **per-app** capture path (double-capture risk there outweighed the marginal benefit), so a
per-app-only route switch does not get this improvement.

1. While AirPlay + the Mac's own speakers/headphones could plausibly both be audible, switch the
   Mac's default output device (e.g. disconnect Bluetooth headphones, or change System Settings →
   Sound output) while something is playing through Audiout's whole-system route.

**Expected:** no brief blast/leak of audio out of the Mac's local output during the switch, and a
shorter or no audible gap in the AirPlay output compared to a hard cut.

**PASS:** no local-speaker blast, no long AirPlay gap. **FAIL:** you hear a brief blast out of the
Mac's local device, or a noticeably longer gap than a single clean rebuild should take.

## Test 5 — DefaultOutputDeviceMonitor consolidation: no rebuild storms

**What changed:** the whole-system tap, the per-app tap, and `LocalPlaybackEngine`'s
default-output reaction now all read default-output identity/rate from one shared monitor instead
of each installing its own HAL listeners. This is a consolidation, not a new behavior — the check
here is that ordinary device switching still works and didn't regress.

1. Switch the Mac's default output device a few times in a row (Bluetooth toggle, Sound menu, or
   physical connect/disconnect), with Audiout routing active.
2. Watch telemetry while you do it:
   ```
   grep -E '"cat":"(captureWS|capturePA)"' ~/Library/Logs/Audiout/telemetry.jsonl | tail -40
   ```

**Expected:** each switch behaves normally (device switching still works, per Tests 1 and 4
above) and produces a bounded number of transition/rebuild lines per switch — not a runaway,
ever-growing stream of rebuilds for a single switch (a storm).

**PASS:** normal behavior, bounded telemetry per switch. **FAIL:** rebuild lines keep appearing
long after you stopped switching devices, or CPU (Activity Monitor → coreaudiod) stays elevated
well after the switch settled.

## Test 6 — New instrumentation actually emits

**What changed:** this branch adds three new telemetry event families that previously did not
exist in production output at all. Their mere *presence* in the log after ordinary use is itself
the pass condition — there is no separate behavior to judge by ear here.

1. Select an AirPlay device and play audio through it for at least 15–20 seconds (send-scheduling
   telemetry polls every ~5s while capture is active, so give it time to fire at least once).
2. Check the telemetry file:
   ```
   grep '"evt":"send_sched"' ~/Library/Logs/Audiout/telemetry.jsonl | tail -5
   grep -E '"evt":"(write_cadence_drift|write_backlog_drop)"' ~/Library/Logs/Audiout/telemetry.jsonl | tail -10
   grep -E '"evt":"aggregate_(create|destroy)"' ~/Library/Logs/Audiout/telemetry.jsonl | tail -10
   ```

**Expected:**
- At least one `send_sched` line appears (this event was previously dead code and NEVER emitted
  in production before this branch — seeing it at all is the pass).
- `write_cadence_drift` events appear with `"path":"wholeSystem"` when you're on the whole-system
  route (this is a new path; a per-app-only session won't show it). `write_backlog_drop` may or
  may not fire depending on whether the engine actually falls behind — its mere availability (not
  necessarily firing) satisfies this check; if the machine is under load, you may see it fire.
- `aggregate_create` / `aggregate_destroy` lines appear on capture start/stop.

**PASS:** all three families are present in the log after the session above. **FAIL:** any of the
three never appears despite active playback of the matching path (whole-system for
`write_cadence_drift`/`send_sched`, any capture for `aggregate_create`/`aggregate_destroy`).

## Test 7 — Arming a per-app route: exactly one whole-system rebuild, no echo

**What changed:** routing an app to "Play on this Mac" (a `.currentDevice` exception) renders that
app's audio locally, on the very output device the whole-system tap captures — a real risk of
that audio echoing back into the AirPlay mix. The merge kept `main`'s generalized echo guard
(unconditionally excludes this app's own render process from the whole-system tap's capture,
rather than an app-specific mechanism) because it's strictly broader and avoids a redundant
tap rebuild the two independent fixes would otherwise have caused together.

1. Have at least one AirPlay device selected and playing (whole-system route active).
2. Route a different app to "Play on this Mac" (`.currentDevice`) while whole-system audio is
   still playing to the AirPlay speaker.
3. Listen: does the app you just routed locally leak into the AirPlay speaker's mix?
4. Check telemetry for the rebuild count:
   ```
   grep '"cat":"captureWS"' ~/Library/Logs/Audiout/telemetry.jsonl | tail -20
   ```

**Expected:** exactly ONE `create_and_start_begin` / `create_and_start_done` pair for this single
route-arming action (not two, not zero), and the locally-routed app's audio is audible only
through the Mac's own output — NOT also coming out of the AirPlay speaker.

**PASS:** one rebuild pair, no echo. **FAIL:** you hear the locally-routed app's audio doubled
into the AirPlay speaker, OR telemetry shows more than one rebuild pair for this single action.

## After all steps

Report pass/fail per numbered test (1–7). If everything passes, discuss merging separately —
passing this checklist is not itself authorization to merge.
