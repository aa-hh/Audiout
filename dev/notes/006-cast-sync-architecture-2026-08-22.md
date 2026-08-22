# Cast as a third output transport — sync architecture brief (roadmap 006, Phase 2 design)

Date: 2026-08-22. Docs only; every anchor below was read in this worktree, not recalled.
Companion to `006-cast-output-scope-2026-08-22.md` (the scoping brief + spike log) and
`docs/plans/PLAN-UNIVERSAL-SYNC.md` (the BT plan the seams below copy).

## The decision being designed for

- Cast plays **~5–6 s behind live** (no-autoplay recipe; up to ~8.4 s autoplay), set by the
  receiver, and **self-reports its lead**: `secondsSent − currentTime`
  (`CastLiveAudioServer.swift:131`, logged by `CastSpikeRun.swift:236-238`).
- Sync model: **delay-to-worst.** Room delay `R = max over active outputs (intrinsic delay)`;
  each output is delayed by `R − intrinsic + trim` (≥ 0). With a Cast device in the mix
  `R ≈ 5–6 s`, so **AirPlay itself must be delayed** — by holding PCM *before* the engine
  write, never via `startBufferMs` (clamped 300–5000 ms, applied at session creation,
  changed only by the teardown/re-add dance in `applyStartBuffer`, `NativeBackend.swift:5542`).

## THE INVARIANT

**No Cast device selected ⇒ AirPlay, BT and local behave bit-identically to today**: same
bytes, same `pts`, same cadence, same thread, no extra latency, no new work on the IOProc.
The design below satisfies it by *construction* (optional fields that are `nil`, a
`max(x, nil) == x` term, a boolean OR with `false`), not by a feature flag.

---

## 1. AirPlay timing today, precisely

| Step | Anchor | What happens |
|---|---|---|
| Capture | `NativeCaptureCoordinator.swift:2627-2664` | IOProc stamps `pts = mach hostTime → CLOCK_MONOTONIC` (`timespec(machNanos:offset:)` :3023; offset re-seeded per tap, self-healed per buffer :3079-3090). |
| Fan-out | `handleBuffer` :1081-1167 | RT thread; one `snapshotLock.try()` read of the immutable `BufferSnapshot` (:152-187, :203); convert → tick mix (:1128) → **`sink.write(pcm:pts: buffer.pts)` :1133** → local fan-out :1144 → BT fan-out :1156 → RMS :1164. |
| Engine write | `AirPlayEngine.swift:1159-1332` | `nonisolated`; cadence/latency probes (:1184, :1190), `WriteBacklogGuard.admit` (2 s cap, :1208, :1362), heap copy, enqueue to the engine thread; `obuf.pts = pts` :1282 → `outputs_write`. |
| Vendored sender | `airplay.c:4341-4377` | `timestamp_set(ams, obuf->pts)` :4364 → `cur_stamp.ts = pts`, `cur_stamp.pos = rtp pos + input_buffer − output_buffer_samples` (:2232-2258). Sync packets are sent **only from inside `airplay_write`** (:4367; `packets_sync_send` has no other caller). |
| Schedule | `airplay.c:1229`, `EngineConfig` :37-71 | `output_buffer_samples = (startBufferMs − 250 ms) · rate`; receiver adds its 250 ms `latencyMin` (:2736). **Sound leaves the speaker at `pts + startBufferMs`.** |

**How the engine uses `pts`:** it does not pace or schedule by it. It pairs *the pts of the
latest write* with *the sample count delivered so far* to tell receivers "at wall time `ts`,
rtptime `pos` should be playing". Arrival order + sample count set the RTP timeline; `pts`
only anchors that timeline to the wall clock.

**Consequence for a pre-engine delay line:**
- **Keeping the original pts is WRONG.** A 5 s-old pts makes every sync packet advertise a
  position 5 s in the past — the exact failure already documented for the mach-vs-monotonic
  bug (`NativeCaptureCoordinator.swift:3005-3014`: "receiver schedules nothing").
- **Fresh pts is required — and with the right FIFO shape it is *unchanged* pts.** A
  cadence-preserving delay line (one output block per input block, same frame count) hands
  the engine the live capture `pts` with content from `D` seconds earlier. The engine sees the
  identical `(byteCount, pts)` sequence it sees today; only sample values differ. Nothing
  downstream correlates content with time (progress/metadata paths `airplay.c:950-1006` are
  unused for stream 0). Probes (`latencyProbe`, cadence, backlog) are untouched.
- Sound leaves the AirPlay speaker at `pts + D + startBufferMs`. With `D = R − startBufferMs`
  that is `pts + R`. ✔

**Discrepancy found (keep as-is):** `SyncCore.swift:34-38` says sinks must read
`currentPresentationDelayMs()` (= `startBufferMs − 250`), but both sink factories hand them
the *start buffer* (`OwnToneBackend.swift:947-948` via `localSinkReferenceDelayMs`
`NativeBackend.swift:5502-5507`; BT closure `OwnToneBackend.swift:961-962`
`nativeBackend?.startBufferMs`). That is the acoustically right number (speaker-out is
`pts + startBufferMs`, see table), so **AirPlay's intrinsic delay for the N-way rule is
`startBufferMs` (S), exactly as wired** — do not "fix" it to S − 250.

---

## 2. Where the delay line lives

| Option | Verdict | Why |
|---|---|---|
| (a) Optional stage inside `handleBuffer`, published through `BufferSnapshot` | **Chosen** | Same seam the tick injector (:1128) and both fan-outs already use; `nil` field ⇒ the existing `sink.write` statement runs unchanged; no lock, no queue, no allocation beyond today's posture. |
| (b) Wrapper replacing `sink` | Rejected | `sink` is an immutable `let` injected at init (:424, `EngineSink` :2067-2093); making it swappable adds a mutable hop to the hot path for no gain. |
| (c) Inside `AirPlayEngine` | Rejected | Engine must stay app-concept-free and is the GPL boundary (`AirPlayEngine/AGENTS.md`); a bypass would still be needed there. |

**Seam (exact):** `NativeCaptureCoordinator.swift:1132-1133`
```swift
// today                                      // after
sink.write(pcm: pcm, pts: buffer.pts)         if let line = snapshot.airPlayPreDelay {
                                                  sink.write(pcm: line.exchange(pcm), pts: buffer.pts)
                                              } else {
                                                  sink.write(pcm: pcm, pts: buffer.pts)   // byte-for-byte today's path
                                              }
```
- `BufferSnapshot` (:152) gains `let airPlayPreDelay: PCMDelayLine?`; `.empty` (:164) and
  `publishBufferSnapshot()` (:1035) carry it. A new `CaptureControlling` method
  `setAirPlayPreDelay(ms:)` (next to `setBTSink` :8156, default no-op :8183) publishes on
  `queue` like `setBTSink` :757-779. **`ms == 0` publishes `nil`, never an empty line** —
  that is the structural bypass.
- `PCMDelayLine` (new file, LICENSE-CLEAN banner like `SyncCore.swift:1-8`): single-thread
  S16LE frame ring (push and pop both on the IOProc), preallocated at construction on the
  control queue, `exchange(_:)` = write N frames, read N frames from `write − D`. Output is
  a `Data(bytesNoCopy:)` view over a preallocated scratch — legal because `write(streams:)`
  copies synchronously before enqueue (`AirPlayEngine.swift:1229-1233`). Delay changes use
  the BT two-counter idiom (requested/applied words, `BTSyncedSink.swift:380-387, :424-428`):
  on grow, zero-fill the newly exposed region (silence, not a replay); on shrink, drop.
- **Reuse/licensing:** copy the *idiom* from `BTFrameRing`/`BTDelayLine`
  (`BTSyncedSink.swift:246-343, :359-504`, license-clean). Do not reuse them as-is: they are
  Float, two-thread, and pull-shaped for `FractionalResampler`; an Int16 round trip would be
  two pointless conversions. **Never read `SyncedLocalSink.swift`'s ring (:699-705, GPL)
  for this.**
- RT rules honoured: no `queue.sync` (:1082-1110), `Telemetry` only from the control queue,
  `snapshotLock.try()` unchanged. Echo: the line renders nothing, so the `.mutedWhenTapped`
  exclusion set (:1142, :749-751 self-exclude) is untouched — **no tap rebuild on install.**

---

## 3. Reference-timeline generalisation

**Today (binary):** `BTReferenceTimeline.delayNanos` (`BTSyncedSink.swift:56-68`) picks
`airPlayPresent ? presentationDelayMs : btOnlyBufferMs(500)`; `SyncTiming.totalDelayNanos`
(`SyncCore.swift:53-64`) = `max(0, ref − latency − margin + trim)`;
`localSinkReferenceDelayMs` (`NativeBackend.swift:5502-5507`) = `(btSinkEnabled && !airPlayPresent) ? 500 : S`.

**N-way rule:** `R = max(R_today(composition), castTermMs)` where
`castTermMs = max over active Cast devices of settledLead_j` (nil when no Cast is active).
Every output then delays by `R − intrinsic_i + trim_i` (clamped ≥ 0) through the **same**
`SyncTiming.totalDelayNanos`, with `presentationDelayMs: R`. AirPlay pre-delay
`D_ap = airPlayPresent ? max(0, R − S) : 0` (nil when 0).

**Proof it reduces exactly** (castTerm = nil ⇒ `R = R_today`; `castPresent = false`):

| Composition shipped today | R_today | AirPlay `D_ap` | BT delay | Local delay |
|---|---|---|---|---|
| AirPlay only | S | `max(0, S − S) = 0` → nil | — | — (sink not armed: `wantSyncedLocal` :2498) |
| AirPlay + Mac | S | 0 → nil | — | `S − localLatency − margin + offset` (`SyncedLocalSink.swift:480-484`) |
| AirPlay + BT (+ Mac) | S | 0 → nil | `S − deviceOffset + trim` (:63-67) | as above |
| BT only | 500 | not AirPlay-present → 0 → nil | `500 − offset + trim` | — |
| BT + Mac | 500 | nil | `500 − offset + trim` | `500 − localLatency − margin + offset` (via :5504) |
| Mac only | n/a | nil (capture gate off :7549) | — | native playback |

Every cell equals today's value because `max(x, nil) ≡ x` and `(airPlayPresent || false) ≡
airPlayPresent`. `BTGroupComposition` gains `castPresent: Bool`; the predicate at :64 and in
`usableTrimRangeMs` (:1328) becomes `(airPlayPresent || castPresent)`.

**Call sites that read the reference today → what each becomes**

| Site | Today | Becomes |
|---|---|---|
| `localSinkReferenceDelayMs` :5502 | composition-aware S/500 | `castTermMs.map { max(old, $0) } ?? old` |
| BT factory closure `OwnToneBackend.swift:961` | `nativeBackend?.startBufferMs` | `nativeBackend?.btReferenceDelayMs()` = same `max` over S |
| `BTGroupComposition(...)` :2554-2558 | airPlay/mac | + `castPresent: ids.contains { known[$0]?.isCast == true }` |
| `localReferenceMoved` :2592-2594 | BT/AirPlay flips | + castPresent flip, + castTerm change |
| re-anchor :2606-2614 (`requestReanchor`, `SyncedLocalSink.swift:394`) | on composition flip | also on every `castTermMs` change |
| `btUsableTrimRangeMs` :8349 → :1318-1333 | live query | unchanged code, new predicate |
| `applyStartBuffer` :5542 | teardown/re-add | after step 2, recompute `D_ap` iff castTerm ≠ nil |
| NEW `roomDelayChangedLocked()` (stateQueue) | — | fans R to: `captureCoordinator.setAirPlayPreDelay`, BT (`setComposition`/shift), local (`requestReanchor`), Cast feed lines |

---

## 4. Cast's intrinsic delay is a live measurement

Facts (spike log): ~0.7–3.7 s to first audio, 2–3 stalls in the first ~12 s, then lead flat
±0.1 s for minutes; `currentTime` granularity ~10 ms; volume round trip 17 ms settled, ~1 s
mid-stall (control replies queue behind the stall).

**Key physics (changes the design):** we cannot *shorten* Cast's delay, but we can *lengthen*
it freely — inserting zeros into the HTTP feed delays content without starving the receiver
(lead in audio-seconds unchanged). Skipping feed content shortens it at the cost of buffer
level (stall risk). Holding the feed starves the receiver → stall → re-buffer → *longer*
delay. So: **Cast gets the same `PCMDelayLine` in front of its server feed** (insert-zeros
/ skip, never hold), with `D_cast = R − settledLead + trim`. The dominant Cast device sits at
`D_cast = 0`; a second, faster Cast device (Nest-class ~2 s) is zero-padded up to R without
touching the others.

**Room-delay policy — high-water mark, settle-gated, never chase:**

| Event | Action | Who hears what |
|---|---|---|
| Cast selected | `castTermMs := remembered steady lead for this id, else 5500` (session memory; no persistence v1) **before** LAUNCH; Cast feed attached at LOAD with gain 0 (zeros in the feed, not receiver volume). | Others take their one hit now (§5). Cast silent ~3 s launch + ~10 s settle. |
| Lead samples | `GET_STATUS` every **1 s** while `castPresent`; keep a sample only if `playerState == PLAYING` and round trip < 100 ms. | — |
| Settle gate | 10 consecutive kept samples within ±100 ms (mirrors `BTDriftCorrector.defaultSettleNanos` 10 s, `BTSyncedSink.swift:107`; threshold 100 ms not 2 ms — stalls are 0.5–5 s, drift is ~3 ms/min). `settledLead = median`. | — |
| Settled, `settledLead ≤ castTerm` | `D_cast = castTerm − settledLead + trim` (zeros, inaudible while muted), then un-mute with a 5 ms fade. | Cast joins in sync. |
| Settled, `settledLead > castTerm + 150 ms` | raise `castTermMs` (R grows by the excess) once; re-apply. | Second, smaller gap on every other output. Honest and rare (default 5.5 s covers the measured 5.1–5.9 s). |
| Mid-song stall (lead jumps up δ) | Re-settle (10 s), then: if `D_cast ≥ δ` skip δ in the Cast feed; else raise R by the remainder. Hysteresis: R never falls while Cast stays selected. | Cast already had the gap; others untouched when the Cast line can absorb it. |
| Slow drift (receiver clock vs Mac, ~50 ppm ≈ 3 ms/min) | v1: re-align by skip/insert when \|error\| > 150 ms (≈ every 50 min, a 150 ms blip on Cast only). Phase 3: `FractionalResampler` ±ppm on the Cast feed driven by the lead slope (the `BTDriftCorrector` shape, `BTSyncedSink.swift:100-140`). | One blip/hour on Cast, or none after Phase 3. |
| Cast deselected / failed | `castTermMs := nil` → R = R_today. | Others skip ahead (§5). |

`settledLead` is per device; `castTermMs = max_j`. Lives on `stateQueue` beside the BT
connect poll (`pollBTRenderStart` :3036); Telemetry `cast_lead_sample`, `room_delay_changed`.

**Why not follow immediately:** the first 12 s have 2–3 jumps; following each one would
silence the whole house three times. **Why not freeze forever:** a mid-song stall leaves Cast
seconds behind with no path back; the settle-then-correct rule fixes it on Cast alone when
the Cast line has headroom.

---

## 5. Changing delays live — join/leave sequences, honestly

Primitives: AirPlay line grow = zeros (silence) / shrink = drop (content jump, no fade — a
5 ms equal-power crossfade as in `BTDelayLine.mixFadeStep` :497-503 is cheap to add, do it);
BT `requestShift` + crossfade (:424, :457-486) — note a **negative shift replays history**
(:419-421), so a seconds-long grow must use a new zero-fill variant, not a 5 s rewind; local
`requestReanchor` (`SyncedLocalSink.swift:394`, already fired on composition flips :2613);
`BTSyncedSink.setComposition` rebuilds (:1250-1257) = silence for the whole delay.
**A trim change never rebuilds a sink** (`Sources/AudiouterCore/AGENTS.md:38-47`) — R
changes follow the same rule: shift, don't rebuild, except Cast join/leave where a rebuild
costs about what the shift would.

| Transition (S = 1000, Cast 5.5 s) | AirPlay | BT | Local | Cast |
|---|---|---|---|---|
| Cast joins AirPlay(+BT+Mac) | silent 4.5 s, then resumes 4.5 s behind where it was | silent ~5 s (rebuild via composition) | re-gate, silent ~5 s | silent ~13 s, then in sync |
| Cast joins BT-only / BT+Mac | (no session) | silent 5 s | silent 5 s | as above |
| Cast joins Mac-only | — | — | capture gate trips (:7549), Mac sink arms (:2498) → Mac mutes, comes back 5.5 s later | as above |
| 2nd Cast joins (faster) | nothing | nothing | nothing | zero-padded up to R, muted until settled |
| Cast leaves (others stay) | content jumps ahead 4.5 s (+5 ms fade) | skip ahead (crossfade) | re-gate | stops |
| Cast fails mid-session | same as leaves — **never take AirPlay down with it** | | | `.failed` with a Cast cause |
| R nudge < 1 s (settle correction) | grow: zeros / shrink: jump | shift + crossfade | re-gate | usually absorbed on Cast alone |
| `applyStartBuffer` with Cast active | existing teardown/re-add + line resized to `R − S'` | closures read S live | same | unchanged |

Ordering on join: set `castTermMs` and publish the AirPlay line **first** (one atomic
snapshot swap), then BT/local, then LAUNCH. On leave: publish `nil` first so the invariant is
restored at the very next buffer, then drop the Cast manager.

---

## 6. Capacity and margins

Rates: AirPlay/Cast feed S16LE 44.1 k stereo = **176,400 B/s**; BT ring Float 44.1 k stereo
= 352,800 B/s; local ring Float at device rate (48 k) = 384,000 B/s.

| Ring | Max delay it must hold | Size rule | Memory |
|---|---|---|---|
| AirPlay `PCMDelayLine` | `R_max − S_min = 9500 − 300` | 10 s | 1.76 MB |
| Cast feed line (per device) | `R_max − lead_min + trim = 9500 − 700 + 1000` | 10 s | 1.76 MB |
| BT (`maxBufferedSeconds` 8, `BTSyncedSink.swift:619`) | `R_max + 500` = 10 s | set **11 s** — pow2 rounding (:255-256) keeps 2^19 frames (11.89 s real capacity) → **no memory change** from today's 4.2 MB | 4.2 MB |
| Local (`SyncedLocalSink.swift:153`, GPL — touch the number only) | `R_max + syncOffset` | set **10 s** — 10·48 k·2 = 960 k samples stays inside today's 2^20 | 8.4 MB @48 k (unchanged) |

**Cap `R_max = 9500 ms`.** A Cast device whose settled lead exceeds it is refused for sync
(badge "too far behind to sync", plays unsynced) — autoplay's 8.4 s fits, Opus's 15 s would not
(we ship WAV). Trim ranges: BT ±500 (`BTTrimStore.swift:23`); Cast ±1000 (Airfoil's figure).

**CPU:** the line is two `memcpy`s per buffer. At 512-frame buffers (~86/s): 2 × 2 KB =
4 KB/buffer ≈ 0.4 µs at ~10 GB/s; 353 KB/s of memory traffic total. "No measurable CPU
impact" holds by three orders of magnitude; and at delay 0 the cost is one nil check.

---

## 7. Everything else a third transport touches

| Seam | Change | Touches AirPlay path? |
|---|---|---|
| `Device.Kind` (`Device.swift:14-42`) | `case cast` (+ `isCast` next to `isBluetooth` :76; `supportsAirPlay2 = false`). **Trap:** exclude via `isCast`, never `supportsAirPlay2` — AP1 receivers share that flag and ARE engine-driven (`AudiouterCore/AGENTS.md:320-323`). | No |
| Discovery | `_googlecast._tcp` browse (`CastBrowser`), ingest shaped like `applyBTSnapshots` :6714 via `commitKnownDevice` :6645; groups = one virtual device. | No |
| `setOutputSet` (:2353) | Engine loop guard :2413-2415 gains `!device.isCast` (explicit, like `isBluetooth` — R-partition trap: no `outputIDs` entry already drops it silently). Third arm after the BT arm (:2523-2616): `castIDs`, `.connecting` on select, manager reconcile, `castPresent` in composition. | Guard only; evaluates `false` for every non-Cast device |
| Fan-out slot | `setCastSink(_:renderProcessPID:)` in `CaptureControlling` (:8156 pattern, default no-op), `BufferSnapshot` field, fourth consumer after :1156 — S16LE straight in (Cast server already speaks 44.1/16/2), no widen/resample. pid = own pid ⇒ `rebuildIfExclusionObjectsChanged` finds no change ⇒ **no tap rebuild** (:747-756). | One more `if let` after the engine write |
| Capture gate (:7537-7549) | None — `isLocalDevice == false` already trips it (same as BT). | No |
| `desiredDeviceAudibleLocked` (:6034-6038) | `if device.isCast { return castPlayerState[id] == .playing }` — PLAYING, not "un-muted after settle", else the 10 s silence watchdog un-mutes the Mac during the settle hold and you get both. | Inserted before the AirPlay line; AirPlay line unchanged |
| `retryOutput` (:2656) | `if retryCastOutput(id) { return }` beside `retryBTOutput` :2663. | No |
| `ConnectionFailure.Cause` (`ConnectionState.swift:39-67`) | `.castReceiverBusy`, `.castAppUnavailable` (the AirServer case), `.castTLSFailed`; reuse `.timedOut`/`.vanished`. | No |
| Volume/mute (:2129, :2174, :2226) | Cast branch before the `outputIDs` guard, like BT :2151; composed `Main × Group × Device` → `SET_VOLUME` (17 ms round trip), serialised latest-wins like `pushVolume`. | No |
| Trim | `BTTrimStore` is a string-keyed JSON map (`BTTrimStore.swift:63`) — reuse for Cast ids as-is in Phase iv; rename to `SyncTrimStore` later. `BTOutputControlling` (:8200) gets Cast twins or a generic `SyncTrimControlling`. | No |
| Wizard | `BTAlignmentBisection` is pure; `BTAlignmentWizardSession` takes a `Reference` identity — host a Cast run with ±1000 ms start. | No |
| Per-app routing | Cast excluded in v1 **for free**: `isRouteTargetReachableLocked` :3110-3112 needs an `outputIDs` entry. Document, don't code. | No |
| Popover | `deviceSections()` `PopoverController.swift:1338-1348`: fourth "Cast Devices" section, AirPlay filter adds `!isCast`. Rows reuse the AirPlay vocabulary (no `isBluetooth`-style branches needed). | No |
| Bundle | `make-app.sh:599-605` add `NSBonjourServices.3 = _googlecast._tcp` + its check; Local Network grant already covers the browse and the unicast TLS to :8009. | No |
| `MockBackend` | Nothing (no BT handling there either). | No |

---

## 8. Risk register against the invariant

| Function | Modification | Structural guard (no-Cast ⇒ identical) |
|---|---|---|
| `handleBuffer` :1081 | `if let` around the engine write; fourth fan-out `if let` | Both fields `nil` in every snapshot unless `setAirPlayPreDelay(ms > 0)` / `setCastSink(non-nil)` ran; the `else` branch is today's statement verbatim. Test: forwarded `(pcm, pts)` arrays equal (§9). |
| `publishBufferSnapshot` :1035 | two more fields copied | Value copy of `nil`. |
| `setOutputSet` :2353 | guard term, third arm | `isCast == false` for all existing kinds; `castIDs` empty ⇒ arm is a no-op and `castPresent == false`. |
| `localSinkReferenceDelayMs` :5502 / BT closure `OwnToneBackend.swift:961` | `max` with optional | `castTermMs == nil` ⇒ old expression returned unchanged. |
| `BTReferenceTimeline.delayNanos` :56 / `usableTrimRangeMs` :1318 | predicate OR | `castPresent == false`. |
| `reconcileCaptureGate` :7537 | **none** | — |
| `TapRebuildDecision` (`NativeCaptureCoordinator.swift:2200`) / `recreateTap` / R10 reset (`AudiouterCore/AGENTS.md:222-257`) | **none** | Cast attach changes no exclusion object (own pid); a future out-of-process encoder would — keep it in-process. |
| `resetAirPlaySessionForWholeSystem` :3700, `handleSystemDidWake` :5913, `armSilenceWatchdog` :6065 | **none** | Iterate `added`/`desiredOn` with `outputIDs` — Cast never has one. Wake re-connect for Cast is the manager's (like BT's enumerator refresh). |
| `retryOutput` :2656 | early-return arm | `isCast == false` ⇒ falls through to today's body. |
| `desiredDeviceAudibleLocked` :6034 | one inserted line | — |
| `applyStartBuffer` :5542 | post-step recompute | `guard castTermMs != nil`. |
| `setVolume`/`setMuted`/`setMasterGain`, Touch Bar, `engineVolume` | Cast branch only | AirPlay branch byte-identical. |
| `AirPlayEngine` package | **none** | — |

A feature flag is *not* part of the guard: the off-state is the absence of state.

---

## 9. Verification strategy

**Must stay green (names):** `NativeCaptureCoordinatorTests` (pts-domain tests :1044-1084,
`identityChangeRebuildsMakeBeforeBreak` :554), `SyncedLocalFanoutTests` (Goertzel
self-exclude :193/:244, identity passthrough :369, `…releasesAtComputedTarget_noExtraDelay`
:473), `BTSyncedSinkTests` (:92, :105, :134, :165), `NativeBackendTests`,
`NativeBackendBTSelectionTests`, `NativeBackendSyncedLocalSelectionTests`,
`NativeBackendBTDevicesTests`, `NativeBackendBTAlignmentInterceptTests`,
`AlignmentTickInjectorTests`, `GroupControllerTests`, `PopoverControllerTests`,
`PopoverDeviceVisibilityTests`, `DeviceBluetoothKindTests`, the four `Cast*Tests`.
Run via `bash scripts/run-tests.sh --filter <Suite>`.

**New tests that prove the degenerate case**
1. *Byte identity* (`NativeCaptureCoordinatorTests`, uses the existing recording `SpySink`
   :137-141 and `makeSequencedCoordinator(sink:)` :529): drive 200 fake buffers through
   (a) a coordinator that never hears of Cast and (b) one that had `setAirPlayPreDelay(ms: 0)`
   and `setCastSink(nil)` called; `#expect(a.forwarded == b.forwarded)` on bytes **and** pts.
2. *Bypass is structural*: a `test_` seam asserting the published snapshot's
   `airPlayPreDelay == nil` after `ms: 0`, non-nil after `ms: 1`, nil again after `ms: 0`.
3. *Backend never installs a line without Cast* (`NativeBackendTests`' `FakeCapture` :902
   records calls): across AP-only, AP+BT, AP+Mac, BT-only, BT+Mac, `setAirPlayPreDelay`
   is never called with `ms > 0` and every BT composition carries `castPresent == false`.
4. *Reduction table* (§3) as a parametrised `SyncTiming`/`BTReferenceTimeline` test: with
   `castTerm = nil` the N-way helper returns today's numbers for all six compositions.
5. *Line semantics* (`PCMDelayLineTests`): cadence preserved (out count == in count), grow
   emits zeros not history, shrink drops, delay-0 is a different object path (nil).
6. *Room policy* (pure): synthetic lead series from the spike (1.4 → 5.5 with stalls) → R
   changes exactly once; a +2 s stall with `D_cast ≥ 2` → Cast skip, R unchanged.

**Live checklist (Alec + Streamer + `cast-spike`):** AP-only before/after the branch sounds
and measures the same (`AIRPLAY_DEBUG_LATENCY=1` pts-age unchanged); Cast join → one gap on
AirPlay, Cast silent ~13 s then aligned by ear (ticks via the wizard); Cast leave → AirPlay
jumps, no silence, no reconnect; pull the Streamer's Ethernet mid-song → Cast fails, AirPlay
untouched; 30-min soak → lead flat, at most one Cast blip; sleep/wake with Cast selected.

---

## 10. Phasing — AirPlay-touching changes land last and smallest

| Phase | Content | AirPlay path touched | Parallel? |
|---|---|---|---|
| **(i) Cast transport, unsynced** | `Device.Kind.cast`, discovery ingest, `CastOutputManager` (connect/launch/LOAD no-autoplay/PLAY/status/volume) built on `CastSender`, `setOutputSet` third arm + guard, `setCastSink` fan-out, failure causes, popover section, `NSBonjourServices`. Cast plays ~5.5 s late; nothing else moves. | Guard term + one `if let` after the write (both inert) | Yes: (a) manager/protocol, (b) Device/discovery/UI, (c) backend arm + fan-out — three worktrees, one merge |
| **(ii) N-way timeline, inert** | `castPresent`, `castTermMs` + `max` terms, `PCMDelayLine` + `BufferSnapshot` field + `setAirPlayPreDelay`, ring-capacity bumps, tests 1–5. Never installed (castTerm stays nil). | Yes — the snapshot field and the `if let`, proven identical by tests 1–3 | After (i-c); `PCMDelayLine` + its tests can start immediately |
| **(iii) Activation** | Room-delay controller (§4), Cast feed line + mute-until-settled, join/leave choreography (§5), `applyStartBuffer` hook, test 6. | Only through already-tested seams | Serial, one worktree |
| **(iv) Trim / wizard / UI** | Trim store reuse, Cast SYNC column, wizard hosting, ±1000 range, "can't sync" badge. | No | Parallel with (iii) |

Merge (ii) only with tests 1–3 green and the live "AP-only sounds the same" check done;
that is the one gate the invariant actually depends on.

**Constraints restated:** all new in-app Cast code license-clean (banner precedent
`SyncCore.swift:1-8`; never copy from `SyncedLocalSink.swift`); zero new dependencies;
tests through `run-tests.sh --filter`; `dev/notes/` owns the briefs; `main` untouched.

**Decision (Alec, 2026-08-22):** design approved. Cast-join gap on AirPlay = **silence**
(not replay), as specified in §5. Phase (i) may run as three parallel worktrees.
