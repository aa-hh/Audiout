# Cast `ioproc_to_push_ms` growth under load: discovery report

Code read: `.claude/worktrees/cast-timing-fix-r2` (PR #283, HEAD `db50e957`). All `file:line` below are in that worktree.
Data: `telemetry.jsonl` copied to this scratchpad at 22:09 local; session `C421A3ED-…` runs 19:54–20:09 UTC (21:54–22:09 local, UTC+2). Mac: MacBookPro17,1, Apple M1, 4 performance cores + 4 efficiency cores.

## Short answer

Almost all of the growth is not audio arriving late. It is two clocks being subtracted from each other.

- A captured block's `pts` is Core Audio's host time (the raw hardware tick counter, `mach_absolute_time`) plus an offset sampled once when the tap starts. The push and render instants are read from `CLOCK_MONOTONIC`.
- On macOS `CLOCK_MONOTONIC` is steered by the time daemon (`timed`, the process that keeps the Mac's clock matched to Apple's time servers through `ntp_adjtime`). The raw tick counter is not. So the gap between them grows at whatever rate `timed` sets, plus a ramp every time `timed` corrects the clock's offset.
- Measured right now on this Mac: `CLOCK_MONOTONIC` gains 19.0 parts per million (ppm) on the raw counter, which is 1.14 ms per minute. That is the "creeps ~1 ms/min".
- The ~20 ms jump at 20:02 UTC lines up with a `timed` correction logged at 22:02:03.646 local: a 23.9 ms offset correction with frequency 18.98 ppm. `age_ms` ramps up by 24 ms over the following ~40 s, then holds flat.
- The hold value used for speed matching is `age_ms − delay_line_ms`, so speed matching chases this phantom error. It went from 1 ms error at +10 ppm to 14 ms error, pinned at the +100 ppm limit, within 60 s of the correction. That moves the TV for real, by the amount of the phantom.

Real scheduling delay between the capture callback and `push` stays under ~1 ms in this session, at load averages of 12–25. The AirPlay send loop stayed on time for the same reason: nothing on its path compares the two clocks.

## (a) Path map: capture callback to `CastFeedRing.push`, and the consumer

The thread priorities in this table were read off the running app (pid 21444) with `ps -M`, which does not pause the process. Priority 97 marked `R` means a real-time thread under `THREAD_TIME_CONSTRAINT_POLICY`, the Mach scheduling policy that gives a thread a fixed period and deadline. 46 = `.userInteractive`, 37 = `.userInitiated`, 31 = default, 20 = `.utility`. Two threads sit at 97R; one carries 15.8 s of CPU time, which fits the capture callback doing the conversion and fan-out.

| # | Hop | Thread / queue | Priority | Blocking or delay risks | file:line |
|---|---|---|---|---|---|
| 1 | Capture callback (the IOProc, Core Audio's per-cycle audio callback) of the whole-system tap's aggregate device | Registered on serial queue `com.audiout.native.capture` (`.userInitiated`). The header says "All IOBlocks are dispatched synchronously" (`AudioHardware.h:1384-1388`, macOS 27 SDK). `dispatch_sync` normally runs the block on the calling thread, which is the HAL's real-time I/O thread | 97R (inferred: two 97R threads, no jitter under load). The repo disagrees with itself: the comment at `NativeCaptureCoordinator.swift:3770-3775` says the block does NOT run on the HAL thread, while `docs/plans/PLAN-AUDIO-THREAD-SCHEDULING.md:279-280` says it does | Copies every buffer into new `Data` (heap allocation) | `NativeCaptureCoordinator.swift:3763-3832` |
| 2 | `pts` stamp | same | same | `pts = mach host time + machToMonotonicOffsetNanos`. The offset is sampled once per tap start (`:3760`) and re-sampled only when it is more than 1 s off (`:4275`). **This is where the two clocks get mixed** | `:3803-3812`, `:4187-4276` |
| 3 | `handleBuffer`: snapshot read | same | same | `snapshotLock.try()`; a miss drops the buffer and never waits | `:1683` |
| 4 | Format convert (`AVAudioConverter`, 44.1 kHz in and out tonight, so format change only) | same | same | Converter's own `NSLock` (one caller); allocations | `:1698`, `:4461` |
| 5 | Leveled-app mix, Main Out EQ, tick | same | same | Mixer ring locks (bounded work) | `:1712-1734` |
| 6 | Dropped-cycle check and fill | same | same | On a gap, `queue.async` (heap allocation) plus a silence fill pushed downstream. 5 fills in this session | `:1758-1795` |
| 7 | `leveledClockLock.try()` | same | same | Non-blocking | `:1797` |
| 8 | `deliver` → AirPlay engine write (runs **before** the Cast push) | same | same | `WriteCadenceTracker`; per-write `UnsafeMutablePointer.allocate` (`AirPlayEngine.swift:1286`); `EngineThread.enqueue` takes `baseLock.lock()`, a blocking `NSLock` (`EngineThread.swift:287`), plus `event_base_once` (`malloc`). This is the one blocking lock on the path | `NativeCaptureCoordinator.swift:1940`, `AirPlayEngine.swift:1210-1330` |
| 9 | Synced-local and Bluetooth fan-outs, `referenceRing.append` (also before Cast) | same | same | Never opened `SyncedLocalSink.swift` (licence fence); comments say `try()`-only | `:1969-2004` |
| 10 | `CastFanOut.write` | same | same | `lock.try()`; reads `CLOCK_MONOTONIC` for `nowNanos` (**the second clock**) | `CastOutputManager.swift:893-907` |
| 11 | `CastFeedRing.push` | same | same | `producerLock.try()` (a miss drops the block); `PCMDelayLine.exchange` (lock-free); `memcpy`; stamps `livePts` (raw-counter based) and `pushedAt` (`CLOCK_MONOTONIC`) | `:491-530` |
| 12 | Other producers: wizard pacing queue, leveled-app fallback clock | `NativeCaptureCoordinator.wizardPacer` `.userInteractive`; `…leveledClock` `.userInitiated` | 46 / 37 when active | Not active tonight (`leveled_health` shows `rings:0`; no wizard run) | `:369-370`, `:407-408`, `:1585-1597`, `:1895-1900` |
| 13 | Consumer: server pacing timer → `CastFeedRing.render` | `DispatchSource` timer on serial `DispatchQueue(label: "CastLiveAudioServer")` at default QoS, 20 ms tick, 1 ms leeway; paced by `DispatchTime` (the raw counter) | 31 (default) | `render` takes `lock` (never shared with the producer). Allocates `[Float]` under the lock while resampling (`:668`). Stamps render time with `CLOCK_MONOTONIC` (`:477-480`). One late tick of +13 ms in this session (`pacing_phase_ms` max 33.4 at 20:02:02Z); p99 19.7 ms | `CastLiveAudioServer.swift:114, 364-389`; `CastOutputManager.swift:636-720` |
| — | AirPlay send path, for comparison | `com.airplayengine.engine` thread, `.userInteractive` (`EngineThread.swift:199`), joined to the aggregate's I/O workgroup | 46 (not real-time) | Its timing probes use `CLOCK_MONOTONIC_RAW` (`AirPlayEngine.swift:2133, 2534`), so they never see the clock steering. `send_sched` gap p99 11.7–11.9 ms all session | — |

How `ioproc_to_push_ms` is computed (`CastOutputManager.swift:611` with `:698-701`):

`ioproc_to_push = pushedAt − contentPts − delay` where `contentPts = livePts + offsetInBlock − delay`, so it equals **`pushedAt(CLOCK_MONOTONIC) − livePts(raw counter + offset frozen at tap start) − offsetInBlock`**.

- `livePts` is the capture callback's `inInputTime.mHostTime`: the capture time of the block's first frame, not the time the callback ran.
- `offsetInBlock` is how far into its 512-frame block the first rendered frame sits.

## (b) Causes of the growth, ranked

### 1. Two clocks mixed in one subtraction; `timed` steers one of them (explains the creep and the 20 ms jump)

Evidence for:
- `clockdrift.py` in this scratchpad, run for 180 s at 22:10 local: `CLOCK_MONOTONIC − CLOCK_UPTIME_RAW` (the raw counter) grew a steady +19.0 ppm (1.14 ms/min). `CLOCK_MONOTONIC_RAW − CLOCK_UPTIME_RAW` grew 0.000 ppm.
- `man clock_gettime` (this Mac) describes `CLOCK_MONOTONIC_RAW` as "unaffected by frequency or time adjustments", which by contrast means `CLOCK_MONOTONIC` is affected.
- `timed` adjustments tonight (`/usr/bin/log show --predicate 'process == "timed"'`), local time. `freq` is `freq_scaled / 65536`, in ppm:

  | local | offset | freq |
  |---|---|---|
  | 19:14 | 31.5 | 30.0 |
  | 19:30 | 35.0 | 30.0 |
  | 19:48 | 32.6 | 30.0 |
  | 20:05 | 30.8 | 30.0 |
  | 20:22 | 13.7 | 30.0 |
  | 20:40 | −15.8 | 19.1 |
  | 21:04 | −5.2 | 17.0 |
  | 21:33 | −15.7 | 11.96 |
  | **22:02:03.646** | **+23.9** | **18.98** |

  The offset is logged as `offset_us`, but the raw values (e.g. 23923039) only fit the observed ramps if they are nanoseconds, so they are shown here in milliseconds.
- Session slopes match those rates. 19:54–20:01Z: `ioproc_to_push` median rose 8.2 → 13.2 ms, about 0.7 ms/min, which is 12 ppm, the rate set at 21:33 local. 20:03–20:09Z: 37.9 → 45.8 ms, 1.3 ms/min, about 19 ppm, the rate set at 22:02 local.
- The jump is a ramp, not a step. `age_ms` holds at about 137 until 20:02:04Z, then climbs 139.8, 141.2, 143.1 … 161 by 20:02:45Z (24 ms in about 40 s, roughly 600 ppm, the kernel slewing away a 23.9 ms offset), then goes flat. It starts 1–2 s after the `timed` call at 20:02:03.6Z.
- Measures that use one clock only did not move:
  - `ring_wait_ms` (both ends `CLOCK_MONOTONIC`) stayed at 120–130.
  - `lead_ms` stayed at about 5470.
  - `write_cadence_drift.netDriftTotalSeconds` (on `CLOCK_MONOTONIC_RAW`) moved −0.025 → −0.027 across the jump.
- Effect on the controller: `errorMs = leadMs + holdMs + …` (`NativeBackend+Tone.swift:1052`), and `holdMs = ageMs − delayLineMs` (`CastOutputManager.swift:1494-1495`). `cast_speed_match` went from error 1 ms at +10 ppm (20:02:00Z) to error 14 ms at +100 ppm (20:03:04Z). A permanent 12–30 ppm steering rate eats 12–30 of the ±100 ppm budget for good, and every `timed` correction adds a 5–35 ms phantom step. Positive corrections make the TV look late; negative ones make it look early.

Evidence against:
- The owner saw the jump coincide with a test run starting. `timed` fires about every 17–29 minutes on its own, so the coincidence is plausible. Load does not change the steering rate.
- A real queueing delay would show as spread, not as a smooth ramp followed by a flat line. Within each minute, `ioproc_to_push` max − min stays 11.6–11.8 ms all session: one block (cause 2) plus the per-minute creep.

Cheap confirmation, no build:
- Line up every step in `age_ms` from the earlier sessions (`telemetry.jsonl.1`) and the second Mac's logs against `ntp_adjtime:in` lines from `log show` on the same machine. Every step should land 0–2 s after a `timed` call, with the size and sign of its offset.
- With a build: log the push instant on `CLOCK_UPTIME_RAW` next to the current field. That version should be flat.

### 2. The ~10 ms two-level alternation is a measurement split, not jitter

- `ioproc_to_push` subtracts `offsetInBlock`, and `ring_wait_ms` is `render − pushedAt`, so `ioproc_to_push + ring_wait = age` exactly.
  - Example, 20:01:40–41Z: (7.8, 129.0) and (17.8, 119.0), both with age 136.8.
- The server renders 882-frame chunks (20 ms) against 512-frame capture blocks (11.61 ms). 882 mod 512 = 370, so the frame a render starts on lands at different points inside a block, and the once-a-second sample catches it about 10 ms apart.
- Confirm: the alternation disappears if the field reports `pushedAt − livePts` with no in-block offset. Within-minute range should drop from about 11.7 ms to about 1 ms.

### 3. Real load effects: present but small, and not what moved the field

- Dropped capture cycles: 5 `tap_feed_gap cause=dropped_cycle` events in 15 minutes (19:54:58, 19:56:05, 19:56:14, 19:59:30, 20:04:35Z). Each one is a single 11.6 ms block, already filled with silence. These are real lost callback cycles (the HAL's own overloads), not queueing.
- Server pacing (consumer side, default QoS): one tick 13 ms late at 20:02:02Z (`pacing_phase` 33.4 ms against a 20 ms tick). The 80 ms standing queue absorbs it. It never touches `ioproc_to_push`.
- `fanout_drops` 0. Ring `dropped_blocks` 113 and `underrun_frames` 44100 were all logged by 19:54:19Z, at session start before the receiver's first fetch, and never moved after.
- Blocking risks that could turn into real delay under heavier load, with no sign of it tonight:
  - `EngineThread.enqueue`'s blocking `baseLock` taken on the capture thread (`EngineThread.swift:287`), with holders at default QoS.
  - `malloc` on the capture thread (`AirPlayEngine.swift:1286`, `Data(bytes:)` at `NativeCaptureCoordinator.swift:3821-3828`, `event_base_once`).
  - The `[Float]` allocation under the ring lock on the default-QoS server queue (`CastOutputManager.swift:668`).
- Second Mac (8 → 28/50/56 ms as outputs were added): not checked here. It reads like the same creep plus `timed` corrections accumulating over the session. Check its `timed` log the same way.
- Cheap confirmation: run `scripts/load-gen.sh 16 60` during a session after fixing cause 1. A real load effect would widen the within-minute spread of the corrected metric and raise `dropped_cycle` counts.

## (c) Fixes, ranked

### 1. Put every Cast timing stamp on one clock (removes causes 1 and the phantom speed-match error)

- Option A, smallest: stamp `pushedAt` (`CastFanOut.write`, `CastOutputManager.swift:905`) and render time (`:477-480`) on the same timescale as `pts`. Either carry the raw host time through, or convert with the same frozen offset.
- Option B: make the offset follow `CLOCK_MONOTONIC` by re-sampling it every buffer at `NativeCaptureCoordinator.swift:3806-3812` (two clock reads). This also changes the `pts` the AirPlay engine gets.
- Recommendation: A. It is local to Cast. B touches the AirPlay anchor and the delayed-local and Bluetooth sinks, which are risk-path code.
- Expected effect: `ioproc_to_push` flat, no 5–35 ms phantom steps every 17–29 min, and speed matching gets its 12–30 ppm back.
- Risk: none for the audio threads (one clock read already happens there). The room-delay hold values shift once by the size of the accumulated phantom. Battery: none. App Store and notarisation: none.
- Size: about 20 lines. Files: `CastOutputManager.swift`, maybe `NativeCaptureCoordinator.swift` to expose the offset.
- Also worth a follow-up: the comments at `NativeCaptureCoordinator.swift:4187-4200` say the vendored sender compares `pts` against `CLOCK_MONOTONIC`. Anything there that compares across time inherits the same 19 ppm.

### 2. Fix the metric (cause 2)

- Report `pushedAt − livePts` with no in-block offset, and add a per-second max of it so real scheduling lateness becomes visible instead of hidden in the alternation.
- Effect: a clean signal for any later priority work. Risk: none. Size: about 10 lines in `CastOutputManager.swift`.

### 3. Give the Cast consumer reserved capacity cheaply

- `CastLiveAudioServer`'s queue → `DispatchQueue(label:qos: .userInteractive)` (`CastLiveAudioServer.swift:114`). Hoist the per-render `[Float]` allocation out of the ring lock into a reused buffer (`CastOutputManager.swift:668`).
- Expected: pacing p99 stays under the 20 ms tick under load. The one 13 ms late tick goes away.
- Risk: low. `.userInteractive` steers work onto performance cores ("the system is more likely to run background tasks on lower performance cores", [Tuning your code's performance for Apple silicon](https://developer.apple.com/documentation/apple-silicon/tuning-your-code-s-performance-for-apple-silicon)). Battery: small, the work is a few hundred microseconds every 20 ms. App Store and notarisation: none, it is public API.
- Size: about 15 lines.

### 4. Real-time thread plus audio workgroup for the Cast pacing, only if a corrected measurement still shows load delay

- Apple's model for threads with their own cadence ("asynchronously, i.e. at a cadence independent of any audio hardware", `AudioWorkInterval.h` case 3, macOS 27 SDK):
  - a dedicated thread under `THREAD_TIME_CONSTRAINT_POLICY` set with `thread_policy_set`;
  - its own workgroup from `AudioWorkIntervalCreate`;
  - `os_workgroup_interval_start`/`finish` each 20 ms.
- Sources:
  - [Adding Asynchronous Real-Time Threads to Audio Workgroups](https://developer.apple.com/documentation/audiotoolbox/adding-asynchronous-real-time-threads-to-audio-workgroups)
  - [Meet Audio Workgroups, WWDC20](https://developer.apple.com/videos/play/wwdc2020/10224/)
  - Mach scheduling: [Kernel Programming Guide, Mach Scheduling and Thread Interfaces](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/KernelProgramming/scheduler/scheduler.html)
- Constraints:
  - The header says these APIs are "unavailable from Swift, because … the Swift runtime is unsafe for use on realtime threads", so it needs a C shim like `AirPlayEngine/Sources/CAirPlayEngine/shims/engine_workgroup.c`.
  - Dispatch pool threads must not be given a time-constraint policy; it has to be a thread we own.
  - `NWConnection.send` is not real-time safe, so the real-time thread should only render into a buffer and leave the socket send to a normal queue.
- Risk: highest. An overrunning time-constraint thread is demoted by the kernel. `PLAN-AUDIO-THREAD-SCHEDULING.md:199-209` already designs the guard for this. Battery: moderate, it keeps a performance core waking every 20 ms.
- Size: about 200 lines plus a shim. Files: `CastLiveAudioServer.swift`, new C shim, `CastOutputManager.swift`.

### 5. Check the existing workgroup join

Apple: "Only real-time threads can join an audio workgroup; nonreal-time threads cannot" ([Understanding Audio Workgroups](https://developer.apple.com/documentation/audiotoolbox/understanding-audio-workgroups)). The AirPlay engine thread is `.userInteractive` and shows as 46, not real-time, in `ps -M`. So its join (`EngineThread.swift:125-170`) is probably inert, as `PLAN-AUDIO-THREAD-SCHEDULING.md` risk 2 predicted. AirPlay stays on time because receivers buffer ≥250 ms and timing is sample-counted, not because of the workgroup. To check, read the `engine thread joined audio I/O workgroup` / `errno` lines in the unified log (subsystem `com.airplayengine`). No change needed for this symptom.

### Not recommended now

- Moving the capture callback off its dispatch queue, or re-policying it. The data shows it already runs without measurable delay under load average 12–25.
- `os_unfair_lock` in place of `NSLock` on the capture path. `pthread_mutex` already records an owner, so the system can boost a low-priority holder ([WWDC16 Concurrent Programming with GCD](https://developer.apple.com/videos/play/wwdc2016/720/)). The only blocking lock on the path, `EngineThread.baseLock`, shows no measurable cost tonight.

## (d) Recommended first step

1. Ship fixes 1 and 2 together: one clock for the Cast stamps, plus the metric without the in-block offset.
2. Re-run tonight's setup with `scripts/load-gen.sh 16 60` started mid-session, and keep `log show --predicate 'process == "timed"'` open alongside.
3. Pass looks like this: the corrected `ioproc_to_push` stays flat within about 1–2 ms, `timed` calls produce no step, and `cast_speed_match` ppm settles near the real capture-device drift instead of pinning at +100. That drift reads about −41 ppm from `netDriftTotalSeconds`, −0.040 s over 15 min.
4. Only then decide whether fixes 3 and 4 are needed.

Before building, a zero-cost check of the claim: match the `age_ms` steps in `telemetry.jsonl.1` against tonight's other `timed` corrections at 20:05, 20:22, 20:40, 21:04 and 21:33 local.
