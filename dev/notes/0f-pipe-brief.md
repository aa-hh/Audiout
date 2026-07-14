# 0f-pipe-brief — OwnTone pipe input: byte contract, latency, underruns, volume API

T-0f-1 + T-0d (no-speakers revision), executed 2026-07-13 against OwnTone 29.2
(`dev/owntone/`, JSON API :3689) with the fake shairport-sync 5.1 AirPlay-1
receiver ("Dev Speaker") as the sole output. All receiver-side claims below were
verified by capturing the receiver's decoded PCM (shairport `stdout` backend →
file) and pitch-checking it with a Goertzel detector — not by ear.

## TL;DR for T-0f-2 (the pipe writer)

- Write **raw headerless S16LE interleaved stereo** to a FIFO inside the library dir.
- The rate is **whatever `pipe_sample_rate` says in owntone.conf — now set to 44100**
  to match the measured tap rate (see the T-0f-2 addendum at the bottom; was 48000).
  There is NO autodetection; wrong-rate data plays pitch-shifted.
- **Do not rely on autostart.** Start playback explicitly:
  `queue/clear → queue/items/add?uris=library:track:{id} → player/play`.
- Keep the writer ahead; a >1.5 s gap suspends playback (see Underrun).
- End of stream: OwnTone goes to `pause` (not `stop`). Send an explicit
  `PUT /api/player/stop` when capture ends — lingering paused sessions wedge
  shairport (and possibly real speakers) on the next activation.

## Exact pipe format contract

- **Encoding:** raw PCM, S16LE ("PCM16" per docs), interleaved. No header, no framing.
- **Channels:** stereo (2ch). A `pipe_bits_per_sample` config option also exists;
  16 is default — left at 16.
- **Sample rate: fixed by global config `library { pipe_sample_rate = N }`.**
  Default **44100**. Valid values per the binary's validation strings:
  44100/48000/88200/96000 ("The configuration of pipe_sample_rate is invalid: %d").
  - **Proven, not assumed:** with the default config, a 440 Hz tone written at
    48 kHz arrived at the receiver as **404.2 Hz** (= 440·44100/48000) — OwnTone
    read the bytes as 44.1k. After setting `pipe_sample_rate = 48000` and
    restarting, the same stream arrived at exactly **440.0 Hz**.
  - Conversely, 44.1k data under the 48k config arrived at **478.9 Hz**
    (= 440·48000/44100). **One global rate; not per-pipe, not sniffed.**
- **Q4 status: 48 kHz works — but only with the config set.** The plan's
  "48 kHz is a legal pipe rate, so we may skip resampling" is true *given*
  `pipe_sample_rate = 48000`, which is now in `dev/owntone/etc/owntone.conf`
  (left in place; changing it requires an OwnTone restart). OwnTone itself
  resamples to 44.1 kHz for the AirPlay-1 output (shairport negotiated
  `44100/S32_LE/2`), so the writer never needs to resample.
- **FIFO location:** must be inside a configured library directory
  (`dev/owntone/media/spike.fifo`, registered as `library:track:2`,
  `data_kind: "pipe"`, `type: "wav"`, length shows as 0).
- **`.metadata` companion:** optional; not tested. OwnTone probes for
  `<pipe>.metadata` on every playback start and logs a harmless
  `Could not open pipe for reading ... .metadata: No such file or directory`.

## Rescan requirements

- Creating the FIFO then `PUT /api/update` (HTTP 204) was sufficient; it appeared
  as a library track within ~2 s. No restart needed.
- Receiver discovery needed nothing: shairport was visible in `GET /api/outputs`
  via mDNS within seconds of starting, no rescan/restart.

## Autostart / autostop semantics (the fine print matters)

- **Autostart (`pipe_autostart`, default on):** when the pipe becomes readable,
  OwnTone's watcher starts playback. Observed working repeatedly: first PCM at the
  receiver **+0.12 s** after the first byte was written (from player state `stop`).
- **BUT autostart silently no-ops when the player's current item is already this
  pipe.** Source (`src/inputs/pipe.c`, `pipe_read_cb`): if `status.id == pipe->id`
  it returns without starting ("Pipe '%s' already playing", E_INFO — invisible at
  default loglevel). Since EOF leaves the pipe as the current item in `pause`,
  and the queue persists across restarts, we repeatedly hit runs where new data
  produced NO playback and the writer just blocked on a full FIFO (64 KB) forever.
  Rescans and FIFO re-creation did NOT fix it; a `queue/clear` + manual play +
  stop cycle or an OwnTone restart did.
  - **Consequence: treat autostart as a demo feature. The pipeline must start
    playback explicitly** (verified working even in the "wedged" state):
    ```
    curl -X PUT  'http://localhost:3689/api/queue/clear'
    curl -X POST 'http://localhost:3689/api/queue/items/add?uris=library:track:2'
    curl -X PUT  'http://localhost:3689/api/player/play'
    ```
- **Autostop is actually auto-SUSPEND:** when the writer closes (EOF) OwnTone
  keeps state `play` briefly, then logs
  `Source is not providing sufficient data, temporarily suspending playback
  (deficit=…/288000 bytes)` and goes to **`pause`** (never `stop`). Threshold =
  **1.5 s of configured pipe format** (264600 B at 44.1k, 288000 B at 48k —
  rate·4 bytes·1.5). Wall time from EOF to `pause` observed 1.5–3.9 s.
- **Resume:** writing again within a few seconds of the suspend resumed `play`
  in ~0.1 s with the RAOP session reused. BUT resume after a longer pause
  (~80 s) hit a dead session: shairport refused the new connection
  (`Classic AirPlay stream session interruption not allowed`), OwnTone logged
  `failed to activate` and **silently auto-deselected the output while keeping
  state `play`** — audio went nowhere while the API looked healthy. The app must
  watch `outputs[].selected`, not just player state.

## Latency (method stated honestly)

- **Method:** wall-clock bracketing by polling at 50–100 ms granularity: t0 =
  first byte written to the FIFO; markers = OwnTone `/api/player` state,
  shairport's RTSP `RECORD` log line, and growth of the receiver's decoded-PCM
  capture file. This measures "audio data arriving at the receiver," not
  acoustic output.
- **Numbers:** from a clean `stop`, first decoded PCM at the receiver
  **+0.12 s** after first byte (repeatable across 4 runs). One first-ever run
  (fresh rescan) took ~3.0 s to state `play`. On top of that sits the AirPlay-1
  sync buffer before sound is audible — nominally ~2 s for shairport (not
  measured acoustically here). **Practical estimate: FIFO write → audible
  ≈ 2–2.5 s, dominated by the AirPlay sync buffer, not by OwnTone's pipe path
  (~0.1 s).**

## Underrun behavior

- **Short gap (3 s writer stall, SIGSTOP/SIGCONT, live output):** absorbed.
  State stayed `play`, no OwnTone log entries, no shairport sync errors, and the
  receiver's PCM stream stayed byte-continuous (7.02 s of PCM delivered over the
  7 s window spanning the stall — OwnTone fills the hole, presumably with
  silence). No session drop.
- **Sustained slow writer (0.5× realtime):** OwnTone cycles: plays until the
  input deficit hits 1.5 s → suspends to `pause` → auto-resumes when data
  accumulates → suspends again (two suspend cycles observed in one run). Not a
  crash, but audibly it would be stop-and-go; the writer must sustain ≥1× realtime.
- **Abrupt writer kill mid-stream:** treated like EOF (suspend to `pause`), but
  repeatedly left the player with the pipe as current item → autostart wedge
  (above) and, against shairport, TEARDOWN failures (`TEARDOWN request failed in
  session shutdown`) that poisoned the NEXT activation (`No response … to
  OPTIONS`) until shairport was restarted. Real Sonos may be more forgiving, but
  0f-3's soak should expect this failure class: **always tear down with
  `player/stop`, and re-select the output if `selected` flips to false.**

## T-0d — per-output volume API (verified end to end)

The plan's predicted payload is correct. Working syntax (HTTP 204 on success):

```
curl -X PUT 'http://localhost:3689/api/outputs/117846700406551' \
     -H 'Content-Type: application/json' -d '{"volume": 85}'
```

- Scale is **0–100 per output**; `GET /api/outputs` reflects the change
  immediately. (`PUT /api/outputs/set` with `{"outputs": [ids…]}` selects the
  active output set; selection + volume persist across OwnTone restarts.)
- **Wire-verified:** each PUT produced a live RTSP `SET_PARAMETER` at the
  receiver (shairport `-vvv` log): volume 50 → −15.0 dB, 15 → −25.5 dB,
  85 → −4.5 dB, i.e. OwnTone maps 0–100 linearly onto −30…0 dB. Sent mid-stream
  on the existing session, no interruption. PUTs also succeed (204 + state
  change) when the output is deselected or the session is dead — API success is
  NOT proof audio/volume reached a device.

## Surprises / deviations from plan assumptions

1. **48 kHz needs `pipe_sample_rate = 48000` in owntone.conf** — data is
   silently pitch-shifted otherwise. Config now set (survives restarts; restart
   required when changed). SPEC §8/Q4 should record this.
2. **Autostart has a silent no-op path** (pipe already current item) — use
   explicit queue+play in 0f-2/0f-3.
3. **"Autostop" is suspend-to-pause**, and the failure mode after long pauses is
   a zombie RAOP session + silent auto-deselect while the player still says `play`.
4. `PUT /api/update` = 204 and instant; pipe indexing is trivial.
5. macOS AirPlay Receiver was ON at task start (ControlCenter held :5000/:7000;
   `748F3CBFFECB@Alec's MacBook Pro` in `dns-sd -B _raop._tcp`). Alec toggled it
   off mid-session (System Settings → General → AirDrop & Handoff), after which
   shairport bound :5000 fine. It must stay off for all fake-receiver work.
6. shairport-sync Homebrew build ignores its configured RTSP port (asked for
   5100, bound 5000) — confirms the repo README's one-instance limit.
7. The LG TV shows up as a discoverable AirPlay-2 output in `/api/outputs`; per
   decision Q6 it was never selected.

## Addendum (T-0f-2, 2026-07-13) — pipe_sample_rate lowered to 44100 (config-follows-tap)

The T-0f-1 work above set `pipe_sample_rate = 48000` on the assumption the tap ran
at 48 kHz. It does not on this machine: T-0e-2 measured the tap at **44100 Hz**
(the rate tracks the default output device, and this Mac's is 44.1k). Since OwnTone
does NOT sniff the pipe rate, a 44.1k S16LE stream under a 48k config plays
pitch-shifted (the brief above proved 44.1k data under 48k config arrives at
478.9 Hz for a 440 Hz tone).

Per Q4's "no resampler" spirit, the fix is **config-follows-tap**, not a resampler:
`pipe_sample_rate` is now **44100** in `dev/owntone/etc/owntone.conf`, and OwnTone was
restarted (admin dialog) so it took effect. The audiocap `--pipe` writer does NOT
resample — it converts Float32→S16LE at the tap's native rate and prints the exact
`pipe_sample_rate` line to set. **Invariant the future app must uphold:** whenever the
tap rate changes (a different default-output device), update `pipe_sample_rate` to
match and restart OwnTone. audiocap prints the required value on every `--pipe` run.

## State left behind

- OwnTone: **running**, queue cleared, player `stop`, **no outputs selected**,
  config now contains `pipe_sample_rate = 44100` (T-0f-2 lowered it from 48000 to
  match the tap; restarted via admin dialog, pid changes on restart).
- `spike.fifo` **left in place** in `dev/owntone/media/` (registered as
  `library:track:2`) — 0f-2 will need it; deleting it would just force another
  mkfifo+rescan.
- Fake receiver: killed; nothing bound to :5000. `dev/.run/` has stale logs.
- Scratchpad (session-ephemeral): test scripts, shairport `-vvv` logs, and the
  receiver PCM captures backing every claim above.
