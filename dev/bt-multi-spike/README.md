# bt-multi-spike — macOS Bluetooth multi-device feasibility spike

A throwaway CLI tool for testing whether multiple Bluetooth speakers can be pinned to distinct `AVAudioEngine` instances and driven concurrently from macOS, and where the setup falls apart under load. This answers the four critical feasibility questions:

1. **Do N concurrent BT-pinned engines stay alive + audible?** (kernel scheduler, device routing, no silent failures)
2. **Where do dropouts start as speakers are added?** (find the practical ceiling)
3. **Can per-device delay nudges align different brands by ear?** (synchronization headroom)
4. **Is the clock drift tolerable?** (rough rate offset, "beating" on the tone)

This is **NOT** production code — it is a diagnostic for the mixed-brand multi-Bluetooth design decision. See the main codebase's memory for context: `/Users/alechenderson/.claude/projects/-Users-alechenderson-Projects-AirPlay-Controller/memory/MEMORY.md`, key doc: "Multi-Bluetooth feasibility".

---

## Build

Prerequisite: macOS 14.4+ (Bluetooth device enumeration via Core Audio).

```sh
cd dev/bt-multi-spike
swift build -c release
# binary: .build/release/bt-multi-spike
```

**No external dependencies.** Uses only Apple frameworks (AVFoundation, AudioToolbox, Darwin/termios).

If `swift build` hits a sandbox EPERM on caches, re-run with the sandbox disabled.

---

## Usage

### List paired/connected Bluetooth output devices

```sh
.build/release/bt-multi-spike --list
```

Output:
```
bt-multi-spike: Bluetooth output devices:
  id=12345 name="Sonos One" uid=Sonos-XXXXXX
  id=12346 name="HomePod mini" uid=D41D-XXXX
  ...
```

**Prerequisite:** Devices must be **paired and connected in macOS System Settings** first. The tool does NOT pair — it only enumerates already-connected devices. See "Prerequisites" below.

### Self-test (no hardware required)

```sh
.build/release/bt-multi-spike --selftest
```

Runs flow-proof against the **built-in output device** (macOS internal speaker or HDMI): pins one `BTOutputEngine`, streams a tone for ~2 seconds, and asserts the render tap actually fired and delivered non-zero RMS samples. Exits with status 0 (PASS) or 1 (FAIL).

**What this tests:** confirms the audio graph wiring (player → delay → mixer → output) actually pushes samples to the device, not just that `setDeviceID` and `engine.start()` return success. False-success cases (wrong device ID silently accepted, route drops to nowhere) are caught here.

### Drift self-test (no Bluetooth hardware required)

```sh
.build/release/bt-multi-spike --drift-selftest
```

Validates the **hardware DAC clock reading mechanism** on the built-in output device: confirms that each device's DEFINITIVE real-DAC-clock reads (`mSampleTime` and `hostTimeNanos`) advance monotonically over a ~10-second window, and the measured effective rate lands within a sane band of the device's own nominal rate. This proves the drift readout infrastructure works on this Mac, but does NOT measure real clock offset (that requires two actual Bluetooth speakers running simultaneously). Exits with status 0 (PASS) or 1 (FAIL).

**What this tests:** the drift mechanism uses two query paths:
- **Primary (query):** `AudioDeviceGetCurrentTime()` reads the device's own real-time DAC clock directly.
- **Fallback (IOProc):** if the query errors, a lightweight timing-only IOProc callback measures the DAC's sample-time advance instead.

`--drift-selftest` confirms that at least one of these paths works on this Mac, and that the clock's sample-time and wall-time advance consistently. With real Bluetooth speakers, the interactive loop (`--drift-selftest` is orthogonal to it) will use whichever path succeeds and report the relative clock offset between speakers in ppm (parts per million).

### Connect probe — `--connect-probe` (BT-SPIKE-CONNECT, hardware gate)

Feasibility harness for `docs/plans/PLAN-UNIVERSAL-SYNC.md` §G: can
`IOBluetoothDevice.openConnection()` reliably restore an already-paired but
disconnected speaker — baseband link *and* the Core Audio output device
(proof A2DP actually came back) — and how long does each stage take?

```sh
# List paired devices (name, address, connected, A2DP advertisement) + TCC status:
.build/release/bt-multi-spike --connect-probe

# Full probe: baseband connect, then wait for the Core Audio output to appear:
.build/release/bt-multi-spike --connect-probe "JBL Flip 6"

# Round-trip: drop the link, then wait for the Core Audio output to vanish:
.build/release/bt-multi-spike --connect-probe "JBL Flip 6" --disconnect
```

The device argument matches the paired-device name (case-insensitive, or an
unambiguous substring) or its address (`aa-bb-cc-dd-ee-ff`, separators
optional). With no argument on a terminal it lists and asks for a number;
with no terminal (launched via `open`) it lists and exits — pass the device
as an argument in that case.

Two timed stages per connect:

1. **`openConnection()`** — restores the baseband link (20 s timeout; the
   call blocks, so a hang is reported as a timeout rather than freezing).
2. **Core Audio poll** — waits (30 s max, 0.5 s cadence) for the speaker to
   appear as a Bluetooth output device via the same enumerator `--list` uses.

`--disconnect` runs the mirror image (`closeConnection()` + wait-for-vanish)
so one live session can repeat connect → disconnect → connect cycles.

**Bluetooth TCC (~macOS 14+):** classic IOBluetooth calls are gated by the
Bluetooth privacy permission (`kTCCServiceBluetoothAlways`). A bare CLI's
grant is attributed to the RESPONSIBLE process — the app that launched it.
Depending on that app, the first Bluetooth access either prompts on its
behalf, silently returns an empty paired list, or — **verified live on this
Mac (macOS 27.0)** — TCC **kills the process outright** (SIGABRT, "attempted
to access privacy-sensitive data without a usage description") when the
responsible process's Info.plist has no `NSBluetoothAlwaysUsageDescription`.
The probe prints the current authorization status up front (read without
prompting), warns before the first Bluetooth touch when running un-bundled,
runs unbuffered so those lines survive a TCC kill, and explicitly diagnoses
the empty-list-because-denied/undetermined cases. Expect the `.app` wrapper
below to be the *reliable* path, not just a fallback.

**Fallback when the bare CLI can't get a prompt** — wrap it in a minimal
ad-hoc-signed `.app` whose Info.plist carries
`NSBluetoothAlwaysUsageDescription`:

```sh
bash make-spike-app.sh
# ALWAYS launch via `open` — a shell-launched binary (even the one inside the
# bundle) inherits the terminal's TCC context and defeats the wrapper:
open --stdout "$(tty)" --stderr "$(tty)" build/bt-multi-spike.app \
  --args --connect-probe "JBL Flip 6"
```

`--stdout/--stderr "$(tty)"` route the probe's output back to your terminal
(`open`-launched processes otherwise print to nowhere). There is no stdin
through `open`, so always pass the device as an argument.

**GOTCHA:** ad-hoc TCC grants pin to the exact binary's **cdhash**. After ANY
rebuild, REMOVE the stale grant (System Settings → Privacy & Security →
Bluetooth, the "−" button — toggling it is not enough) and let it re-prompt.

### Pacing-clock probe — `--pacing-probe` (passive; no audio out)

Empirical check of the research finding (`dev/notes/bt-output-research-2026-08-07.md`
§3): on a Bluetooth device, `AudioDeviceGetCurrentTime` reads the **host-side
BT stack's pacing clock**, not the speaker's remote DAC — and that clock is
suspected to re-anchor (jump) when the stack re-buffers, e.g. during the
fresh-connect warm-up window. The production drift loop needs to know whether
to low-pass/slew or hard re-anchor; this probe produces that data.

```sh
.build/release/bt-multi-spike --pacing-probe "JBL Flip 6" --seconds 120
```

Samples the device clock at ~1 Hz for `--seconds` (default 60) using the same
query-first / timing-only-IOProc-fallback mechanism as the drift readout,
**without ever starting an audio graph** — nothing is rendered; worst case the
fallback IOProc runs the device with silent zero-filled buffers.

Per sample it logs the rate-normalized clock position vs host monotonic time
(`dev=+0.420ms` = the device clock has gained 0.42 ms on the host since the
baseline). A step > 2 ms between consecutive samples is reported immediately
as a **JUMP** (re-anchor suspected); a backwards sample-time is reported as a
clock restart. A mid-run nominal-rate change (rate renegotiation) restarts
the measurement rather than printing garbage. The summary reports the ppm
trend per steady segment — warm-up shows up as early segments drifting
differently than late ones — plus every jump's timestamp and magnitude.

If the device is idle (no IO running) its query clock may be frozen; the
probe says so and waits. For a meaningful run, either let the IOProc fallback
engage or play audio to the speaker from another terminal (the interactive
loop) first.

### Interactive control loop (the hardware test)

```sh
.build/release/bt-multi-spike
```

Requires a **terminal (tty)** — not piped stdin. Enters raw-mode single-keypress control. Displays available Bluetooth devices and an interactive menu.

Press `1`–`9` to select a device, then use the keys below. Terminal is restored on exit (Ctrl-C, `q`, or process termination).

#### Keybindings

| Key | Action |
|-----|--------|
| `1`–`9` | **Select device** (target for next action). Displayed as device #1, #2, … |
| `a` | **Add/start** the selected device. Spawns a `BTOutputEngine` pinned to that device; begins streaming the current tone/click. On success prints device name and mode. On failure (device vanished, audio routing broke) prints the error. |
| `r` | **Remove/stop** the selected device. Stops the engine; device goes silent. Engine is deallocated. |
| `+` or `=` | **Delay +10ms** on the selected device. Use this to align different-brand speakers by ear (see "By-ear sync protocol" below). |
| `-` or `_` | **Delay −10ms** on the selected device. |
| `]` | **Volume +0.05** (0.0–1.0 scale) on the selected device. |
| `[` | **Volume −0.05**. |
| `t` | **Toggle source** (all active devices). Switches the shared tone source between: `tone` (pure 440 Hz sine wave) and `click` (short pulse train, ~100ms on/off). Live swap — no restart needed. Useful for detecting latency/echo (click) vs steady-state drift (tone). |
| `d` | **Print drift readout now.** Reads each speaker's REAL hardware DAC clock directly (query-first with IOProc fallback) over the 30-second integration window, reporting ppm offset + beat frequency at 440 Hz. Only meaningful with ≥2 active devices. Auto-printed every ~2 seconds. |
| `l` | **Reprint device list + status.** Shows which devices are active (`*` marker) and current RMS, delay, volume, rendered frames for each. |
| `q` | **Quit** (stops all devices, restores terminal, exits). |

#### Status display (automatic, every ~2 seconds)

The tool prints a line like:

```
status: [#1 Sonos One delay=0ms vol=1.00 rms=0.1234 frames=196608] [#2 HomePod mini delay=15ms vol=1.00 rms=0.0987 frames=195216]
```

Each active device shows:
- **delay**: configured delay in milliseconds (0 to +10000ms).
- **vol**: volume scalar (0.0 to 1.0).
- **rms**: RMS level since last drain (0.0–1.0, where 1.0 = full scale). Drains every status print, so stale values can't mask dropout.
- **frames**: cumulative frames rendered to that device's output tap (resets at engine start).

#### Drift readout (automatic, every ~2 seconds when ≥2 devices active)

```
drift: HomePod mini vs Sonos One (ref): 187.3 ppm  (~11.24 ms/min, beat=0.0824 Hz@440, swell every ~12.2s)
```

This is a **rough ballpark**, not a calibrated measurement. It reads each speaker's REAL hardware DAC clock directly (via `AudioDeviceGetCurrentTime` query, falling back to an IOProc timestamp if the query errors on this Mac) over a 30-second integration window. The **ppm (parts per million)** figure is the relative clock offset:

- **0 ppm:** clocks are matched (no beat).
- **Positive ppm:** device is running faster than reference device; audio sample times accumulate, causing audible beat on a tone.
- **Negative ppm:** device is running slower.

The readout also provides:
- **ms/min:** milliseconds of accumulated drift per minute of wall time (derived from ppm).
- **beat=Hz@440:** the beat frequency you hear on a 440 Hz tone (how many Hz apart the two tones land once each DAC's real rate is applied).
- **swell every ~Ns:** how often the audible beat completes one full cycle (inverse of beat frequency).

**Interpretation on a tone:**
- **< ~300 ppm** (swell slower than every ~7 seconds): **GO** criteria — imperceptible or very slow beat.
- **300–1000 ppm** (swell every ~1–7 seconds): **By-ear call** — noticeable but tolerable for some use cases.
- **> ~1000 ppm** with sign flips or obvious fast beating: **NO-GO** — suggests incompatible clock rates or a fundamental routing issue.

---

## Prerequisites: Bluetooth speaker pairing & connection

**The tool only controls already-paired/connected devices.** Before using `bt-multi-spike`:

1. **Open macOS System Settings** → Bluetooth.
2. **Pair each speaker** (Bluetooth setup dialog, one at a time).
3. **Ensure each speaker shows "Connected"** in the Bluetooth list.

Then `bt-multi-spike --list` will show them. If a speaker isn't listed, it's not connected (even if you see it in System Settings — toggle Bluetooth off/on or move the speaker closer to force reconnection).

**Connecting a speaker fires `AVAudioEngine` configuration-change events** in all running engines on that machine. The tool automatically re-stabilizes each engine, but you may see brief (< 100ms) audio artifacts as the route re-establishes. **This is normal.**

---

## Hardware test: by-ear synchronization protocol

The goal: add devices one at a time and detect where audio breaks (dropouts, latency, or sync).

### Setup

1. Start the tool: `./bt-multi-spike` (interactive mode).
2. Ensure all speakers are **paired, connected, and roughly similar distance** from the Mac (within ~1 meter).
3. Keep the Mac on mains power (not battery — power management can introduce latency).

### Protocol: 2-device alignment

1. Press `1`, then `a`. **Device #1 starts**, streams a tone (440 Hz sine).
   - You should hear a steady tone from the first speaker.
   - Confirm via status line: `rms > 0.01`, `frames > 0`.

2. Press `2`, then `a`. **Device #2 starts**.
   - You now hear **two simultaneous tones** from two speakers.
   - **Listen for echo/alignment:**
     - If the two speakers are **in phase** (tones reinforce), you hear a **single loud tone** (maybe slightly fuller).
     - If they're **out of phase** (delayed by ~0.5 cycle), you hear **phase cancellation** (thinner, hollow sound).
     - If they're delayed by >~10ms, you hear a **discrete echo** (first speaker, then repeat).

3. **Nudge device #2's delay to align:**
   - While listening, press `−` (or `-` / `_`) to reduce #2's delay, or `+` / `=` to increase it, in **10ms steps**.
   - Adjust until the two tones **blend into one**, not a hollow-cancelled sound or discrete echo.
   - The delay value when they align is the **per-device latency offset** for these two speakers (Sonos' DSP is often 20–50ms, HomePod ~80ms, raw Bluetooth DACs ~0–20ms).
   - Status line shows current delay: `delay=35ms` etc.

### Protocol: 3-device and beyond

1. With devices #1 & #2 aligned, press `3`, then `a`. **Device #3 starts**.
   - Now three tones from three speakers.
   - Listener can typically track alignment of two speakers at once; a third becomes diffuse.

2. **Align #3 to the mix:**
   - Nudge #3's delay until it sounds "together" with the other two (no obvious echo).
   - You don't need perfect phase-locking — slight delay (< 20ms) is acceptable, because the listener's ear can integrate delays <~100ms as "together."

3. **Repeat for each new device**, always nudging the newest speaker's delay to match the existing group.

4. **Expected delays (typical values):**
   - Sonos Era 100: 30–50ms.
   - HomePod mini: 70–100ms.
   - Apple TV: 30–50ms.
   - Generic Bluetooth DACs: 0–30ms.
   - Built-in Mac speaker: 0–5ms.

   If you need *absolute* sync (e.g., for video playback), per-device delays of up to ~500ms are implementable (set in the tool, or hardcoded in the production engine). **Listeners tolerate ~100ms jitter; beyond that, sync breaks.**

---

## Detection: what to listen for

### Dropouts

If any speaker goes **silent** while the others keep playing:
- **Symptom:** one speaker suddenly stops mid-tone.
- **Likely cause:** device disconnected, macOS route change, or engine crashed.
- **Diagnosis:**
  - Status line will show that device's `rms ≈ 0` and `frames` stops incrementing.
  - Run `d` to print drift — if one device is missing, you can't compute drift.
  - Verify the device is still connected: `--list` again (requires stopping the tool first, or run on another terminal).

### Echo / phase cancellation

Heard when two or more devices are running at different delays:
- **Discrete echo** (> ~10ms delay): hear the first speaker, then a repeat.
- **Hollow sound** (< ~2ms delay, opposite phase): tone thins out, sounds like two speakers fighting.
- **Comb filtering** (complex delay): rapid sweep/warble as phases interfere.

Use `+`/`−` keys to adjust delay until the echo vanishes.

### Beating / wah-wah (drift)

Heard on the **tone** (steady 440 Hz sine), not the click:
- **Symptom:** a slow, cyclic volume rise/fall, like "wah-wah" or a beating pattern.
- **Cause:** two devices' DACs are running at slightly different rates (< ~300 ppm difference is imperceptible; 300–1000 ppm is noticeable; > 1000 ppm is obvious and distracting).
- **How to measure:** press `d` to read the drift offset from each speaker's real DAC clock.
  - Drift line example: `HomePod mini vs Sonos One (ref): 187.3 ppm  (~11.24 ms/min, beat=0.0824 Hz@440, swell every ~12.2s)`.
  - This means HomePod's DAC is running ~187 ppm faster than Sonos's DAC (about 0.082 Hz faster on a 440 Hz tone).
  - **On a tone, you'll hear the beat frequency:** 0.082 Hz beat ≈ volume rise/fall every ~12 seconds (one complete swell cycle).
  - **Cross-check:** if the drift readout says beat=0.5 Hz, you should hear a strong wah-wah at ~0.5 cycles/second (period ~2 seconds).

The drift is **inherent to Bluetooth** — speakers don't share a master clock like AirPlay 2's PTP does. For mixed-brand multi-output, this is acceptable if steady-signed (same sign every time you measure) and < ~300 ppm (imperceptible to slow-but-tolerable). If signs flip wildly or exceeds ~1000 ppm with obvious fast beating, the hardware combination may not be compatible.

### Silence on startup (built-in-only issue)

If you start the tool but hear nothing, even though status shows `rms > 0` and `frames > 0`:
- **On built-in Mac speaker:** internal speaker is routed but muted in System Preferences (e.g., volume slider set to 0, "mute" key pressed).
- **On Bluetooth:** device is connected but in standby (move it closer, or tap its power button to wake).
- **Route issue:** Bluetooth device doesn't appear in `--list` output, or `setDeviceID` succeeded but the device isn't being opened by the OS.

Use `d` to confirm `frames` are incrementing (engine is running). If frames increment but you hear nothing, check macOS volume and device standby.

---

## GO/NO-GO rubric

Decision gates, tied to the four feasibility questions:

### GO criteria (proceed with multi-BT production engine design)

✓ **Question 1 — N concurrent engines stay alive + audible**
  - At least **3 Bluetooth devices** added simultaneously play audio without dropout.
  - Status line shows `rms > 0.01` and incrementing `frames` for all active engines.
  - At least one 2-minute run with 3 devices all active.

✓ **Question 2 — Dropout ceiling (where setup breaks)**
  - Identify the **maximum number of simultaneous devices** that avoid dropout.
  - Example: 4 devices stable, 5 devices start dropping → ceiling is 4.
  - **GO if ceiling ≥ 3** (production scenario: Mac + 2–3 speakers typical).

✓ **Question 3 — Per-device delay alignment by ear**
  - Successfully align **2 or more devices** within **< 20ms** using the `+`/`−` nudge keys.
  - Aligned sound should **blend** (no discrete echo or hollow cancellation).
  - Use **click** source (`t` key) to hear delay more clearly than on a tone.

✓ **Question 4 — Drift tolerance**
  - Drift readout (press `d` with ≥ 2 devices) shows each pair's offset is **steady-signed** (same sign across repeated measures).
  - Offset is **≲ ~300 ppm** (beat slower than every ~7 seconds at 440 Hz).
  - On the **tone**, beating is **imperceptible** or **very slow** (swell every ~7+ seconds) during a 2-minute play-through.
  - **Note:** --drift-selftest proves the mechanism on the built-in device, but only real Bluetooth hardware confirms the relative numbers and whether your BT stack accepts the lightweight query vs needs the IOProc fallback.

### Wave 0 spike gates (PLAN-UNIVERSAL-SYNC §G — Alec checkpoint after each)

**BT-SPIKE-CONNECT — GO means all of:**

- [ ] On ≥ 2 speaker brands: `--connect-probe <device>` succeeds end to end —
      `openConnection()` returns success AND the Core Audio output device
      appears within ~10 s.
- [ ] Repeatable: ≥ 3 connect → disconnect → connect round-trips per device
      (`--disconnect` then plain) with **no System Settings visit** in between.
- [ ] TCC behavior recorded: which macOS version gates it, whether the bare
      CLI prompted (and which app the prompt named), and whether the `.app`
      wrapper prompted/behaved correctly when launched via `open`.

**NO-GO** (any of): `openConnection()` hangs or fails; the audio endpoint
doesn't re-appear without a Settings trip; behavior differs wildly by brand.
Consequence per the plan: production BT-CONNECT is **not built** — ship the
`x-apple.systempreferences:com.apple.BluetoothSettings` deep-link + nudge
instead. Either way: written finding + go/no-go, **Alec checkpoint before
BT-CONNECT**.

**Pacing-clock probe (not a plan gate — informs the BT drift-loop design):**

- [ ] ppm trend + jump count/magnitudes recorded on ≥ 2 brands, including one
      fresh-connect run (the warm-up window is where the Apple stack's latency
      is documented to decay over the first ~20–30 min).
- [ ] Verdict written down: are jumps rare and bounded (a low-pass/slewing
      drift loop suffices) or frequent/large (the loop MUST have a hard
      re-anchor path, same lesson as the FLUSH re-anchor work)?

### NO-GO criteria (design is not feasible at this time)

✗ **Any engine crashes or hangs** when a device is added (tool exits, freezes, or logs an error).

✗ **Dropout begins at ≤ 2 devices** (too fragile for production).

✗ **Delay nudges have no effect**, or speaker remains out of sync despite large delay adjustments.

✗ **Drift sign flips wildly** across repeated measures, or **≳ ~1000 ppm** with obvious fast beating (swell every ~1 second or faster), suggesting incompatible clock rates or a fundamental routing issue.

---

## Example run (successful 3-device test)

```sh
$ ./bt-multi-spike
bt-multi-spike — interactive control
devices:
  1. Sonos One  uid=Sonos-XXXXXX
  2. HomePod mini  uid=D41D-XXXX
  3. Generic BT DAC  uid=USB-XXXXX

keys:
  1-9  select a device by number ...
  (full help omitted)

[select] #1 Sonos One
a
[add] #1 Sonos One started (mode=tone)
status: [#1 Sonos One delay=0ms vol=1.00 rms=0.1234 frames=196608]

[select] #2 HomePod mini
a
[add] #2 HomePod mini started (mode=tone)
status: [#1 Sonos One delay=0ms vol=1.00 rms=0.1234 frames=262144] [#2 HomePod mini delay=0ms vol=1.00 rms=0.0856 frames=65536]
drift: HomePod mini vs Sonos One (ref): 142.5 ppm  (~8.55 ms/min, beat=0.0627 Hz@440, swell every ~16.0s)

(hearing heavy phase cancellation — tones are out of phase)
+
[delay] #2 HomePod mini -> 10ms
(hearing slight improvement)
+
[delay] #2 HomePod mini -> 20ms
(hearing the tones blend — aligned!)

[select] #3 Generic BT DAC
a
[add] #3 Generic BT DAC started (mode=tone)
status: [#1 Sonos One delay=0ms vol=1.00 rms=0.1234 frames=393216] [#2 HomePod mini delay=20ms vol=1.00 rms=0.0856 frames=262144] [#3 Generic BT DAC delay=0ms vol=1.00 rms=0.1089 frames=65536]
drift: HomePod mini vs Sonos One (ref): 142.5 ppm  (~8.55 ms/min, beat=0.0627 Hz@440, swell every ~16.0s)
drift: Generic BT DAC vs Sonos One (ref): 58.7 ppm  (~3.52 ms/min, beat=0.0258 Hz@440, swell every ~38.8s)

(adjusting #3 delay)
-
[delay] #3 Generic BT DAC -> -10ms
+
[delay] #3 Generic BT DAC -> 0ms
+
[delay] #3 Generic BT DAC -> 10ms
(all three now blend well)

(run for 2 minutes, all devices stay active, no dropouts)
d
drift: HomePod mini vs Sonos One (ref): 142.5 ppm  (~8.55 ms/min, beat=0.0627 Hz@440, swell every ~16.0s)
drift: Generic BT DAC vs Sonos One (ref): 58.7 ppm  (~3.52 ms/min, beat=0.0258 Hz@440, swell every ~38.8s)

(all drifts ≲ 300 ppm, steady-signed; beating barely audible; well within GO criteria)

q
[quit] stopping all devices...
```

**Outcome:** ✓ GO — 3 devices stable, alignable by ear, drift imperceptible.

---

## Troubleshooting

**Q: Tool crashes or hangs on `a`**
- Check System Settings → Bluetooth — ensure device is still connected.
- Device may have disconnected or entered a low-power state. Move it closer to the Mac or tap its power button.
- If crash persists on a device that was working, restart the tool and try `--list` to confirm the device is still enumerated.

**Q: Status shows frames incrementing but I hear no audio**
- Check macOS volume (not muted, volume slider not at 0).
- Device may be muted (press its mute/volume button).
- Verify device is selected in System Settings → Sound → Output Device. Some Bluetooth devices don't auto-route.

**Q: Drift readout shows "not enough data yet"**
- Need ≥ 2 active devices for drift calculation. Add another device first, then press `d`.
- Also need at least 30 seconds of simultaneous playback before the first drift figure appears (that's the integration window over which DAC-clock offset is measured). Wait ~30 seconds after starting the second device, then press `d` again.
- If you still see "not enough data", the DAC-clock query may have errored and the IOProc fallback hasn't fired yet; wait a few more seconds and try again.

**Q: Delay nudges don't help — speakers still sound out of sync**
- Large delays (> 100ms) are normal for some devices. Keep nudging; you may need ±50–100ms per speaker.
- Check that both devices are actually playing (status line shows `rms > 0.01` for both).
- Try the `click` source (`t` key) — short pulses make delay/echo more obvious than a steady tone.

**Q: Tool exits unexpectedly or terminal is messed up**
- Terminal corruption (no echo, no line buffering) can happen if Ctrl-C is pressed during raw-mode I/O. Run `stty sane` to restore.
- Tool should always restore terminal on exit, but a hard crash may not.

---

## Design & limitations

- **Single machine only.** Both Bluetooth and the Mac's audio engine are local; multi-machine sync is out of scope (that's where AirPlay 2's PTP comes in).
- **No audio input.** The tool generates tones; it does not tap or process any audio input.
- **No pairing.** Devices must be pre-paired in System Settings.
- **Rough drift estimate.** The drift calculation reads each device's REAL hardware DAC clock (via `AudioDeviceGetCurrentTime`, falling back to an IOProc timestamp if the query errors) over a 30-second integration window. Different Bluetooth stacks and device drivers have different accuracy; use it as a ballpark, not a calibrated measurement. The fallback path's fired-callback timestamps are inherently jittery, so if your Mac only supports the IOProc path, expect ±5–10% noise on the final ppm figure.
- **N ≤ ~6 realistic.** macOS thread scheduler, Bluetooth bandwidth, and device driver quality degrade beyond ~4–6 simultaneous streams. This is a hardware/OS limitation, not the tool's.

---

## Code structure

- `main.swift`: CLI argument parsing, interactive control loop, terminal I/O (raw mode via termios).
- `BTDeviceEnumerator.swift`: Core Audio device enumeration, filtering for Bluetooth output devices.
- `BTOutputEngine.swift`: AVAudioEngine instance pinned to a single device; audio graph wiring (player → delay → mixer → output); render tap for RMS/frame counting; real-DAC/pacing-clock reader.
- `ToneSource.swift`: Shared 440 Hz sine tone and click pulse generators (non-real-time buffer synthesis).
- `FlowCheck.swift`: Self-test runner, drift monitor.
- `ConnectProbe.swift`: BT-SPIKE-CONNECT harness — IOBluetooth paired listing, timed connect/disconnect round-trip, TCC diagnosis.
- `PacingProbe.swift`: passive ~1 Hz pacing-clock sampler — ppm trend + jump detection.
- `make-spike-app.sh`: wraps the built CLI in a minimal ad-hoc-signed `.app` (Bluetooth TCC attribution fallback); launch via `open` only.
- `Package.swift`: SwiftPM manifest.

---

## Further reading

- **Main codebase memory:** `/Users/alechenderson/.claude/projects/-Users-alechenderson-Projects-AirPlay-Controller/memory/MEMORY.md` — "Multi-Bluetooth feasibility" doc for the original design questions and trade-offs.
- **Production reference:** `AudiouterCore/Sources/AudiouterCore/LocalPlaybackEngine.swift` in the main checkout — pattern for device pinning, config-change handling, and AVAudioEngine lifecycle (do NOT copy code; study the approach).
