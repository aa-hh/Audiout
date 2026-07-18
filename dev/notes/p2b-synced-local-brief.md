# Synced local Core Audio endpoint — implementation brief (T-P2B)

**The ask** (SPEC §8.1, PLAN-PHASE-2 "NEW REQUIREMENT"): in "play everywhere"
mode, the Mac's own speakers become a first-class, PTP-synced Audiouted
output — mute the live OS output (`muteBehavior = .mutedWhenTapped`, already
proven in `dev/audiocap`) and render a DELAYED local copy sample-aligned with
the remote AirPlay 2 receivers (raw local currently runs ~2s AHEAD of AirPlay's
sync buffer — observed 2026-07-13, SPEC.md:305). This brief covers the concrete
Core Audio implementation path for the delayed local sink: which scheduling API,
how to convert between clocks, how to measure output latency, how to handle
drift and device changes, and an honest v1-vs-proper split.

Read for context: `dev/notes/0e-taps-brief.md` (capture side, tap lifecycle,
mute behavior), `dev/audiocap/README.md` (what's built today), SPEC.md §4 + §8.1,
PLAN-PHASE-2.md "NEW REQUIREMENT" + T-API-1 sections, `AirPlayEngine/README.md`
(the `write(pcm:pts:)` + `LocalOutputSink` placeholder API already landed).

---

## 0. TL;DR verdict

- **The hard problem the task framing assumes ("map libairptp's PTP timeline to
  mach_absolute_time") mostly doesn't exist, because we are the grandmaster, not
  a slave.** Traced `libairptp`'s daemon (`airptp.h` + `dev/owntone-src/src/
  libairptp/src/daemon.c:105`): our PTP daemon timestamps its own Sync/Announce
  messages from **our own `clock_gettime(CLOCK_MONOTONIC)`** — it does not
  compute or expose a slave-side offset (there is no `airptp_offset_get()` or
  equivalent in `airptp.h`). The receivers (Sonos, AirPort Express, HomePod)
  slave *their* clocks to *us*. So "the PTP presentation clock" **is, by
  construction, a fixed affine function of our own local clock** — no live
  master↔local offset to track, unlike nqptp/shairport-sync (a *receiver*,
  which legitimately needs the SHM `local_to_master_time_offset` dance — see §2).
  This is the single biggest simplification available and should reframe the
  whole design.
- **The real clock-domain problem is smaller but still real: `CLOCK_MONOTONIC`
  (what libairptp/OwnTone's RTP timing math uses) vs. `mach_absolute_time`
  (what `AVAudioTime.hostTime` / Core Audio scheduling uses) are NOT the same
  clock on Darwin.** `CLOCK_MONOTONIC` keeps ticking across system sleep;
  `mach_absolute_time` freezes during sleep (Apple TN QA1643; confirmed via
  web research, §3). They agree while awake (same tick source, fixed offset)
  but diverge across a sleep/wake cycle. A local sink scheduled in `hostTime`
  must be re-anchored after wake — see §5.4.
- **The engine already has the right seam.** `AirPlayEngine.write(pcm:pts:)`
  (`AirPlayEngine/Sources/AirPlayEngine/AirPlayEngine.swift:403`) takes a
  `timespec pts` documented as "the capture clock's timestamp for A/V sync,"
  and `LocalOutputSink`/`setLocalOutputEnabled` (lines 450–458, 564–570) is a
  **placeholder surface already shaped for this** — "TODO: implement a Core
  Audio output unit driven off the same PTP-derived clock." This brief tells
  that TODO what to actually do.
- **Recommended API: `AVAudioSourceNode` (or `AVAudioPlayerNode.scheduleBuffer
  (at:)`) with `AVAudioTime(hostTime:)`, NOT a raw HAL IOProc.** `hostTime`
  gives sample-accurate scheduling across the local output timeline (Apple's
  own guidance: use `hostTime`, not `sampleTime`, for cross-node/cross-context
  sync — Apple Developer Forums thread on `AVAudioTime`, §3). A raw
  `AudioDeviceCreateIOProcIDWithBlock` on a dedicated output-only device gives
  equal or better precision but forces us to reimplement format conversion,
  device hot-swap, and the render buffer pump ourselves — no accuracy win for
  meaningfully more code. Use AVAudioEngine.
- **Simplest-correct v1: fixed measured offset + periodic hard resync, no
  continuous drift correction.** Measure total output latency once (§4),
  compute a constant delay = (measured AirPlay pipeline latency − local output
  latency), schedule the delayed copy on `hostTime`, and every N seconds
  (or on xrun/underrun) re-derive the offset and re-anchor. This is honestly
  good enough: local playback drift over minutes is sub-millisecond on a Mac's
  hardware clock (no resampling needed for v1). "Proper" (continuous
  micro-rate correction) is §6/§7 and should be a v2 refinement, not a
  blocker.

---

## 1. What "sample-aligned with the AirPlay receivers" actually means

There are two different sync problems buried in one sentence, and separating
them changes the whole design:

1. **Local Mac output vs. remote AirPlay receivers** (the actual ask). The
   remote receivers already do PTP-synced, buffered playback at a ~2s
   presentation delay (AirPlay 2's `start_buffer_ms`, default 2250ms —
   seam-map.md §3.1 "`general.start_buffer_ms`... default `2250`... must exceed
   `AIRPLAY_AUDIO_LATENCY_MS`"). To align, the **local** Mac output must ALSO
   be delayed by (that same buffer window − the Mac's own much-shorter output
   latency). This is a **one-shot, mostly-static offset**, not a live PTP
   feedback loop, because:
2. **We are the PTP grandmaster for the whole system**, so there's no
   "convert PTP time → our clock" step to build. Our clock (`CLOCK_MONOTONIC`)
   *is* the reference all receivers discipline themselves to. The local sink
   never needs to ask "what time does the PTP domain think it is" — it already
   knows, because it's running on the box that defines that time.

This matters because the task brief's framing ("engine's PTP timeline ↔
mach_absolute_time... what mapping can libairptp expose?") presumes a
slave-side conversion problem that isn't there. The actual problem is:
**(a) what's the fixed delay between "when a PCM frame is captured" and "when
it comes out of a Sonos speaker," and (b) how do we schedule that same frame
to come out of the MacBook's speakers at the same wall-clock instant, expressed
in a clock domain Core Audio's scheduler understands (`hostTime` /
`mach_absolute_time`)?**

---

## 2. libairptp clock exposure — what's actually there (evidence)

Read `AirPlayEngine/Sources/CAirPlayEngine/libairptp/airptp.h` (verbatim, all
39 lines of API surface) and `dev/owntone-src/src/libairptp/src/{daemon.c,
ptp_msg_handle.c}` (the real logic; the `airptp.h`/`.c` under `AirPlayEngine/`
is the same code, vendored):

- **Public API surface** (`airptp.h`): `airptp_daemon_bind`, `airptp_daemon_
  start(hdl, clock_id_seed, is_shared)`, `airptp_daemon_find`, `airptp_peer_
  add/remove`, `airptp_clock_id_get` (returns a `uint64_t` **clock identity**
  — the grandmaster's EUI-64-derived ID advertised in Announce messages, NOT a
  time value), `airptp_ports_override`. **There is no offset/current-time
  accessor in the public header** — no `airptp_now_get()`, no
  `airptp_offset_get()`.
- **`daemon.c:105`**: `clock_gettime(CLOCK_MONOTONIC, &now)` is the sole time
  source the daemon uses to stamp outgoing Sync/Announce/Delay-Resp messages.
  There is no slave/offset-correction logic anywhere in `libairptp/src/*.c` —
  confirmed by grep (`grep -rn "offset" ptp_msg_handle.c` finds only PTP wire-
  format fields being parsed for logging, e.g. `offset_scaled_log_variance`,
  `UTC Offset`, never a locally-applied correction).
- **Conclusion: libairptp implements the PTP *master/grandmaster* role only.**
  It answers receivers' Delay_Req packets and broadcasts Sync/Announce/
  Follow_Up — it never disciplines *our* clock to anyone else's, because
  nothing else in this topology outranks us. `airptp_daemon_find()` (used if
  another process on the host is already running a compatible daemon) is the
  only "could we be a slave" seam, and OwnTone's own `ptpd.c` uses it only to
  share/reuse a bind, not to slave the sender's timing math (confirmed:
  `airplay.c`'s own RTP-timestamp math, §"3. RTP timestamps" below, uses
  `CLOCK_MONOTONIC` directly, not any PTP-corrected value).
- **What this means for the local sink:** there is no PTP "current presentation
  time" to fetch from libairptp because the presentation clock literally is
  our wall clock (mod affine transform to PTP's epoch, which we never even
  need since we don't emit absolute PTP time to ourselves). We need:
  `capture_instant (CLOCK_MONOTONIC or mach time) → fixed known delay →
  scheduled local playback instant (mach_absolute_time via AVAudioTime)`.
  That fixed delay is measured, not synchronized (§4).

### 2.1 Prior art comparison — nqptp/shairport-sync (why their problem is different)

nqptp exposes a POSIX shared-memory struct (`shm_structure` →
`shm_structure_set{ master_clock_id, local_time, local_to_master_time_offset,
master_clock_start_time }`) so shairport-sync (a **receiver**) can compute
`master_time = local_time + local_to_master_time_offset` — i.e., "what does the
sender's PTP domain currently read, translated onto my local clock." (nqptp
README via GitHub, fetched 2026-07-17: "add this to the local time to get
master clock time"; nqptp's own docs say explicitly "It is not a PTP clock" —
it's a monitor/slave.) **This SHM pattern is the right shape for a receiver
slaving to a foreign master. We are not that.** If a future requirement ever
needed us to slave to an *external* PTP grandmaster (e.g., a HomePod acting as
master in some AirPlay topologies), this is the pattern to copy — but nothing
in the current spec requires it, and building it now would be solving a
problem we don't have.

Source: https://github.com/mikebrady/nqptp/blob/main/README.md

---

## 3. `mach_absolute_time` vs `CLOCK_MONOTONIC` — the real clock-domain gap

Two clocks are in play and they are NOT interchangeable across sleep:

| Clock | Used by | Ticks during sleep? |
|---|---|---|
| `CLOCK_MONOTONIC` (Darwin) | libairptp daemon (`daemon.c:105`), OwnTone's RTP timestamp math (`rtp_common.c:544-557` `timing_get_clock_ntp`, `airplay.c:2170`) | **Yes** (Darwin's `CLOCK_MONOTONIC` counts wall-elapsed time including sleep, unlike Linux) |
| `mach_absolute_time()` / `AVAudioTime.hostTime` | Core Audio scheduling (`AudioTimeStamp.mHostTime`, `AVAudioTime(hostTime:)`, `AudioQueue` start times) | **No** — freezes during sleep (Apple TN QA1643: "this clock does not increment while the system is asleep"; confirmed independently via web search on `mach_absolute_time` sleep behavior) |

Both clocks share the same physical tick source (the CPU/timebase counter)
and the same `mach_timebase_info` numer/denom conversion to nanoseconds while
the machine is continuously awake — so **while awake, `mach_absolute_time()`
and `clock_gettime(CLOCK_MONOTONIC, ...)` differ only by a fixed additive
constant** you can measure once per process run:
```
offset_ns = (mach_absolute_time() converted to ns) - (clock_gettime(CLOCK_MONOTONIC) converted to ns)
```
Re-measure `offset_ns` after any sleep/wake (register for
`NSWorkspace.didWakeNotification`) since `mach_absolute_time` "loses" the
sleep duration relative to `CLOCK_MONOTONIC` — the affine mapping shifts by
however long the machine was asleep. **This is the actual "PTP timeline ↔
mach_absolute_time" conversion the task asked about — it's a same-machine
sleep-aware epoch reconciliation, not a network PTP slave computation**, per
§2's finding that we're the grandmaster.

Sources: Apple TN QA1643 (https://developer.apple.com/library/archive/qa/
qa1643/_index.html); `mach_absolute_time` kernel docs
(https://developer.apple.com/documentation/kernel/1462446-mach_absolute_time);
`man clock_gettime` on this machine (Darwin 23.4.0) confirms `CLOCK_MONOTONIC`
"will continue to increment while the system is asleep" vs.
`CLOCK_MONOTONIC_RAW` which does not track wall time at all (different
gotcha — do not use `_RAW` for this).

---

## 4. Measuring the fixed delay (the number that actually matters)

The local sink needs one number: **how many milliseconds after "now" should
this PCM frame come out of the Mac speaker so it lines up with when the
*same* frame comes out of a Sonos/AirPort Express/HomePod.**

Two additive pieces:

**(a) AirPlay 2 remote presentation delay** — dominated by the sender's
configured `start_buffer_ms` (OwnTone default 2250ms, per seam-map.md §3.1;
our engine should expose/confirm whatever value `AirPlayEngine` config lands
on for `general.start_buffer_ms`). This is a **known constant we set**, not
something to measure per-session — the engine picks it, so read it back from
`EngineConfig` rather than re-deriving it empirically. Confirmed empirically
2026-07-13 (SPEC.md:305): "raw local output plays ~2s AHEAD of AirPlay."

**(b) Local Core Audio output latency** — this DOES need measuring per output
device, because it varies (built-in speakers vs. a USB DAC vs. Bluetooth).
Standard Core Audio formula (Apple engineer Dan Klingler on the coreaudio-api
mailing list, confirming the documented properties):
```
total_output_latency_frames =
    kAudioDevicePropertySafetyOffset (device, output scope)
  + kAudioDevicePropertyLatency      (device, output scope)
  + kAudioStreamPropertyLatency      (the active output stream)
  [+ the driver's I/O buffer size, kAudioDevicePropertyBufferFrameSize,
     since a callback's samples don't leave the buffer until the buffer fills]
```
Convert frames → seconds via the device's nominal sample rate
(`kAudioDevicePropertyNominalSampleRate`), then → host ticks via
`mach_timebase_info`. Sources: `kAudioDevicePropertyLatency` docs
(https://developer.apple.com/documentation/coreaudio/kaudiodevicepropertylatency);
Core Audio mailing list latency-formula thread (https://www.mail-archive.com/
coreaudio-api@lists.apple.com/msg01238.html) — "Actual playback time = callback
timestamp + kAudioDevicePropertyLatency + kAudioStreamPropertyLatency."

**Net formula:**
```
local_schedule_delay = engine.startBufferMs  −  local_output_latency_ms  −  safety_margin_ms
```
Clamp to ≥ 0 (if local latency somehow exceeds the AirPlay buffer, which
shouldn't happen with typical `start_buffer_ms` ≥ 2000ms vs. built-in-speaker
latency of a few ms to a few tens of ms). A small negative `safety_margin_ms`
(e.g., schedule 10–20ms later than the exact computed instant) is standard
practice to absorb scheduler jitter without audible impact.

**This value is measured once at startup/device-change, not continuously** —
supports the "simplest correct v1" recommendation in §0/§6.

---

## 5. The scheduling API — three candidates, evaluated

### 5.1 `AVAudioEngine` + `AVAudioPlayerNode.scheduleBuffer(_:at:)` /
`AVAudioSourceNode` with `AVAudioTime(hostTime:)` — **RECOMMENDED**

- `AVAudioTime.hostTime` is explicitly the cross-context-safe timestamp:
  Apple Developer Forums thread on `AVAudioTime` (fetched 2026-07-17):
  "sampleTime is not a reliable timing strategy for cross-node
  synchronization... hostTime property theoretically gives an accurate
  timestamp that can be compared across nodes." This is precisely our case —
  the local `AVAudioEngine` output timeline vs. the moment we decided (via
  §4's math) audio should sound.
- `scheduleBuffer(_:at:options:completionHandler:)` accepts an `AVAudioTime`
  built from a `hostTime` (`AVAudioTime(hostTime: someMachAbsTimeValue)`);
  passing `nil` means "next available slot" — we must pass an explicit
  future `hostTime` to get the delay.
- For a **continuous PCM stream** (not discrete clips), prefer
  `AVAudioSourceNode(format:renderBlock:)` over repeated `scheduleBuffer`
  calls: the render block is pulled by the engine's own render thread each
  cycle, and we feed it from our lock-free ring (same pattern as `dev/
  audiocap`'s `RingBuffer.swift`, just in the reverse direction — draining
  into Core Audio instead of draining out of it). The *initial* alignment
  (when the render block starts actually emitting non-silence) is still
  established via a `hostTime`-anchored gate: hold the source node muted/
  silent until the render block's callback-provided `AVAudioTime` reaches
  the computed delayed instant, then start emitting real samples. This
  avoids needing a discrete "first buffer" scheduling call at all and fits a
  ring-buffer-fed streaming source better than repeated `scheduleBuffer`.
- **Verdict: use `AVAudioSourceNode` for the sustained stream, with the
  hostTime gate for the initial alignment; `scheduleBuffer(at:)` is simpler to
  reason about for a v1 spike (schedule buffer N, wait, schedule N+1...) but
  is a worse fit for a continuous tap-fed stream than a pull-based source
  node.** Either is sample-accurate; pick based on which is less code against
  the ring-buffer producer this project already has.

### 5.2 Raw HAL IOProc (`AudioDeviceCreateIOProcIDWithBlock` on the default
output device) — same tool already used for capture, considered and rejected
for this direction

- We already have this exact pattern in `dev/audiocap` for the **capture**
  (input) side (`0e-taps-brief.md` §3d). Mirroring it for **output** (a
  private aggregate or the real default output device, IOProc writes into
  `outOutputData` instead of reading `inInputData`) is possible and gives
  the same host-time-stamped callback semantics (`inOutputTime.mHostTime`).
- **Why not recommended:** AVAudioEngine's output path already runs an
  equivalent HAL IOProc under the hood — going raw buys no additional timing
  precision, but costs us: reimplementing format conversion (our PCM is
  S16LE 44.1k stereo per `PCMFormat.airplay`; the output device's ASBD may
  differ, same "never assume 48k/2ch" gotcha as capture, `0e-taps-brief.md`
  §0/§3b), reimplementing device hot-swap handling ourselves (§7), and losing
  AVFoundation's buffer-underrun/format-negotiation conveniences. Only
  reach for raw HAL if `AVAudioEngine` demonstrably cannot hit the precision
  bar in testing (unlikely — both ultimately ride the same HAL timeline).

### 5.3 `AudioQueue` timeline (`AudioQueueEnqueueBufferWithParameters` +
`AudioTimeStamp.mHostTime`, or `AudioQueueSetProperty` for start time)

- Legacy API, still `hostTime`-schedulable (`AudioQueueStartTime.mFlags =
  kAudioTimeStampHostTimeValid`, per Apple's QA1643 example, §3). No
  advantage over `AVAudioEngine` for a modern Swift codebase already using
  AVFoundation elsewhere (the capture side already imports `AVFoundation`
  for `AVAudioPCMBuffer`, `0e-taps-brief.md` line 9). **Not recommended** —
  no reason to add a second, older API surface when AVAudioEngine covers it.

**Decision: `AVAudioEngine` (§5.1).** It is sample-accurate via `hostTime`,
it is the modern/supported API, and it shares infrastructure (AVFoundation,
`AVAudioPCMBuffer`) with the existing capture code.

---

## 6. Drift strategy: resync vs. micro-rate-adjust

Two local clocks are involved in the *audible* alignment over time: the Mac's
own audio hardware clock (driving the local sink) and each AirPlay receiver's
hardware clock (disciplined to our PTP broadcasts). Both drift against true
time, and both drift against EACH OTHER, but:

- **The local Mac sink and the Mac's own PTP broadcasts share the same
  physical oscillator** (both derive from the same CPU/audio-clock hardware
  on one machine) — so **local-vs-our-own-PTP drift is near zero by
  construction**. There is no "our clock drifting against itself" problem.
- **The remote receivers' drift against OUR clock is exactly what PTP is
  already solving** — that's the entire point of the AirPlay 2 PTP handshake;
  it's the receivers' problem to keep disciplining themselves to us, not ours
  to solve for them.
- **What CAN drift, locally:** the local Core Audio output device's actual
  playback rate vs. its "nominal" sample rate (every audio clock has ppm-level
  error — a consumer DAC might run at 44,101 Hz when asked for 44,100 Hz).
  Over long sessions (hours), a sample-rate-fed-by-timestamp local sink that
  never corrects will accumulate a growing gap between "how many samples we
  scheduled" and "how many samples actually played," because our source feed
  (the tap) is driven by ITS OWN device clock which may differ in ppm from
  the local OUTPUT device's clock, if they're different physical devices
  (e.g., tapping a Bluetooth headset's rate while outputting to built-in
  speakers — different clock domains).

### v1 (simplest correct): periodic hard resync, no continuous correction

- Track `samples_scheduled` vs. `elapsed_wall_time × nominal_rate`. If the
  drift exceeds a threshold (e.g., ±10ms, chosen to stay below typical human
  perceptibility for a **local-only** timing artifact — this is not the
  receiver-to-receiver sync bar, just local-vs-remote, so a slightly looser
  threshold than "professional multi-room sync" is acceptable per SPEC's own
  audio-only scope), **insert or drop a few frames of silence/audio at a
  buffer boundary** (a "hard resync") rather than continuously resampling.
  A few-ms silence/skip once every several minutes is inaudible; a
  continuously varying pitch is not.
- This matches the "fixed measured offset + periodic hard resync" framing
  the task brief itself proposes as the honest v1, and is the right call:
  it's simple, it's inaudible in practice, and it avoids building a
  continuous control loop before there's any evidence one is needed.

### v2/"proper": continuous micro-rate correction

- **`AVAudioUnitVarispeed`** changes playback rate — but **links pitch to
  rate** (it's the same mechanism as `AVAudioPlayer.rate`, "chipmunk effect"
  at large rate changes). At the ppm-level corrections needed here
  (fractions of 1%), the pitch shift would be inaudible, so Varispeed is
  usable for tiny corrections — but:
- **`AVAudioUnitTimePitch`** decouples rate from pitch entirely (range
  1/32×–32× rate, independent pitch control) — strictly more correct in
  intent even though at ppm-level corrections the practical difference from
  Varispeed is inaudible either way. Prefer TimePitch since "we are literally
  trying to NOT change pitch" is exactly the invariant TimePitch guarantees
  and Varispeed only accidentally satisfies.
  Source: hackingwithswift.com AVAudioEngine rate/pitch example + Apple docs
  comparison (both fetched 2026-07-17) — Varispeed range 0.25–4.0 vs.
  TimePitch range ~0.03125–32, and "AVAudioUnitTimePitch can change rate
  without changing pitch" vs. Varispeed's linked rate/pitch.
- **Manual resampling** (feeding the source node through your own tiny
  fractional resampler, nudging effective rate by measured ppm error) is the
  most "correct" but is real DSP work for a benefit (sub-ms long-run drift)
  that's inaudible if v1's periodic-resync approach is already in place.
  **Recommendation: do not build this unless real-world testing after v1
  ships shows audible drift** — likely never, given both clocks are on the
  same machine or PTP-disciplined.

**Recommendation: ship v1 (periodic hard resync) only. Treat continuous
micro-rate correction as a "if a real problem surfaces" backlog item, not a
day-one requirement.**

---

## 7. Default-output-device changes

The local sink must react to the same class of event the capture side already
handles (`0e-taps-brief.md` §7: "Default-device changes... Register a HAL
listener on `kAudioHardwarePropertyDefaultSystemOutputDevice`... on change:
tear down and rebuild"). For the OUTPUT sink specifically:

- Listen for `kAudioHardwarePropertyDefaultOutputDevice` (note: this is the
  **output**-side property; the capture code listens on
  `kAudioHardwarePropertyDefaultSystemOutputDevice`, which is what the tap
  mirrors — the local sink should follow the SAME device the tap is silencing,
  so in practice both listeners fire together / can share one listener since
  "default system output" and "default output" are normally the same device
  unless the user has split them in Audio MIDI Setup).
- On change: (1) re-measure §4's local output latency for the NEW device
  (latency varies device-to-device — a value measured for built-in speakers
  is wrong for a freshly-connected Bluetooth speaker), (2) re-anchor the
  `hostTime`/`CLOCK_MONOTONIC` affine offset (§3) since the new device may
  have a different nominal sample rate, (3) do a hard resync (§6) rather than
  trying to carry over in-flight scheduled buffers across the device swap —
  simplest and matches the tap's own "tear down and rebuild" philosophy for
  device changes.
- **AVAudioEngine has a wrinkle here:** if bound to a specific
  `AVAudioOutputNode` tied to the system default, macOS `AVAudioEngine`
  generally auto-follows default-device changes for `.outputNode`, but the
  engine's render format can become stale across a rate change and needs
  `engine.stop()` / reconfigure `.outputNode` format / `engine.start()`. Treat
  a default-output-device-changed notification as "stop, reconfigure latency +
  offset, restart" unconditionally rather than trying to detect exactly what
  changed — this is the same "always rebuild, don't diff" posture
  `0e-taps-brief.md` recommends for the tap.
- **Sleep/wake** (§3) should trigger the same "stop, re-measure, restart"
  path even though the device didn't change, because the `mach_absolute_time`
  ↔ `CLOCK_MONOTONIC` affine offset shifted by the sleep duration. Subscribe
  to `NSWorkspace.shared.notificationCenter` for
  `NSWorkspace.didWakeNotification` (and probably `willSleepNotification` to
  proactively mute/stop rather than let the sink glitch through the sleep
  transition).

---

## 8. Interaction with the mute (`.mutedWhenTapped`) and the two documented modes

Recall PLAN-PHASE-2.md's already-decided UX (2026-07-13): **two modes**, "Mute
the Mac" (tap mute only, no local sink — the simple case, already built) and
"Play everywhere" (tap mute + this delayed local sink). Concretely:

- Both modes use `muteBehavior = .mutedWhenTapped` on the SAME tap (per
  `0e-taps-brief.md` §6 — self-heals on crash, so we never leave the user's
  Mac stuck silent if the app dies). The tap doesn't know or care whether a
  local sink is running; muting the live OS output and running our OWN
  delayed sink are orthogonal (mute happens in the tap layer, the delayed
  sink is a completely separate `AVAudioEngine` writing to the same physical
  output device).
- **Feedback-loop hazard:** the local sink writes to the (real) default
  output device. If the tap's exclude-list doesn't cover the sink's own
  process, the tap could re-capture its own delayed output, creating an
  echo/loop. `dev/audiocap`'s `--exclude` flag already solves exactly this
  for the OwnTone-pipe case (excluding the pipe-writer's own pid); the same
  pattern applies here — exclude our own process (or specifically the
  `AVAudioEngine`'s output) from the tap's `stereoGlobalTapButExcludeProcesses`
  list. This is a correctness requirement, not an edge case — get it wrong
  and "play everywhere" becomes "play everywhere, with a delayed echo of
  itself."
- Toggling modes at runtime = start/stop the local `AVAudioEngine` sink; the
  tap's mute behavior doesn't need to change between the two modes (it's
  ALWAYS `.mutedWhenTapped` since the OS's raw/unsynced local output is never
  what we want to hear in either mode).

---

## 9. Recommended approach — summary

**v1 (ship this first):**
1. On session start (or local-output-enabled toggle), measure local output
   latency for the current default output device (§4b) and read
   `start_buffer_ms` from `EngineConfig` (§4a); compute `local_schedule_delay`.
2. Build an `AVAudioEngine` with an `AVAudioSourceNode` fed by a small
   lock-free ring buffer that the SAME producer feeding `AirPlayEngine.write
   (pcm:pts:)` also feeds (i.e., one capture → two consumers: the AirPlay
   engine's `write`, and the local sink's ring). Gate the source node's
   render block silent until `hostTime` reaches `capture_instant +
   local_schedule_delay` (established via the §3 affine `CLOCK_MONOTONIC` ↔
   `mach_absolute_time` mapping), then start emitting real samples.
3. Exclude our own process from the capture tap (§8) to prevent a feedback
   loop.
4. Every N seconds (or on detected xrun/underrun), re-check drift (§6) and do
   a hard resync (silent frame insert/drop) if beyond threshold — no
   continuous rate correction.
5. On default-output-device change OR sleep/wake, tear down and rebuild the
   entire local sink (stop, re-measure §4b + §3, restart) — same "always
   rebuild" posture as the capture tap.
6. Verify by ear: Mac + one real AirPlay device, listening for the two to
   audibly align (per PLAN-PHASE-2.md's own acceptance criterion, "Verify by
   ear... once the engine can run a session").

**v2/"proper" (only if v1 shows real drift in practice):** replace step 4's
hard resync with continuous `AVAudioUnitTimePitch`-based micro-rate
correction driven by a measured ppm error between the tap's device clock and
the local output device's clock.

---

## 10. Walls / risks, ranked

1. **(Highest) The `AVAudioEngine` output path may not actually expose
   sub-buffer-accurate `hostTime` scheduling in practice on all output
   devices** — Bluetooth output devices in particular are known to have
   larger, less-precise, and sometimes non-deterministic latency reporting
   (`kAudioDevicePropertyLatency` on a BT device can be a rough estimate, not
   a hardware-measured constant). **This risk is untested — no code exists
   yet that measures real BT latency accuracy.** If BT output devices report
   garbage latency, the delayed sink will be audibly off until re-tuned per
   device family. Mitigate: measure and log actual observed vs. reported
   latency during hardware verification; consider a small user-adjustable
   fudge-factor as an escape hatch (SoundSource/Rogue Amoeba-style apps
   commonly expose exactly this kind of manual offset knob for this reason).
2. **Feedback-loop correctness (§8) is easy to get subtly wrong.** If the
   tap's process-exclude list is wired to the wrong pid/bundle (e.g., excludes
   the AirPlay engine process but the local sink runs in a different process
   or a different Core Audio client identity than expected), you get an
   audible echo that's easy to miss in a quiet test and embarrassing in
   real use. Needs an explicit test: play program audio in "play everywhere"
   mode and confirm via spectral/tone analysis (same Goertzel approach as
   `0e-taps-brief.md`'s per-app tone test) that the tap does NOT pick up the
   delayed local output.
3. **Sleep/wake and default-device-change handling is exactly the kind of
   code that's easy to skip until it bites in the field.** Both are silent
   failure modes (stale offset → local sink drifts audibly out of alignment,
   not a crash), and both require the app to have live `NSWorkspace`/HAL
   listeners wired up correctly, which is easy to under-test since a dev
   machine that never sleeps mid-session won't exercise it. Needs an explicit
   manual test pass (put the Mac to sleep mid-playback, wake it, confirm
   resync) before calling this done.
4. **(Lower, but worth flagging) `EngineConfig`'s `start_buffer_ms` must
   actually be read back by the local sink, not re-guessed.** If the two
   values (engine's real buffer config vs. whatever constant the local-sink
   code hardcodes) ever diverge — e.g., someone tunes `start_buffer_ms` later
   for a real-hardware latency finding and forgets the local sink reads the
   same config — local playback silently goes back out of alignment. Wire
   the local sink's delay calculation to read the SAME `EngineConfig` value,
   not a separately hardcoded constant.
5. **(Lower) Multi-output scenarios (aggregate/multi-output devices, or a
   user with several apps taking exclusive Core Audio ownership) could
   interact unpredictably with a second `AVAudioEngine` instance targeting
   the default output.** Not deeply investigated here — flag as an open
   question (§11) rather than a researched risk, since it's plausible but
   there's no test evidence either way yet.

---

## 11. Concrete implementation checklist (dependency-ordered)

1. **Latency-measurement helper** (`LocalOutputLatency.swift` or similar, new
   file in `AirPlayEngine` or the app layer — TBD which owns it, see open
   question below): read `kAudioDevicePropertySafetyOffset` +
   `kAudioDevicePropertyLatency` (device scope) + `kAudioStreamPropertyLatency`
   (active output stream) + `kAudioDevicePropertyBufferFrameSize` for the
   current default output device; convert frames→seconds via
   `kAudioDevicePropertyNominalSampleRate`. No dependencies — can be built and
   unit-verified (against a known device) standalone first.
2. **`CLOCK_MONOTONIC` ↔ `mach_absolute_time` affine-offset helper**: compute
   once at process start (`offset_ns = mach_ns_now - clock_monotonic_ns_now`),
   expose a `machTime(for monotonicInstant:)` conversion function. Depends on
   nothing; also standalone-testable (assert the offset is stable across
   repeated calls while awake, within measurement noise).
3. **Wire `EngineConfig.startBufferMs` (or whatever it's named) to be
   readable from outside the engine actor**, so the local sink can read the
   SAME value the AirPlay sessions use (risk #4, §10). Small API addition to
   `AirPlayEngine` if not already exposed — check current `EngineConfig`
   shape first.
4. **Build the `AVAudioSourceNode`-backed local sink** as a new small type
   (e.g. `LocalPlaybackSink`) that: takes PCM frames + a `pts`/monotonic
   timestamp per frame (same shape as `write(pcm:pts:)`'s existing
   contract — reuse it, don't invent a parallel one), buffers into a
   lock-free ring, and gates/schedules via the §3+§4 helpers. Depends on 1–3.
5. **Replace `LocalOutputSink`'s placeholder body** (`AirPlayEngine.swift`
   lines 440–458) to actually own/drive step 4's sink instead of just
   flipping a bool, keeping the same public surface
   (`localOutput`/`setLocalOutputEnabled`) so no caller-facing API changes.
   Depends on 4.
6. **Fan out the capture producer to two consumers**: today `write(pcm:pts:)`
   is the only PCM destination; add the local sink as a second consumer of
   the same capture stream (same PCM bytes + timestamp, no double-capture).
   Where exactly this fan-out lives (capture layer vs. inside
   `AirPlayEngine`) is an open question — see §12 Q1.
7. **Tap self-exclude wiring** (§8): ensure the capture tap's
   `stereoGlobalTapButExcludeProcesses` list includes whichever process
   actually renders the local sink's Core Audio output, before any real
   listening test. Verify via the Goertzel tone test pattern (risk #2).
8. **HAL device-change + `NSWorkspace` sleep/wake listeners**: hook
   `kAudioHardwarePropertyDefaultOutputDevice` + `didWakeNotification` /
   `willSleepNotification` to tear down and rebuild the local sink (§7).
   Depends on 4 (needs a sink to tear down/rebuild).
9. **Periodic drift check + hard resync** (§6 v1): a timer (or buffer-count
   heuristic) comparing `samples_scheduled` vs. expected, inserting/dropping
   a few frames at a threshold. Depends on 4.
10. **Manual hardware verification**: with a real AirPlay 2 receiver (Cinema
    or Pool) and the local sink both playing, verify by ear (per
    PLAN-PHASE-2.md's own acceptance bar), confirm no feedback-loop echo
    (risk #2), and do the sleep/wake manual test (risk #3). This is the same
    kind of user-present, PTP-port-contention-gated test the engine's own
    live-session tests already require (PLAN-PHASE-2.md "GATED LIVE TEST").
11. *(Only if #10 shows audible long-run drift)* implement `AVAudioUnit
    TimePitch`-based continuous micro-rate correction (§6 v2) as a follow-on
    task — not part of the v1 checklist.

---

## 12. Open questions for ahh (genuine decisions, not researchable)

- **Q1 — where does the fan-out to the local sink live?** Should the capture
  layer (today: `audiocap`/whatever replaces it as the native capture
  component) feed BOTH `AirPlayEngine.write(pcm:pts:)` AND the new local sink
  directly (two consumers at the capture layer), or should `AirPlayEngine`
  itself own the local sink internally and tap its OWN internal PCM stream
  right after `write()` receives it (one consumer at the capture layer, engine
  internally forks)? The `LocalOutputSink` placeholder's location (inside
  `AirPlayEngine.swift`) suggests the latter was the original intent, but
  that means the engine needs a live Core Audio output dependency it didn't
  need before (currently it only touches the C sender cluster + libevent —
  no AVFoundation). Architecturally cleaner to decide before building step 6.
- **Q2 — is a user-adjustable manual offset "fudge factor" in scope for v1?**
  Given risk #1 (Bluetooth/exotic output devices may misreport latency),
  apps like SoundSource commonly expose a manual ms-offset slider as an
  escape hatch. Worth deciding now whether that's a v1 nice-to-have or firmly
  deferred, since it changes whether the local sink's delay is ONLY the
  computed value or computed-value-plus-user-override from day one.
- **Q3 — how tight does "sample-aligned" need to be, concretely?** This
  brief assumed a ±10ms-ish perceptibility bar for the LOCAL-vs-REMOTE case
  (looser than professional multi-room-to-multi-room sync, since it's "Mac
  speakers next to you" vs. "Sonos in another room," where small timing
  differences are physically less noticeable than phase-cancellation-prone
  same-room multi-speaker setups). If ahh wants tighter (or is fine with
  looser), that changes the drift-check threshold in §6/checklist item 9 and
  possibly whether v2 (§6) needs to be pulled forward.
