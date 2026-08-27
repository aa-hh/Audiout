# audiocap — system-audio capture CLI (Core Audio process taps)

A standalone SwiftPM executable that captures **all system audio** via a Core Audio
process tap (macOS 14.4+) and writes raw interleaved Float32 PCM to a file and/or
stdout. This is the T-0e-2 spike tool; it feeds the 0f capture→OwnTone pipeline.

It is deliberately **separate** from `AudioutCore` (which pins macOS 14).
This package targets `.macOS("14.4")` because the tap API is 14.2+/14.4-public.

## Build

```sh
cd dev/audiocap
swift build -c release
# binary: .build/release/audiocap
```

No external dependencies (argument parsing is hand-rolled; the ring buffer uses
`OSMemoryBarrier`, not swift-atomics). If SwiftPM hits a sandbox EPERM on its
caches, re-run the build with the sandbox disabled.

## Usage

```
audiocap [SINK...] [TARGET] [--duration <s>] [--mute-local]
audiocap --selftest
```

**Sinks** (one or more; default = verify-only, bytes discarded):

| Flag | Meaning |
|------|---------|
| `--out <file.pcm>` | Write raw captured **Float32** PCM to this file. |
| `--stdout` | Write raw **Float32** PCM to **stdout** (for piping). Diagnostics go to **stderr**. |
| `--pipe <fifo>` | **S16LE bridge (T-0f-2):** convert to S16LE interleaved and write to a named FIFO (OwnTone pipe input). `open()` **blocks** until OwnTone reads the pipe. See "Pipe mode" below. |

**Target** (at most one; default = whole system):

| Flag | Meaning |
|------|---------|
| `--pid <n>` | Tap **only** this process id (single-app capture, `stereoMixdownOfProcesses`). |
| `--bundle <id>` | Resolve a running app's bundle id (e.g. `com.spotify.client`) to its pid via `NSRunningApplication`, then tap only that app. |
| `--exclude <p[,p...]>` | Global tap of **everything except** these pids (`stereoGlobalTapButExcludeProcesses`). The feedback-loop guard: exclude the playback process (e.g. shairport) so capture→playback doesn't loop. Global-tap only; **not** combinable with `--pid`/`--bundle`. |

**Other:**

| Flag | Meaning |
|------|---------|
| `--duration <sec>` | Auto-stop after N seconds. Default: run until **SIGINT** (Ctrl-C). |
| `--mute-local` | Silence local playback while tapping (`.mutedWhenTapped`, self-heals on crash). Default is `.unmuted` (you still hear audio locally). |
| `--selftest` | Run the float32→S16LE conversion checks (**no TCC, no audio**) and exit 0/1. Safe to run from any shell. |
| `-h`, `--help` | Show help (on stderr). |

`--pid`, `--bundle`, and `--exclude` translate pids to Core Audio process object
IDs via `kAudioHardwarePropertyTranslatePIDToProcessObject`. **A pid must have
opened an audio stream** to translate — start playback in the target app first, or
translation fails with a clear error.

On start it prints the tap's **actual ASBD** (sample rate / format flags / channels /
bytes-per-frame) to stderr. **Never assume 48 kHz** — the rate follows the current
default *output* device. On this machine it was observed as **44100 Hz** (see below).
A per-app tap's ASBD may differ from the global tap's — it is printed too.

### Output format

Raw **interleaved Float32 little-endian** PCM at the tap's sample rate and channel
count. The tap may deliver non-interleaved planar buffers internally; the tool
interleaves them so the output is always standard interleaved PCM. Play back with:

```sh
ffplay -f f32le -ar 44100 -ch_layout stereo captures/test.pcm     # adjust -ar to the printed rate
# or convert to a wav:
ffmpeg -f f32le -ar 44100 -ac 2 -i captures/test.pcm out.wav
```

The tool also prints a built-in silence check at the end
(`peak|sample|` + a NON-SILENT / ALL SILENCE verdict), so you don't need a separate
analyzer to know whether real audio was captured. `rms.py <file.pcm> [channels]` is
included for a second opinion (RMS + dBFS), and `rms.py --tones ...` does Goertzel
tone detection for the per-app / exclude PASS/FAIL test (below).

## Pipe mode (`--pipe`) — S16LE bridge to OwnTone (T-0f-2)

`--pipe <fifo>` captures (global tap, honoring `--exclude`), converts the interleaved
Float32 tap stream to **raw headerless S16LE interleaved** (scalar clamp+scale, no
dither), and writes it to a named FIFO with a **blocking writer thread** fed by the
same lock-free ring buffer the file/stdout sinks use. The realtime IOProc never
touches the FIFO or does conversion — it only enqueues Float32 into the ring.

- **FIFO open blocks:** `open(fifo, O_WRONLY)` blocks until OwnTone opens the read
  end. audiocap opens on the writer thread, so the main thread stays responsive and
  a signal still tears everything down. It logs `opening FIFO ... (blocks until
  OwnTone reads)` then `FIFO open — OwnTone attached` when a reader appears.
- **Backpressure / not-draining:** if OwnTone stalls, `write()` blocks, which lets
  the upstream ring fill; on overflow the ring **drops the oldest bytes and counts
  them** (reported at exit) so the audio thread never blocks. Keep OwnTone draining.
- **Clean EOF:** on stop the writer drains the ring, then `close()`s the fd so
  OwnTone sees end-of-stream (it suspends to `pause` — see the pipe brief).
- **SIGPIPE** is ignored process-wide; a closed reader surfaces as an `EPIPE` write
  error that stops the writer with a clear message (not a crash).

### SAMPLE-RATE SYNC IS MANDATORY (config-follows-tap)

OwnTone does **not** autodetect the pipe rate. `library { pipe_sample_rate }` in
`dev/owntone/etc/owntone.conf` **must equal the tap's sample rate**, or playback is
silently **pitch-shifted** (not garbled). The tap rate follows the default output
device; on this machine it is **44100**, so `pipe_sample_rate` is now **44100**
(lowered from 48000 by this task; OwnTone was restarted). `audiocap --pipe` prints
the exact `pipe_sample_rate = <rate>` line to set on every run. **If the tap rate
ever changes, update the config and restart OwnTone.** No resampler is used (Q4).

## TCC / permissions — READ THIS

Capturing system audio requires the **system-audio-capture** TCC permission.

- The usage string (`NSAudioCaptureUsageDescription`) is baked into the Mach-O at
  link time via `-sectcreate __TEXT __info_plist` (a bare SwiftPM executable has no
  Info.plist). This is already wired up in `Package.swift`.
- **There is no public pre-flight API.** The permission prompt fires **lazily** the
  first time the tap is created/started. Approve it, then re-run.
- The grant appears in **System Settings → Privacy & Security → Screen & System
  Audio Recording**, listed under this binary (or its parent terminal identity).
- **Symptom of "not yet granted":** the tap is created successfully and the IOProc
  fires with correctly-sized buffers, **but every sample is zero** (silent capture).
  The tool detects this and prints a clear ALL-SILENCE warning. A non-empty `.pcm`
  file is therefore **not** sufficient — check the peak/RMS.
- **Rebuild-loses-grant gotcha:** this CLI is ad-hoc (linker) signed, so its TCC
  identity is per-binary and can **reset after every `swift build`**. If capture goes
  silent right after a rebuild, re-approve. Its TCC identity is the binary name
  `audiocap`, *not* the `CFBundleIdentifier` — so `tccutil reset AudioCapture
  com.audiout.audiocap` will fail; use the un-scoped reset:
  ```sh
  tccutil reset AudioCapture      # reset the grant for all apps, to re-test the prompt
  ```
  **This task (T-0e-3/T-0f-2) rebuilt the CLI, so the grant is reset — ahh must
  re-grant before the verification runs below.** The exact copy-paste re-grant +
  test commands live in `dev/notes/0e3-0f2-verify.md`.

## Per-app & exclude verification (T-0e-3) — the tone test

Deterministic PASS/FAIL without acoustic judgment: play two pure tones from two
`afplay` processes (440 Hz and 880 Hz), then check which frequencies the capture
contains via Goertzel (`rms.py --tones`):

- **Per-app (`--pid`):** tap only the 440 Hz process → the `.pcm` must contain
  440 Hz and **not** 880 Hz → `rms.py --tones cap.pcm <rate> 440 880` prints PASS.
- **Exclude (`--exclude`):** global tap excluding the 440 Hz process → the `.pcm`
  must contain 880 Hz and **not** 440 Hz → `rms.py --tones cap.pcm <rate> 880 440`
  prints PASS.

`rms.py --tones` downmixes to mono, runs Goertzel at both frequencies, and requires
the "present" tone to exceed the "absent" tone by ≥8× (and clear a noise-floor
minimum). Full copy-paste procedure: `dev/notes/0e3-0f2-verify.md`.

## Reproduce a 10-second system-audio capture (the human one-liner)

Run this **in a foreground terminal at the machine** (so the TCC dialog can appear
and you can approve it). Play known audio during the window, then verify non-silence:

```sh
cd "dev/audiocap"
swift build -c release
# start a looping local sound so there is audio to capture:
( for i in $(seq 1 15); do afplay /System/Library/Sounds/Submarine.aiff; done ) &
AF=$!
.build/release/audiocap --duration 10 --out captures/cap10.pcm
kill $AF 2>/dev/null
# the tool prints its own NON-SILENT / ALL-SILENCE verdict; double-check with:
python3 rms.py captures/cap10.pcm 2
```

First run: **approve the "would like to record this computer's audio" dialog**, then
run the command again — the first (denied/pending) run captures silence.

Pipe form (PCM to stdout, diagnostics to stderr):

```sh
.build/release/audiocap --duration 10 --stdout > captures/cap10.pcm 2> captures/cap10.log
```

## Design notes

- **Lifecycle** (`TapEngine.swift`): create tap → read `kAudioTapPropertyFormat`
  ASBD → create private aggregate device (sub-tap UID = the CATapDescription UUID) →
  register IOProc → `AudioDeviceStart`. Teardown is strictly **Stop →
  DestroyIOProcID → DestroyAggregateDevice → DestroyProcessTap** (tap dies last),
  each step guarded so teardown always completes. Verified: no orphaned `Tap-*`
  aggregate devices remain after runs.
- **Realtime safety** (`RingBuffer.swift`): the IOProc does no allocation, locking,
  or logging. It interleaves (if needed) into a preallocated scratch buffer and hands
  bytes to a lock-free SPSC ring buffer; a dedicated writer thread drains it to the
  file/stdout. Ring overflow drops the chunk and bumps a counter (audio thread never
  blocks) — reported at exit.
- **App Nap**: the process takes an `NSProcessInfo` activity assertion so a
  no-UI/background process isn't throttled.
