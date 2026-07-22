<!-- SPDX-License-Identifier: GPL-2.0-or-later -->
# Speaker-input responsiveness — build + gated live-test brief

**What:** make the app respond to controls pressed **on the speaker itself** —
the transport keys (play/pause/next/previous) and the speaker's own volume knob.
Before this, both were dropped inside the vendored C layer. Decisions (from the
requester): transport **controls the Mac's music** (via media keys, needs
Accessibility); volume **is built and verified on real hardware**.

## How it flows (bottom → top)

1. **C event channel** — the receiver already opens a reverse "event" channel
   (`airplay.c` SETUP `eventPort` → `airplay_events_listen`, now passed
   `session->device_id`). `sender/airplay_events.c`:
   - transport (`sendMediaRemoteCommand`) still parses as before but now reaches
     real shims instead of no-ops;
   - `volume_parse()` recognizes an inbound `SET_PARAMETER` `volume: <dB>` line
     and fires it; any message that is neither is logged (`Unhandled AirPlay
     event …`) so a live test reveals other formats.
2. **C bridge** — `shims/engine_bridge.{h,c}`: `airplayengine_remote_fire()` +
   `airplayengine_remote_event_set()` (sibling of `outputs_engine_state_set`).
   Transport is routed via the (now-live) `shims/player.c` `player_playback_*`
   shims; volume is fired straight from `airplay_events.c`.
3. **Engine** — `AirPlayEngine.makeRemoteEventStream()` → `AsyncStream<RemoteEvent>`
   (`.transport(TransportCommand)` / `.volume(OutputID, level:)`), fed by
   `RemoteEventHub` (sibling of `StateStreamHub`). Installed/torn down in
   `start()`/`stop()` around `airplay_init`/`airplay_deinit`.
4. **Backend** — `NativeBackend.subscribeRemoteEventStream()`: event-channel
   volume → `setSpeakerVolume` (moves that one device's slider AND, since the
   2026-07-22 rework below, writes the level back to the engine); transport →
   `emit(.remoteTransport(…))` (`BackendEvent`, device-agnostic). In practice
   AirPlay 2 receivers (Sonos et al) report volume over **DACP**, not the event
   channel — `DACPServer` (`NativeBackend.dacpServer`) advertises
   `iTunes_Ctrl_<DACP-ID>`, and a `setproperty?dmcp.device-volume=<dB>` or
   `volumeup`/`volumedown` callback routes through
   `applyDacpVolume`/`applyDacpVolumeStep` to the same `setSpeakerVolume` core.
5. **App** — `AudiouterApp/MediaKeyController.swift`: turns `.remoteTransport`
   into a Mac aux media key (`NX_KEYTYPE_PLAY`/`NEXT`/`PREVIOUS` via a
   `.systemDefined` NSEvent → `.cghidEventTap`). First press while untrusted
   asks for **Accessibility** once (`AXIsProcessTrustedWithOptions`).

## Headless tests (all green)

- `AirPlayEngineTests/RemoteEventStreamTests.swift` — fires the real C
  `airplayengine_remote_fire` and asserts the mapped `RemoteEvent` (volume,
  clamp, all three transport keys, UNKNOWN dropped, stream finishes on stop).
- `AudiouterCoreTests/NativeBackendTests.swift` — `testSpeakerVolumeMovesThatDeviceSlider`,
  `testSpeakerVolumeForUnknownOutputIsIgnored`, `testSpeakerTransportKeysEmitRemoteTransport`,
  plus the DACP routing/write-back/echo-guard/step-accumulation tests added in
  the 2026-07-22 rework below.
- `AudiouterCoreTests/DACPServerTests.swift` — pure request-parsing + dB↔level
  mapping tests (no sockets).

## Gated live test (needs the real Sonos + a human)

Single-instance only — PTP ports 319/320 are exclusive, so **stop any other
running copy / worktree first** (see the native-live-test-single-instance note).

**Updated 2026-07-22 — Accessibility no longer needs re-granting per build.**
Two things changed since this brief was first written:
- `scripts/make-app.sh` now AUTO-DETECTS a **Developer ID** identity in the
  keychain and signs with it by default (falls back to ad-hoc only if none is
  present) — confirm via its `==> Auto-detected Developer ID signing identity`
  line. Unlike ad-hoc, a Developer ID signature is STABLE across rebuilds, so a
  TCC grant tied to it survives a `make-app.sh` rerun.
- Onboarding/Setup's **Remote Control** row (`SetupModel.primeRemoteControl()`
  → `RemoteControlPrimer`) calls the exact same `AXIsProcessTrustedWithOptions`
  API `MediaKeyController` does — granting it there satisfies the same TCC
  entry, so a press on the speaker doesn't need its own separate first-prompt.

1. `scripts/make-app.sh` (no special flags — Developer ID auto-detected) then
   launch via **`open build/Audiouter.app`** (a shell-launched binary inherits
   the terminal's TCC identity — use `open`). Set `AIRPLAYENGINE_LOG_LEVEL`
   high enough to see `L_AIRPLAY` info/debug (the volume + "Unhandled AirPlay
   event" lines).
   - **Before testing transport**, confirm Remote Control is actually granted —
     it's an enhancement, not a required permission, so Setup can be "complete"
     with this row skipped. Check System Settings › Privacy & Security ›
     Accessibility lists Audiouter ON, or open the app's Setup screen and
     confirm the Remote Control row shows Granted. If not, click Allow there
     once — that grant now persists across rebuilds (see above).
2. Select the Sonos so a session is streaming.
3. **Transport:** play something (Music/Spotify/a browser). Press pause on the
   Sonos → **should pause on the first press**, no Accessibility prompt (it's
   already granted per the pre-check above); play/next/previous likewise. If a
   prompt DOES appear, the build's signature likely changed (e.g. fell back to
   ad-hoc) and invalidated the earlier grant — re-grant via Setup and treat the
   fallback itself as a bug to chase (check make-app.sh's signing-identity log
   line).
4. **Volume:** turn the knob on the Sonos (or in the Sonos app). Expected: that
   speaker's slider in the popover follows. Watch the log:
   - `'<name>' set its own volume to X (0..1)` → parser works; confirm the slider
     matches and the dB→level mapping feels right.
   - `Unhandled AirPlay event … (N bytes)` → the Sonos reports volume in a shape
     `volume_parse` doesn't handle yet. Bump `AIRPLAYENGINE_LOG_LEVEL` to debug
     for the hex dump, decode it, and extend `volume_parse` accordingly.
   - **nothing at all** on a knob turn → this Sonos model may not report volume
     back over the event channel; that half isn't available via this path and
     would need a different mechanism (out of scope until confirmed).

## Rework after first live test (2026-07-22): close the volume loop

First live test refuted the "report" model: a full swipe on the Sonos moved our
slider only ~5 points (vs ~20 in the Sonos app) and every new swipe re-based on
the same stale level. Root cause: **the sender owns AirPlay volume.** A
speaker-side swipe is a DACP *request* ("set device-volume to X dB"); the
speaker's audible level only changes when the sender writes the value back out
(SET_PARAMETER). We were treating it as a report — slider moved, nothing was
written back — so the Sonos's baseline never advanced and swipes could neither
complete nor accumulate.

Fix (this worktree):
- `NativeBackend.setSpeakerVolume` now moves the slider **and** pushes the level
  to the engine (`pushVolume` → SET_PARAMETER). Loop safety: a same-value
  inbound (a receiver reflecting our own write) is dropped before the push, and
  the −30…0 dB ↔ 0…100 map is linear both ways so round-trips are
  rounding-stable. Swipe bursts coalesce in `pushVolume` (latest wins) instead
  of being dropped by the old `volumeInFlight` guard.
- Relative `volumeup`/`volumedown` DACP verbs are now implemented
  (`DACPServer.onVolumeStep` → `applyDacpVolumeStep`): step ±2 UI points from
  the level the app currently holds, so presses accumulate. Step size is a
  guess pending live calibration.

## Second live test — PASSED (2026-07-22, Sonos Move 2)

The reworked loop was live-verified working, and the log confirms every part of
the design (`/tmp/audiouter-speaker-input.log`, `AIRPLAYENGINE_LOG_LEVEL=4`):

- **Wire format confirmed:** the Sonos reports its own volume as an absolute
  DACP `GET /ctrl-int/1/setproperty?dmcp.device-volume=<dB>` (NOT the RTSP
  `volume:` event-channel line the original hypothesis guessed, and NOT the
  relative `volumeup`/`volumedown` verbs). Example:
  `[dacp] request cmd=setproperty token=1963900746 query=["dmcp.device-volume": "-20.700001"]`.
  So `applyDacpVolume` (absolute) is the live path; `applyDacpVolumeStep`
  (relative) stays a safety net for receivers that use the other verbs, unused
  by the Sonos.
- **Write-back loop working:** every genuine change is followed by
  `[airplay] Sending volume … to 'Move 2'` + `set_volume_one: Sending
  SET_PARAMETER (volume)` — i.e. the speaker's request moves our slider AND is
  written back out, which is the whole fix. A full knob sweep tracked the entire
  range smoothly (−20.7 → −26.7 dB in 0.6 dB steps) instead of the old
  ~5-point cap.
- **Echo/same-value guard working in the wild:** the Sonos re-sends the same dB
  several times in a row (it's chatty — 91 DACP requests in one short session);
  each repeat is logged by `[dacp] VOLUME` but produces NO `[airplay] Sending
  volume`, because `setSpeakerVolume`'s `guard pct != known[id]?.volume` drops
  it. No ping-pong feedback observed.

Transport was likewise fine (pause on the speaker paused the Mac on the first
press — Accessibility already granted via Setup, no prompt). **Net: the feature
works end-to-end on real hardware.** This supersedes the earlier "parked / not
working" verdict — that was the pre-rework "report" model.

Test rig: build with `AUDIOUTER_STATUS_LABEL=speaker-input
AIRPLAYENGINE_LOG_FILE=/tmp/audiouter-speaker-input.log AIRPLAYENGINE_LOG_LEVEL=4
bash scripts/make-app.sh` (those three now flow into `LSEnvironment` so an
`open`-launched bundle sees them), then `open build/Audiouter.app`. The status
label disambiguates this build from other worktrees' (shared bundle id → they
collide in LaunchServices).

## Open item — RESOLVED

The original hypothesis (receiver sends a `volume: <dB>` `SET_PARAMETER` on the
RTSP event channel) was WRONG for the Sonos: it uses absolute DACP `setproperty`
instead (see the second live test above). The event-channel `volume_parse` path
is kept for receivers that might use it, but the confirmed, exercised path is
DACP. Transport was never in doubt.
