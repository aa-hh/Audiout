# Code: how Audiout keeps outputs in time today, with Bluetooth as the focus

Researcher: code. Written 2026-09-26 against `aa-hh/Audiout` main at `add4251`,
`audiout-shared` and `audiout-remote` as checked out, plus the remote branches on
origin (fetched the same day). Read-only. `file:line` is main unless a commit or
branch is named. Anything I could not prove from code or a logged measurement is
marked **inferred**.

Two sibling documents already cover part of this ground and I cite rather than
repeat them:

- `/mnt/project-files/sync-architecture/sync-clock-architecture.md` ("SCA"):
  the master-clock answer, the room delay `R`, the transport table, drift
  machinery, and its Gaps 1 to 5.
- `/mnt/project-files/bt-sync-version-comparison/report.md` ("VCR"): which
  Bluetooth fixes are merged and which are not (none of the 2026-09-26 fixes are
  on main).

My depth goes to what those two do not cover: the actual data path end to end,
the Bluetooth sink's state machine and every lifecycle edge, the assumptions the
code makes about Bluetooth, and what the branches tried and dropped. Where SCA
already says it, I give one line and the section number.

Abbreviations: `BTSS` = `AudioutCore/Sources/AudioutCore/BTSyncedSink.swift`,
`NB+BT` = `.../NativeBackend+Bluetooth.swift`, `NCC` =
`.../NativeCaptureCoordinator.swift`, `NB` = `.../NativeBackend.swift`.

---

## 1. Key findings

### 1.1 The data path, end to end

**Capture.** One whole-system process tap sits in a private aggregate device
whose only sub-device, and therefore its clock, is the current default output
device (`NCC:3643-3686`). `kAudioSubTapDriftCompensationKey: true` resamples the
tap onto that device's clock (`NCC:3684`, explained at `NCC:3852-3866`).
`kAudioAggregateDeviceTapAutoStartKey: true` means the tap sleeps until an app
plays and idles again when the music stops (`NCC:3673-3678`,
`Sources/AudioutCore/AGENTS.md` "Both capture taps keep ..."). Every IOProc
buffer is stamped with its own `mHostTime`, rebased onto `CLOCK_MONOTONIC`
(`NCC:3803-3812`). That per-buffer `pts` is the one timestamp in the system.

**Holes in the feed.** `handleBuffer` measures every buffer against the end of
the previous one. A hole up to 50 ms with no rebuild behind it is a lost IOProc
cycle and is padded with silence (`NCC:1757-1792`, cap at `NCC:2230`). A hole
after a tap rebuild is padded up to 2 s (`NCC:1741-1756`, cap `NCC:2218`).
Anything longer is treated as a real pause and **not** padded. The comment at
`NCC:1759-1767` states the design constraint plainly: "every sink is fed by
sample count. `BTSyncedSink` reads a pts only for its first buffer, and the
sender anchors packet time to samples too". Lost cycles happen about once per
40 s with a third Bluetooth link on the radio (same comment, live 2026-09-14),
which is the first sign that Bluetooth radio load feeds back into capture
timing.

**Fan-out.** The converted block goes to the AirPlay engine, the Mac's own
`SyncedLocalSink`, the Bluetooth manager `BTSyncedSink.enqueue` (`BTSS:1687`),
and the Cast feed (`NCC:1987-2002`). The Bluetooth manager fans the same block to
every per-device sink that per-app routing has not claimed.

**AirPlay.** The vendored sender re-maps RTP time to the host `pts` on every
write (`AirPlayEngine/Sources/CAirPlayEngine/sender/airplay.c:2248-2274`,
`timestamp_set`), and the PTP helper is grandmaster on the same host clock. When
the tap idles, the sender's own idle fill writes zeros at exactly real-time rate
from the last `pts` (`shims/outputs.c:307-320`, `:531-567`). So AirPlay keeps a
sample count that stays tied to wall time through a pause. (SCA §2.)

**Bluetooth sink (per device).** `BTDeviceSink` (`BTSS:485`) owns one
`AVAudioEngine` pinned to the speaker's Core Audio device with
`auAudioUnit.setDeviceID` before the first start (`BTSS:771`), an
`AVAudioSourceNode` rendering at 44.1 kHz into the main mixer, and a wait-free
frame ring `BTFrameRing` of at least 11 s (`BTSS:628`, rounds up to 2^19 frames =
11.9 s at 44.1 kHz). It refuses aggregate and virtual devices, because
AVAudioEngine silently no-ops on them (`BTSS:758-770`).

The sink's life:

1. **Anchor.** The first `enqueue` after a (re)start records that buffer's `pts`
   and computes `target = pts + delay` (`BTSS:930-950`). Every later buffer's
   `pts` is ignored: the ring holds bare frames.
2. **Hold.** The render block rebases the cycle's `mHostTime` onto the same
   monotonic clock (`BTSS:1138-1140`) and stays silent until the cycle that
   contains `target`, releasing at the exact frame inside it
   (`SyncTiming.plan`, `SyncCore.swift:86-100`).
3. **Catch up.** If the engine started late (A2DP `engine.start()` can take over
   half a second), the overshoot's worth of frames is skipped so playout starts
   pts-true (`BTSS:1249-1256`, doc above it).
4. **Play.** From then on the ring is drained FIFO through the shared
   `FractionalResampler` at a hard-coded `ratio = 1.0` (`BTSS:1176-1179`). No
   phase error is computed and no rate correction is applied. The sink does not
   know again which `pts` it is playing.

The delay is `max(0, R − L + trim)` (`BTReferenceTimeline.delayNanos`,
`BTSS:66-83`), with `R` from `btReferenceDelayMs()` or the BT-only buffer
(`NB:3815-3834`, SCA §3), `L` the stored measured latency, and `trim` the user's
nudge. Once released, the delay IS the audio sitting in the ring
(`Sources/AudioutCore/AGENTS-HISTORY.md:44-66`). A trim or latency change moves
the read pointer behind a 5 ms equal-power crossfade (`BTDelayLine`,
`BTSS:260-450`; `applyTrimDelta`, `BTSS:1062-1112`). A forward move stops 100 ms
short of the write pointer (`seekSafetyMarginMs`, `BTSS:556`) and logs
`bt_sink_seek_clamped`.

**Mac's own speakers.** `SyncedLocalSink` has the same anchor and hold, plus a PI
loop that compares content position with wall time every cycle and steers the
resampler within ±200 ppm (`SyncedLocalSink.swift:785-802`, gains in
`SyncCore.swift:319-374`). Its latency comes from the HAL formula
(`LocalOutputLatency.swift`: safety offset + device latency + stream latency +
buffer size) plus a 3 ms margin (`SyncedLocalSink.swift:49`).

**Cast.** Cast plugs in as another fan-out sink (`setCastSink`, `NB+BT:487`)
with its own `PCMDelayLine` (`CastOutputManager.swift:266`). Its lead feeds a
`max` into `R` (`CastRoomDelay.swift`, `NB:3815-3819`). When Cast is present,
AirPlay is pre-delayed by `R − S` (`setAirPlayPreDelay`, `NB+Tone.swift:1004`),
and every BT sink's delay grows to match. The 11 s ring exists to cover Cast's
9.5 s ceiling (`BTSS:624-628`). The cast researcher owns the depth here.

### 1.2 Where each Bluetooth number comes from

| Quantity | Source in code | Trust |
|---|---|---|
| Timebase | Host `CLOCK_MONOTONIC`, per capture buffer (`NCC:3812`) | Exact (SCA §1) |
| `R` with AirPlay or Cast present | `_startBufferMs` (default 1000; options 1000, 1500, 2250, `AppSettings.swift:127-130`), maxed with the Cast term | Exact, but blind to BT latency (SCA Gap 1, VCR §3 item 6) |
| `R`, BT-only | `max(500, slowest measured L + 100)` (`NB+BT:178-182`); 2000 during a wizard run (`NB+BT:170`) | Exact |
| `L` (per speaker) | Stored measured latency: phone probe, Mac mic probe or by-ear wizard, persisted by UID (`BTTrimStore`), re-pushed on every arm (`NB+BT:427-440`) | Good right after a measurement; re-rolls 20–90 ms per stream start (bt-latency-stability research §1) |
| `L` for a speaker nobody measured | **0.** The HAL figure is read and logged once per connect (`bt_device_reported_latency`, `BTSS:770-780`) and never used, not even as the "seed" the plan called for (PLAN-UNIVERSAL-SYNC §B) | Plays `L_real` late (100–400 ms) until calibrated |
| Trim | ±500 ms, 1 ms resolution (`BTTrimStore.swift:23,32`) | User's ear |
| Clock health | `AudioDeviceGetCurrentTime` polled at 1 Hz by `BTClockWatcher` (`BTClockStability.swift:155-250`): jump > 2 ms, steady after 10 s jump-free, lost baseline at ≥ 1 s | Sees the host-side pacing clock only, not the DAC |
| Codec | Nothing. `BTSpeakerTiming`'s `codec` closure defaults to `nil` and the comment says no `bluetoothaudiod` codec line has been seen in the unified log (`BTSpeakerTiming.swift:171-178`) | Unknown |
| Absolute-volume capability | AVRCP SDP record (`BTAbsoluteVolumeSDP.swift:19-57`) AND the volume property settable (`NB+BT:30-88`) | See §1.7 |

### 1.3 Drift and re-timing: what exists, what is inert

- **Rate drift, BT:** none by decision. The sink comment (`BTSS:468-471`) and
  `dev/notes/per-device-trim-spec.md:44-49` rest on one 120 s acoustic run on
  2026-08-12: Sonos Move vs Sony WH-1000XM3, inter-speaker drift −0.02 ppm
  (commit `efb67775` on `origin/claude/bt-multi-spike`, tool `b35b8737`). The
  planned `BTDriftCorrector` was deleted as "inert" because it servoed the
  host-side pacing clock against itself (per-device-trim-spec Part 3c). Note what
  the −0.02 ppm figure does and does not cover: it is **BT against BT**, both fed
  from the same capture. It says nothing about BT against AirPlay or against the
  Mac's speakers, which run on different time references (see 1.4). SCA Gap 3
  already flags the thin evidence.
- **Discrete jumps, BT:** the pacing-clock watcher and the passive mic tracker
  **detect**. Only the tracker **corrects**, by writing a new measured latency
  and seeking (`NB+BT:1228-1270`), and only when two measured BT speakers are
  selected, or one plus an AirPlay anchor (`NB+BT:1152-1154`). Its cadence: first
  window at 180 s, then every 1500 s, plus reconnect (+15 s), clock step
  (rate-limited to one per 60 s per speaker), and a silence→audio edge after
  60 s of silence (`PassiveDriftSampler.swift:392-421`). The `audioModeChange`
  trigger is declared (`PassiveDriftSampler.swift:352`) but **no code ever fires
  it**. Per VCR §3 item 4, the tracker has never corrected live end to end and
  scored under 1 against a gate of 3 in the customer's room.
- **Uneven device pulls:** on main, nothing. The unmerged `ed6f00a`
  (`origin/worktree-agent-a2a761b2a16d4c277`) adds `realignToDevicePulls`. It
  compares wall time since release with the frames the device has pulled and
  seeks, with a crossfade, once they are 20 ms apart. VCR §1 row 1 covers its
  status (a replay test held within 16 ms; never heard on real speakers).
- **Mac speakers:** PI loop, ±200 ppm (above).
- **Cast:** skip/insert when the error passes 150 ms (SCA §5.1).

### 1.4 Assumptions the code makes about Bluetooth, and whether each holds

Ranked by how much sync each one can cost.

| # | Assumption (where) | Reality | Cost when false |
|---|---|---|---|
| A1 | **The ring's frames are contiguous in `pts` from the anchor on**: frame *k* was captured at `anchorPts + k/44100` (`BTSS:930-950`; the capture comment at `NCC:1759-1767` states it). | False whenever the capture feed has a hole the padder does not fill: a pause over 50 ms that idles the tap (`NCC:1769-1778` says this "happens every time the music stops"), a producer chunk dropped on a full ring (`BTSS:180-184`, counted but not compensated), and a tap rebuild hole over 2 s. | **Inferred, needs a live check (§4 Q1).** After a pause long enough to drain the ring (≥ `R − L`), the next audio plays on arrival plus `L`, not at `pts + R`. With AirPlay present that is `S − L` early, about 600–900 ms at the defaults. In BT-only it loses each speaker's `R − L_i` compensation, so two *different* speakers fall apart by `L_1 − L_2` while two identical Moves stay together. Nothing in the sink or the manager re-anchors on a resume: `reanchorAll` is called only for `wizard_feed` and `room_delay_change` (`NB+BT:1418`, `NB+Tone.swift:971`). `ed6f00a` does not help, since pulls continue during the pause and its measure stays near zero. **Counter-evidence:** on 2026-08-23 the owner heard a −410 ms trim hold "across many start/stops" (`bt-autocal-live-findings-2026-08-23.md`, branch `claude/bt-autocal-spike`, `81e7ba97`). That fits either the tap not idling in those pauses, or a build before `TapAutoStart`. So this is a test to run, not a conclusion. |
| A2 | **A2DP playout rate = capture rate**, so unity ratio holds (`BTSS:1176-1179`). | BT against BT is settled: −0.02 ppm acoustically, and after PR #200 fixed the one-sided lost-cycle padding, ≤2 ms over 3 min and about zero over 30 min (SCA Gap 3 as corrected 2026-09-26; crosstalk 00:49). **Common-mode drift, BT against the capture/host clock, is not settled, and there is a live hint that it is real.** In the labelled 2026-09-14 recording, block 6 showed both speakers sliding together by ~1 ms/min (567 → 556 ms over 9 min) with the tap counter flat (SCA Gap 3). That is about 20 ppm, the same order as the Move 2's +21.7 ppm pacing clock against host (`bt-spike-findings-2026-08-07.md`). AirPlay follows host `pts` through PTP, so it cannot share that slide. | **Inferred, with one supporting observation.** A 20 ppm common-mode slide is 1.2 ms/min, i.e. 72 ms per hour between every BT speaker and every AirPlay speaker. The sign in block 6 (arrival getting earlier) means BT pulls faster than the capture writes, so the ring's lead also shrinks by that much. A two-Move rig hides it, since both slide together. A BT+AirPlay session of an hour or more shows it. The 290 ms "slow creep" in customer session D4C23DD3 (VCR §1) is consistent with it. The passive tracker would see it only as a BT arrival moving against an AirPlay anchor, and it corrects in ≥10 ms steps. Neither `ed6f00a` nor anything on main compensates it: `ed6f00a` compares pulls with wall time at nominal rate, not with `pts` |
| A3 | **A latency measured once holds for the stream** (the sink never re-measures; trims are static). | Re-rolls 20–90 ms at every stream start; warm-up about 60 ms over 20–30 min; OS mode steps of 70–90 ms; Move settle up to −353 ms in 42 s (`bt-latency-stability-research-2026-09-05.md` §1-2). | Handled by events only. Each event needs a successful mic window, which has not happened live (VCR §3 item 4). |
| A4 | **The HAL's reported latency is useless** (never used, `BTSS:770-780`). | True as truth (AirPods read a flat 160 ms while the stack moves 60–220 ms; forum thread 764070). But zero is a worse prior than a wrong-but-typical number. | A fresh speaker plays its full `L` late until someone calibrates it. |
| A5 | **A pacing-clock jump is only a hint** (logs, marks the row stale, asks for a mic window; `OutputBackend.swift:789-811`, `BTSpeakerTiming.swift:383-440`). | A jump can be an acoustic move (VCR §1 row 1: a Move played up to +293.5 ms late in a 77 s storm) or pure bookkeeping (`529a321`'s `dev/drift-clock-step-fit.py` exists to decide which; it has not been fed its ~20 paired windows, VCR §3 item 9). | Without `ed6f00a`, every uneven second stays in the ring as a permanent offset. |
| A6 | **Engine config changes keep the timeline** (`config_change` carries the session delay across a rebuild, `BTSS:846-853`, spec Part 3a). | A rebuild restarts the engine, which almost certainly restarts the A2DP stream (**inferred**), and that re-rolls `L` by 20–90 ms. The carry keeps the old sink delay against a new acoustic latency. No drift trigger fires on a rebuild (the clock watcher's restart reads `.ignored`, `BTClockStability.swift:101-107`; only a baseband reconnect fires `.reconnect`, `NB+Tone.swift:1041`). | Silent 20–90 ms misalignment after every route or config change, until the 25-minute periodic window, if that window can see at all. |
| A7 | **The render lock never misses** (`guard stateLock.try() else { return false }`, `BTSS:1181`). | On contention with a control-queue reader (`hasStartedRendering`, polled by `pollBTRenderStart`; `anchoredDeviceUIDs`; `applyTrimDelta`), the cycle returns silent **without draining the ring**. | **Inferred from code:** each miss adds one buffer (11.6 ms at 512 frames, more at A2DP's larger buffers) of permanent delay on that speaker, with no log line. The local sink has the same shape but its PI loop pulls it back at ≤200 ppm. `ed6f00a`'s realign runs before the lock (its diff: "a cycle the lock turns away was still pulled"), so it would catch these once they sum to 20 ms. |
| A8 | **Codec is stable per connection** (no detection at all). | Undocumented on macOS; AAC vs SBC differ by tens of ms (SoundGuys numbers in the stability research). A codec change without a rate change fires no listener. | Unknown size; unobservable today. |
| A9 | **The rate listener catches HFP** (`hfpDegraded = nominalRate <= 24_000`, `BTSS:788`; rebuild on `rate_change`, `BTSS:1266-1272`). | True for the rate. But HFP latency differs from A2DP, and the stored A2DP `L` is re-applied unchanged to an HFP stream. | Plays with the wrong `L` for the length of the call-mode spell. It also re-rolls twice: once in, once out. |
| A10 | **Two BT links are fine**, more is best effort. | `bt-output-research-2026-08-07.md` §3.4: 3–4 is where field reports fall apart. The capture loses cycles once per ~40 s with a third link (`NCC:1760-1763`). | Stepping clocks, lost cycles, more rebuilds. |

### 1.5 Gap 4 in SCA: verified

SCA Gap 4 asked whether a Bluetooth device that is the Mac's default output goes
through `SyncedLocalSink` with HAL latency. **Yes, confirmed from code.**

- `SyncedLocalSink` never calls `setDeviceID`. It renders to whatever the system
  default output is and re-follows it on a default-output change
  (`SyncedLocalSink.swift:549-584`; `grep setDeviceID` finds nothing there).
- Its latency is `LocalOutputLatency.measure()` of the **default** output device
  (`SyncedLocalSink.swift:171`, used at `:289` and `:619`). That is the HAL
  formula `SCA §3.2 point 4` calls wrong for Bluetooth. No transport-type check
  exists on this path. The only transport-aware code nearby is
  `LocalPlaybackEngine`'s loop guard (`LocalPlaybackEngine.swift:1100-1116`),
  which refuses AirPlay-class and Audiout aggregates and deliberately follows
  Bluetooth headphones (`:111-118`).
- The same device then clocks the capture aggregate (`NCC:3654-3672`), so an HFP
  collapse on it changes the capture rate for every output
  (`DefaultOutputDeviceMonitor`'s settle window,
  `Sources/AudioutCore/AGENTS-HISTORY.md:228-240`).
- The row it lives on gets none of the Bluetooth machinery: no clock watcher, no
  keep-alive, no passive-tracker baseline (`refreshDriftTrackingLocked` skips
  `isLocalDevice`, `NB+BT:1190-1191`), no measured `L`, and only the Mac row's
  `syncOffsetMs` (±500 ms) as a manual fix.
- Worse, its PI loop reads the BT device's render timestamps. A pacing-clock
  re-anchor steps those timestamps, and the loop will slew toward the step at up
  to 200 ppm (0.2 ms/s) whether or not the sound moved (**inferred**).

### 1.6 Lifecycle and state-machine edge cases

The sink has four states, `idle → anchored (silent hold) → released (FIFO) →
torn down`. Every structural change goes back through teardown. The table lists
each event, what the code does, and the failure it produces.

| Event | Code path | What happens to timing | Failure mode |
|---|---|---|---|
| First selection | `applyBTSinkTransition` (`NB+BT:402-470`): composition, then reference, trims, latencies, keep-alive, gains, EQ, then `setDevices`, attach, start | Anchors on the first buffer; holds `R − L + trim` | Unmeasured `L = 0`: plays `L_real` late (A4). `engine.start` overshoot is skipped (`BTSS:1249`) |
| Trim or latency change, released | `applyTrimDelta` seek + 5 ms crossfade | Exact, instantaneous | Forward seek clamped at 100 ms short of write; **the refused part is still persisted by the UI**, so the speaker comes back wrong on the next reselect (VCR §1 row 2, open) |
| Trim change, gate closed | Target recomputed from provider (`BTSS:1074-1083`) | Exact | None |
| AirPlay or Cast joins or leaves | `setComposition` → `requestRebuild("composition_change")` for **every** BT sink (`BTSS:1468-1475`) | New anchor, delay re-derived; `R` jumps between BT-only (≥500) and `S` (1000) | Every BT speaker goes silent for a full `R` and restarts its stream (re-roll 20–90 ms, **inferred**). With AirPlay in, the latency budget drops to `S − 500` in the wizard (SCA Gap 1, VCR §3 item 6) |
| BT-only floor moves (a slower speaker measured or added) | `setBTOnlyBufferMs` → rebuild all (`BTSS:1484-1491`) | Same as above | Whole-house gap. The deselect ordering bug (`-10851` restart) is fixed only on `origin/claude/bt-deselect-no-rebuild-a066` `3ae8fea2` (unmerged) |
| Drift correction lands | `writeBTDriftLatency`: slew steps are live seeks with `persist:false`; the floor moves only on the committed write (`NB+BT:1228-1270`) | Seeks only | A correction bigger than the 100 ms headroom rides the zero clamp until commit (acknowledged "razor" at `NB+BT:1250-1262`) |
| Another speaker added or removed (no composition change) | `setDevices` builds or stops only that sink | Survivors untouched | None (spec Part 3a fixed this) |
| `AVAudioEngineConfigurationChange` | `rebuild("config_change")` with **carry** (`BTSS:844-853`, `:1260-1266`) | Old mapping kept | Carry vs re-roll (A6). A multi-fire burst is handled (`BTSS:900-911`) |
| Nominal-rate change (HFP in or out, 44.1↔48) | `rebuild("rate_change")`, no carry | Re-derived | Wrong `L` in HFP (A9); two re-rolls per call; capture also rebuilds if the device is the default output |
| Baseband disconnect/reconnect | Enumerator edge → `noteConnected`, `reapplyBTSinkLocked`, drift trigger `.reconnect` after 15 s (`NB+Tone.swift:1024-1041`) | Fresh sink, stored `L` re-applied and labelled `fromLastTime` (ADR 0001) | Re-roll up to hundreds of ms per connection (`bt-autocal-live-findings`: −410 one session, ~46 the next). The fix relies on the mic window |
| Program pause (tap idles) | Nothing in BT. AirPlay gets idle fill; BT gets nothing | Ring drains; keep-alive marks zero cycles as audio for 10 min (default, `AppSettings.swift:242-246`) so the A2DP stream stays up | A1: delay lost on resume (**inferred**, test Q1). After 10 min the stream idles, and resume re-rolls `L` too |
| Program silence without a tap idle (quiet track) | Frames keep flowing | Fine | None |
| Lost IOProc cycle ≤ 50 ms | Padded (`NCC:1781`) | Fine | Four lost cycles in a row still fit; over 50 ms is treated as a pause |
| Producer ring overflow (consumer stalled > 11 s) | Chunk dropped, counted (`bt_sink_ring_drops`) | Permanent shift by the dropped length | Logged, not compensated |
| Render lock miss | Silent cycle, no drain (`BTSS:1181`) | +1 buffer permanent | A7, unlogged |
| Sleep/wake | Engine config change or rebuild re-seeds the mach→monotonic offset (`BTSS:593-601`) | Re-anchor | Same as config change |
| Wizard or companion probe | Reference raised to 2000 ms for a BT target (`NB+BT:170`), `reanchorAll("wizard_feed")` on both edges (`NB+BT:1414-1418`); non-participants gain 0 (`NB:3053`) | Two whole-house gaps per run | Each gap restarts the stream being measured (the measured `L` then belongs to a stream the run itself re-rolled on exit, **inferred**) |
| Volume change | Software: `mainMixerNode.outputVolume` (`BTSS:719-724`). Hardware (AVRCP): device property write (`NB+BT:105-113`) | None | None on timing. Some speakers park the amp at low level (the Sonos amp-gate eats the first ~2 ticks, `bt-autocal-live-findings`) |
| EQ change | New `EQProcessor` baked off-thread, swapped (`BTSS:740-757`) | None (IIR, no added latency) | None |

### 1.7 Owner requirement (crosstalk 00:45): absolute volume before a sweep

- **Detection lives in** `NB+BT:30-88` (`reevaluateBTHardwareControlLocked`),
  combining `BTAbsoluteVolumeSDP.claim` (`BTAbsoluteVolumeSDP.swift:19-57`:
  AVRCP Target SDP record version ≥ 1.4, or supported-features bit 0x0002) with
  `BTHardwareVolume.isControllable` (`BTHardwareVolume.swift:67`) and a
  failed-write fallback (`NB+BT:115-122`). The result is
  `Device.btHardwareVolumeCapable` plus membership in
  `btHardwareControlledUIDs`. Entering control **adopts the speaker's current
  level**, a read, never a write (`NB+BT:69-77`). The live-quantization check
  (1/127 steps) from `dev/notes/bt-absolute-volume-detection.md` finding 3 is not
  implemented. Only the SDP claim is.
- **The probe path neither checks nor sets the level.** `stageBTMicProbe`
  (`NB+BT:1447-1450`) and `startCompanionAlignmentProbe` (`NB+BT:1526-1612`)
  contain no volume code. The sweep is synthesised at a fixed peak of 0.175
  (−15 dBFS; `AlignmentTickInjector.swift:483-489`), with the Mac/engine lane a
  further −6 dB (`:478-480`). It is injected into the fan-out *before* each
  sink's gain (`BTSS:1725-1732`), so it is scaled by `master × device volume`, or
  by master alone for a hardware-controlled speaker, whose own knob then sets the
  acoustic level (`NB:3052-3060`). A user at 20% volume gets a sweep 14 dB
  quieter than one at 100%.
- **No pre-sweep level check exists** on either side. `MicProbeSession` has no
  RMS or floor gate before correlating (only ambient-noise weighting after,
  `MicProbeSession.swift:428-444`). The phone computes a live RMS
  (`ProbeCaptureSession.swift:172-176`), but it only drives the sheet's visual
  plate (`SyncSheetModel.swift:103, :628`) and gates nothing. The one failure
  signal is after the fact: low correlation confidence. The phone floor is 25
  (VCR §2). The Mac accepts any finite non-negative number
  (`CompanionCommandDispatcher.swift` about line 318, VCR §3 item 5).
- The seams to build on: `pushBTHardwareVolumeLocked` (write), `control.read`
  (current level, for restore), and the probe's own staging
  (`captureCoordinator?.stageWizardMicProbe` / `stageCompanionMicProbe`).
  Raise-then-restore would need the restore to survive a cancel and a
  disconnect. `beginCompanionAuditionCleanup` (`NB+BT:2053`) is the existing
  model for a guaranteed restore.

### 1.8 What was tried and what was dropped (branches and notes)

| Idea | Where | Outcome and why |
|---|---|---|
| Aggregate / Multi-Output device with drift compensation (PairPods style) | July research, restated in `bt-output-research-2026-08-07.md` §1 | **Rejected**: no per-device delay or volume, cannot include AirPlay, pitch warp on 44.1/48 mixes. AVAudioEngine also silently no-ops on an aggregate (`BTSS:448-452`) |
| Per-device BT drift loop servoing the pacing clock (`BTDriftCorrector`) | PLAN-UNIVERSAL-SYNC BT-DRIFT; spike 2026-08-07 | **Deleted** (per-device-trim-spec Part 3c): it compared the host-side pacing clock with itself, so it was inert. The acoustic −0.02 ppm run (`efb67775`) was taken as proof no rate loop is needed. The 08-23 live findings still expected "the BT sink's continuous drift servo" to hold phase through a walk; none existed |
| Mic auto-offset | Cut by the owner 2026-08-07; **reversed** 2026-08-27 (per-device-trim-spec "Out of scope") | Now the phone and Mac mic probes (ProbeKit sweeps) |
| Alternating-mute tick probe on the phone | `claude/bt-autocal-{spike,mac,dsp,iosui}` (`364e24d4` spec, `81e7ba97` findings) | Validated as an instrument (0.4–1.6 ms spread) but superseded by the DOWN/UP sweep pair in ProbeKit. The iOS tree was deleted from those branches when the repos split |
| Forced-choice bisection wizard | `claude/bt-fix-rtlocks` W1 (`80876d59`) | **Replaced** by the method of constant stimuli, then a Bayesian posterior (`BTAlignmentPosterior.swift`). One wrong answer froze the bisection |
| First-mix intercept card | Same branch W3 | **Removed** 2026-09-03 (PLAN-UNIVERSAL-SYNC amendment, per-device-trim-spec Part 2) |
| BT real-time lock fixes | `claude/bt-fix-rtlocks` `dbca24f3` | **Abandoned WIP**, never test-verified ("agent stalled before tests"). Touched construction under `tableLock` and deviceID-aware replacement, which is the lock-contention area of A7 |
| Reconnect-survival band-split chirps (roadmap 062) | per-device-trim-spec Part 3b | **Superseded** by the passive tracker's reconnect trigger (`.scratch/passive-drift-tracking/spec.md` decision 12) |
| Passive tracker, 3-minute periodic | spec decision 2 | **Amended** to event-driven plus 25 min (decision 18): drift was found to be event-shaped once PR #200 padded lost cycles |
| Correlator gate 2.3 | decision 15 | **Reverted** to 3 plus two gates (margin 1.2, local 2.4) after it accepted a non-peak |
| Nearest-speaker assignment of a merged peak | decision 14 | **Removed**: it corrected an in-sync pair out of sync twice live |
| Ambient-noise slice (ticket 15) | `origin/claude/drift-t15-ambient` `dc976f6a` | **Shelved** before review fixes |
| `AUDIOUT_BT_CLOCK_WATCH=0` kill switch | `BTClockStability.swift:157-169` | Kept as a diagnostic after a 2026-09-03 judder; the stalls turned out to be in the AirPlay send loop |
| Sink re-timing on uneven pulls | `ed6f00a` | **Unmerged**, replay-proven only (VCR) |
| Correlator search window | `2977e56` | **Unmerged** (VCR) |
| Deselect-before-reference ordering | `3ae8fea2` on `claude/bt-deselect-no-rebuild-a066` | **Unmerged**, 1 commit ahead of main. Not in VCR's table as a branch (VCR row 4 says "no pushed branch found"), so this is new: **tell the version-comparison thread** |
| BT sync drawer (live scrub without rebuild) | `claude/bt-sync-drawer` | Merged in substance (trim as seek) |

Branches `claude/bluetooth-latency-drift-6c2d59` and
`claude/cr-12-render-callback-clock-rebase` are 0 commits ahead of main (fully
merged). `claude/bluetooth-merge-status-094f33` holds roadmap rows only
(`caecc81e`: 049 re-anchor on lineup change, 050 reconnect survival, 019 HFP
oscillation). `claude/bluetooth-speaker-delay-feasibility-f3474a` holds the
phone-mic auto-cal feasibility brief (`c7922716`: GCC-PHAT, sound-vs-sound on one
recording).

### 1.9 Owner-reported first-sync silence (crosstalk 00:46): hypotheses only

Another thread owns the diagnosis. From my reading, these are the mechanisms that
would make a freshly connected speaker silent during its first sync and fine
after one play/pause. Each is a hypothesis, not a finding.

- **H1, keep-alive never arms on a speaker that has never played.** The
  keep-alive only flags dry cycles as audio once the sink has rendered real
  program audio at least once (`keepAliveWindow > 0 && lastAudible > 0`,
  `BTSS:1224`). A fresh sink has `lastAudible == 0`, so its idle cycles report
  `isSilence = true` and the OS may never start or keep the A2DP transport up. A
  play/pause sets `lastAudible` and holds the transport open for the next 10
  minutes. That matches "worked after play, pause" exactly.
- **H2, the probe rebuilds the sink twice just as it starts.** A BT-target run
  raises `R` to 2000 ms (`NB+BT:1390-1396` → `setBTOnlyBufferMs` → rebuild of
  every sink, `BTSS:1484-1491`) and also calls `reanchorAll("wizard_feed")`
  (`NB+BT:1414-1418`). On a link that has not settled (the Move's clock steps
  for up to 42 s after connect), two engine restarts in a row are the moment a
  start fails (`bt_sink_restart_failed`, `BTSS:854-860`) or comes up late.
- **H3, the arm gate gives up and arms anyway.** Ticks and sweeps wait until
  every sink renders, but only up to `wizardArmCeilingSeconds` = 8 s
  (`NB:666`, poll at `NB+BT:2639-2662`). A sink that has not released by then
  gets its sweep into a closed gate; the log line is `wizard_ticks_armed` with
  `timedOut:1`.
- **H4, the speaker's amp is parked or its level is low.** The Sonos amp-gate
  swallows the first transients after silence (`NB+BT:2646-2647` comment;
  `bt-autocal-live-findings-2026-08-23.md`), and nothing raises or checks the
  level first (§1.7).

The logs that would separate them: `bt_sink_anchored`,
`bt_sink_release_overshoot`, `bt_sink_restart_failed`, `wizard_ticks_armed`
(`timedOut`), and whether any `bt_clock_jump` lines precede the run.

### 1.10 Folded in from the journey researcher (crosstalk, 2026-09-26)

Checked against code and agreed:

- The drift baselines are the model (`room + trim`, `NB+BT:1130-1136`), never an
  acoustic observation taken after a calibration. The Mac-mic path asymmetry
  (2.9 ms/m) therefore reads as speaker error, and a ≥10 ms asymmetry gets
  "corrected" toward alignment at the laptop, not at the seat where the phone
  calibrated. This is a structural gap in the tracker's reference. It is listed
  as gap 2b below.
- Mac speakers plus one BT speaker never run drift tracking, because the Mac's
  own output is not an anchor (`NB+BT:1190-1191` skips `isLocalDevice`) and
  `driftTrackingRuns` needs two measured BT speakers or one plus an anchor
  (`NB+BT:1152-1154`). A trim-only speaker is never tracked
  (`btDriftBaselines`, `NB+BT:1130-1136`).
- The Mac-mic tracker and wizard mic only accept a built-in microphone
  (journey cites `MicProbeSession.swift:231-252`), so desktop Macs get neither.

---

## 2. Failure modes and structural gaps

I rank these by how directly they block *reliable* BT sync. Gaps already owned
elsewhere are listed with a pointer only.

1. **The Bluetooth ring forgets time after the anchor.** Frames carry no `pts`
   and the sink never computes a phase error (`BTSS:930-950`, `:1176-1179`). Every
   later hole, drop, lock miss (A7), pause (A1), or rate mismatch (A2) becomes a
   permanent, invisible offset. The remedy is structural: keep a `pts` per chunk
   (or `anchorPts + framesWritten` with gap detection at enqueue), and compute
   `phaseError = cycleStart − (ptsOfFrameBeingRead + delay)` every cycle, the way
   `SyncedLocalSink` already does against nominal rate. `ed6f00a` is a partial
   step: it ties pulls to wall time, not to `pts`, so it fixes uneven pulls and
   lock misses, but not pauses, capture-rate mismatch or dropped chunks.
2. **No closed loop on the acoustic truth that works in practice.** The only
   sensor that sees a BT speaker's real playout is a microphone. Today that is a
   Mac-mic tracker that has never landed a correction live and scores under 1 in
   a real room (VCR §3 item 4), plus a phone probe the user must run. Every
   event-shaped move (A3, A6, A9, reconnect re-rolls) waits on it.
   **2b.** Even when it works, the tracker's baselines are the model
   (`room + trim`), not an acoustic snapshot taken right after calibration, so
   it aligns speakers at the laptop, not at the listener (§1.10). It never runs
   for Mac + one BT speaker, or on desktop Macs without a built-in mic.
3. **Every structural event restarts the stream it is timing.** Composition
   changes, BT-only floor moves, wizard entry and exit, config changes and HFP
   all rebuild the engine (§1.6). Each costs a full-`R` silence and, by the
   stability research, a fresh 20–90 ms latency, and none of them schedules a
   re-measure. A design that moved `R` without stopping the A2DP stream (seek
   the read pointer, as a trim already does) would remove most of these re-rolls.
4. **`R` ignores BT latency when AirPlay or Cast is present** (SCA Gap 1;
   VCR §3 item 6).
5. **A fresh speaker has no prior.** `L = 0` until calibrated (A4). The HAL
   figure, a per-class default (headphone vs speaker from `deviceClassMinor`,
   already read at `NB+BT:1511`), or a fleet table of measured values would all
   beat zero.
6. **UI persists refused trims** (VCR §1 row 2).
7. **A BT device as the Mac's default output bypasses the BT path** (§1.5).
8. **Nothing detects a codec change or an OS audio-mode change.**
   `audioModeChange` is declared but never fired; the codec closure is nil (A8).
9. **Common-mode BT drift against the host clock is unmeasured and has one live
   hint of ~20 ppm** (A2). Everything behind "no rate drift" is BT-vs-BT. If the
   hint holds, BT+AirPlay rooms lose about 70 ms an hour, and only a
   per-sink rate loop against `pts` (O1) fixes it continuously.
10. **Mac accepts any confidence from the phone** (VCR §3 item 5), and **no
    pre-sweep level check** exists (§1.7).

---

## 3. Options and novel ideas

| # | Idea | Feasibility | What it takes | Risk |
|---|---|---|---|---|
| O1 | **Timestamped ring + per-cycle phase error for BT**, reusing `PhaseController` and `FractionalResampler` from `SyncCore.swift` (already license-clean for this purpose, `SyncCore.swift:1-8`). Gap-fill at enqueue when `pts` jumps past `expected + 50 ms` (write silence, as AirPlay's idle fill does), so pauses keep the mapping | High; the pieces exist and the local sink proves the loop | ~200 lines in `BTDeviceSink`: store `anchorPts + framesWritten`, compare each enqueue's `pts`, zero-fill holes (or re-anchor above a ceiling), compute phase error in `renderInterleaved`, feed the PI loop. Subsumes `ed6f00a` | The loop would servo to the *host-side* view of the device. That is right for pts-truth up to the BT pipe, but blind to the speaker's own buffer (the acoustic `L`). Keep the mic for `L` and the loop for rate and holes. Must keep the ±200 ppm, 25 ppm/cycle slew limits. Pacing-clock steps show up as phase steps; low-pass them or treat steps over 2 ms as re-anchors, not as rate |
| O2 | **Seek instead of rebuild when `R` moves.** `setBTOnlyBufferMs` and `setComposition` become per-sink seeks by `ΔR` (backward replays history; the ring holds 11 s), not engine restarts | High | Change `BTSS:1468-1491` to call `applyTrimDelta`-style shifts. Keep rebuilds for true device or rate changes | A large forward `ΔR` (R shrinking) hits the 100 ms margin clamp. Hysteresis (never shrink `R` while the slow speaker stays) avoids that, as CastRoomDelay already does |
| O3 | **Trigger a mic window on every sink restart**, not only on baseband reconnect: `bt_sink_rebuild` for `config_change`, `rate_change`, `composition_change`, and the HFP edges | High, small | Call `noteDriftTrigger(.reconnect(uid:))` (or a new `.streamRestart`) from `rebuildLocked` | Mic-window budget; the tracker's per-speaker rate limit already exists |
| O4 | **A prior for unmeasured speakers**: use the HAL latency plus a class offset, or a fleet median by `deviceClassMinor` and SDP vendor/product id, sent anonymously (counts and bucketed ms only, within the privacy fence) | Medium | Analytics event with bucketed `L` per device class; a bundled table; seeding in `applyBTSinkTransition` | The table's wrong answer is still better than 0, but must be marked `Source.estimated` so nobody reads it as measured |
| O5 | **Pre-sweep level stage** (owner requirement): if `btHardwareVolumeCapable`, read, raise to a set floor, sweep, restore in a guaranteed cleanup. Otherwise, play a short band-limited noise burst in the sweep band and read the mic RMS against the room floor before the sweep; if it is too quiet, ask the user to turn it up | Medium | New stage in the probe runs; restore path modelled on `beginCompanionAuditionCleanup`; mic RMS gate in `MicProbeSession` and on the phone | Loudness surprise for the user; a speaker that ignores AVRCP (fixed-volume) lies about capability. The Bluetooth researcher owns what AVRCP guarantees |
| O6 | **Treat the BT sink as a Core Audio device with its own presentation timestamps.** Read the device's `AudioDeviceGetCurrentTime` in the render path and map sample time to host time for the frame at the DAC boundary, instead of trusting `mHostTime` plus a measured constant | Medium-low | Only helps if pacing-clock steps track acoustic steps; `dev/drift-clock-step-fit.py` answers that once fed about 20 paired windows | If steps are bookkeeping (VCR says undecided), this imports noise |
| O7 | **Continuous passive tracking with a known inaudible probe**: spread-spectrum (MLS or chirp) sequences at −40 to −50 dBFS, or a high-band (16–19 kHz) marker per speaker, mixed into each BT lane so attribution is exact and the correlator no longer depends on the music's content | Novel for this app; common in acoustic ranging research | Per-lane marker injection already exists for the sweep probe (`enqueue(sweepFrames:sweepFreeFrames:ownerUID:)`, `BTSS:1725-1732`); a steady low-level marker is a variant | Audible to some listeners and pets at high band; many BT codecs (SBC at bitpool 53, AAC) low-pass near 16–17 kHz, so the high band may not survive. That would need measuring per codec. Needs an owner reversal of passive-drift spec decision 7 (no per-speaker signal tweaks); journey.md §5.2 works out a masking-shaped variant |
| O8 | **Measure BT-vs-AirPlay rate agreement** before building anything for A2: extend the `bt-multi-spike` drift meter (`b35b8737`) to put one tone on a BT speaker and one on an AirPlay speaker, 60 min | High, cheap | Spike branch exists; needs an owner session | None; it is the evidence Gap 9 lacks |

---

## 4. Open questions that need a live test or the owner

1. **Q1, pause/resume (A1).** With one BT speaker and one AirPlay speaker, play
   from Music.app, pause for 60 s (long enough for the tap to idle, which
   `tap_feed_gap` will not log, and for the BT ring to drain, `R` ≈ 1 s), resume.
   Is the BT speaker ~`S − L` early? Repeat with two *different* BT speakers in
   BT-only. A unit test can settle the code half first: anchor, drain dry, then
   resume enqueue with a `pts` 60 s later, and check where the first resumed frame
   renders. This is the cheapest high-value check on the list.
2. **Q2, common-mode BT rate against host/AirPlay (A2).** A 60-minute run, one
   BT speaker and one AirPlay speaker, no events: drift meter or two passive
   windows 60 min apart, plus the `bt_clock_deviation` lines (SCA Gap 3's own
   recommendation). Is the 2026-09-14 block-6 slide of ~1 ms/min there against
   AirPlay? Also: which device is the capture clock in the owner's normal setup
   (built-in or something else)? The answer changes the expected ppm.
3. **Q3, does an engine rebuild restart the A2DP stream and re-roll `L`?** Probe
   before and after a forced `config_change` rebuild. If yes, O2 and O3 move up.
4. **Q4, render lock misses (A7).** Add a counter for `stateLock.try()` failures
   in `renderInterleaved`; read it after a session with the drawer and the
   companion open.
5. **Q5, the pacing-clock numbers.** Move +21.7 ppm and XM3 +0.4 ppm against
   host (2026-08-07), yet −0.02 ppm against each other acoustically
   (2026-08-12). Either the HAL `mSampleTime` rate is not the pull rate, or the
   two runs saw different conditions. The ~20 ppm common-mode slide in the
   2026-09-14 recording makes the first reading of the Move plausible.
   (Bluetooth researcher.)
6. **Q6, owner decision on the level stage (§1.7):** may the app raise a
   speaker's hardware volume for 2–3 s during calibration, and to what level?
7. **Q7, default-output BT (§1.5):** should a BT device that is the system
   default be refused as "This Mac", or rerouted through the BT sink with a
   measured `L`?
8. **Q8:** merge order for `ed6f00a`, `2977e56`, `3ae8fea2`, and the refused-trim
   fix. O1 would replace `ed6f00a`'s mechanism, so decide before merging it
   whether pulls-vs-wall-time is the model to keep.
