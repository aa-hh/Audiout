I have everything needed. Here is the diagnosis.

---

# Cast v1 live-test diagnosis — root causes + fix specs

All line numbers are in the worktree at HEAD `76bbc2e4`. The dominant finding is one bug that explains the instability, the PAUSED storms, and the "one success / two failures" pattern.

---

## PRIMARY ROOT CAUSE — the 10 s silence watchdog races Cast's ~10 s startup and starves the feed

**The reasoning chain from the log.** Every attempt in the telemetry shows the capture tap stopping ~10.0 s after the select, *regardless of what Cast is doing*:

| select (`set_output_set [TV]`) | tap `capturing→stopping` | Δ | cast `playing` |
|---|---|---|---|
| 40:33.839 | 40:43.840 | **10.00 s** | 40:44.763 (0.9 s *after* the stop) |
| 41:53.667 | 42:03.669 | **10.00 s** | 42:06.365 |
| 42:56.850 | (deselected) | — | never |
| 43:05.634 | 43:15.683 | **10.05 s** | never → failed |
| 47:11.308 (sid 340E) | 47:21.387 | **10.08 s** | never → failed |

That 10.0 s is not a coincidence — it is `NativeBackend.defaultSilenceFallbackDelay = 10` (`NativeBackend.swift:723`). On select, `setOutputSet` arms the silence watchdog (`NativeBackend.swift:2601`) because the desired non‑local device is "stranded": `desiredDeviceAudibleLocked` for a `.cast` id returns `castPlaying.contains(id)` (`NativeBackend.swift:6295`), which is **false until the receiver reports PLAYING**. Cast's measured connect→PLAY floor on this hardware is ~10 s (connect + `getReceiverStatus` + server start + **~2.7 s LAUNCH** + LOAD + **~5.5 s receiver buffering** — see the spike logs `ctrl-wav-na.txt`/`wav-noise-na.txt`, `load_to_playing ≈ 4.5–5.4 s` *plus* the 2.7 s launch). So the watchdog's 10 s and Cast's ~10 s are a dead heat.

When the watchdog wins, `fireSilenceWatchdog` sets `silenceCaptureOverride = true`, and `reconcileCaptureGate` computes `want = !suspended && !silenceCaptureOverride && …` = **false** (`NativeBackend.swift:7842`), so it calls `coordinator.stop()` — the tap stops. The Cast feed depends entirely on that tap: `CastFanOut`/`CastFeedRing` are fed only from the IOProc (`NativeCaptureCoordinator.swift:1214`, `castSink.write`). Tap off ⇒ no `push` ⇒ the ring starves ⇒ `CastFeedRing.render` zero‑fills silence (`CastOutputManager.swift:86‑105`). The `write_cadence_drift` deltas confirm the gap precisely: attempt 1 jumps `deficitDeltaSeconds 1.108` at 40:46.127, right after the tap restarts (40:44.845) when Cast's PLAYING cleared the override.

**Consequence 1 — the PAUSED storm (Signature A: reached PLAYING, then PAUSED forever).** The ~1 s feed gap underruns the receiver's media element. The stock Default Media Receiver then pauses to rebuffer — and because our server paces at exactly real‑time rate (wall‑clock pacing, `CastLiveAudioServer.swift:227‑246`), the receiver can **never** rebuild its buffer ahead of playback (the pathological live‑source case the spike already documented). It sits PAUSED indefinitely. Nothing in our code sends PAUSE — `grep` confirms `CastClient.pause` is called only by `CastSpikeRun`, never by `CastOutputManager`, and `CastOutputManager.handle(_:)` reacts only to `PLAYING` and to `IDLE`‑after‑playing (`CastOutputManager.swift:380‑394`); a `PAUSED` status is logged and otherwise ignored.

**Who paused, and when.** The receiver paused itself (buffer underrun → rebuffer stall). The PAUSED runs are **before** the deselect: attempt 1's PAUSED spans 40:44.763→41:47.898, and Alec's deselect (`removed [TV]`) is at 41:48.502, with the teardown `idle` at 41:48.579. So the PAUSED is not our teardown — it is the receiver reacting to the feed gap the watchdog created.

**Consequence 2 — the nondeterminism ("one success, two failures").** It is a genuine race. When Cast reaches PLAYING a beat before the 10 s mark (or the receiver's buffer happens to absorb the gap — attempt 2 at 41:53 recovered and played 16 s steady at 5.47 lead), it works. When the watchdog fires first, the session stalls or dies. Same code, different timing ⇒ intermittent.

### Fix spec — Primary

**Goal:** a desired Cast session that is still legitimately starting up (connecting/buffering, within its own `playDeadline`) must not count as "stranded," so the watchdog never stops the feeding tap out from under it. The session's own 15 s `playDeadline` (`CastOutputManager.swift:153`) already handles a genuinely dead receiver — on failure it emits `.failed`, at which point the row is not audible **and** not connecting, and the fallback can legitimately arm.

**Change (one place — the shared stranded predicate):** `NativeBackend.desiredDeviceAudibleLocked(_:)` at `NativeBackend.swift:6292‑6297`. Treat a Cast id as "not stranded" while its session is still making progress:

```swift
if device.isCast {
    if castPlaying.contains(id) { return true }
    // A Cast session legitimately takes ~10 s to reach PLAYING (launch +
    // receiver buffering). While it is still connecting it is NOT stranded —
    // the session's own 15 s playDeadline fails it if the receiver is dead,
    // and a .failed row (not .connecting) then arms the fallback correctly.
    if case .connecting = known[id]?.connectionState { return true }
    return false
}
```

This is the smallest correct fix: it reuses the existing `.connecting`/`.failed` row state (already driven by `applyCastSessionState`, `NativeBackend.swift:2919`) rather than adding a Cast‑specific timer. A receiver that never connects still transitions `connecting → failed` at the 15 s deadline, `desiredDeviceAudibleLocked` then returns false with `connectionState == .failed`, and `reconcileSilenceWatchdog` arms the countdown as designed (R11 preserved).

**Why not just raise the 10 s delay:** the delay is deliberately fixed as a safety net (`NativeBackend.swift:718‑723`) and is shared with AirPlay/BT; raising it globally would leave a dead AirPlay group silent longer. Gate on Cast's own progress instead.

**Tests** (swift‑testing, extend `NativeBackendCastTests.swift`; the rig already injects `watchdogScheduler`/`silenceFallbackDelay` via the `NativeBackend` init at `NativeBackend.swift:1303‑1304`, and `test_silenceWatchdogArmed` exists at `NativeBackend.swift:5910`):
- `func connectingCastSessionDoesNotArmTheSilenceWatchdog()`: fire the record, `setOutputSet([id])`, `manager.fire(.connecting)`; assert `!backend.test_silenceWatchdogArmed` even after the fallback delay elapses (inject a short `silenceFallbackDelay`, e.g. 0.05 s, and a real scheduler, then `waitFor`). This is the regression that would have caught the live bug.
- `func failedCastSessionStillArmsTheWatchdog()`: `setOutputSet([id])`, `manager.fire(.failed(.timedOut))`; assert `backend.test_silenceWatchdogArmed` becomes true — proves R11 is intact.
- Keep the existing `aLatePlayingAfterDeselectLeavesTheRowOff` green (it asserts a re‑selected, still‑`connecting` receiver arms the watchdog *only* because it re‑selects into `.connecting` and then fires `.playing` late; verify the new predicate doesn't break it — it re‑arms on the re‑select before any `.connecting` state is set, so review this test's timing and adjust if the new `.connecting` gate changes it).

**Verify:** `bash scripts/run-tests.sh --filter NativeBackendCastTests`

---

## SECONDARY — Signature B (IDLE → IDLE → failed, no BUFFERING) is a teardown/relaunch race the log cannot fully resolve

**What the log shows.** The pure failures (attempt 5 at 43:05, and the fresh app session 340E at 47:11) go `connecting → IDLE, IDLE → failed`, never BUFFERING. Both immediately follow a prior teardown: attempt 5's `connecting` (43:05.761) lands ~0.8 s after attempt 4's deselect/`idle` (43:04.918). Alec saw the receiver launch and show "trying to stream," so LAUNCH succeeded; but the receiver never fetched (no BUFFERING, no PLAYING).

**Why I can't pin it from these logs, and the two live hypotheses.** The manager logs neither the LOAD reply, the PLAY send, nor whether the HTTP GET arrived, so two causes are indistinguishable here:

1. **Stale DMR / relaunch race.** On deselect, `CastOutputManager.teardown` (`CastOutputManager.swift:485‑522`) sends `stopMedia → stopApplication → channel.close()`. On an immediate re‑select, `applyCastTransition(enable:true)` → `manager.setDevices([record])` builds a **new** `Session` with a **new** `CastChannel` (`startRecipe`, `CastOutputManager.swift:277‑291`) while the previous session's STOP may still be in flight on the old channel. A `LAUNCH` of an already‑running Default Media Receiver returns the *existing* app's `transportID`/`sessionID`; the new virtual CONNECT + LOAD then land on an app that the receiver is simultaneously tearing down ⇒ IDLE, no fetch. The tight temporal correlation (every Signature‑B failure follows a teardown by <1 s) points here.
2. **Receiver never reached our server.** The server binds to `session.channel?.localIPv4Address` (`CastOutputManager.swift:305`) and the URL uses that host + the fresh port. If the reported local IPv4 is a stale/wrong interface for that attempt, the TV's GET never arrives — same IDLE‑only signature. (Note: `CastMediaStatus.parse` maps an empty `status:[]` to IDLE — `CastClient.swift:62‑65` — so a `LOAD` that was *accepted but idle* and a `LOAD` that produced *no media session* both read as IDLE to us. A `LOAD_FAILED`/`INVALID_REQUEST` reply, by contrast, has `type != MEDIA_STATUS` and would fail the session immediately via `.media` stage — `CastClient.swift:205` — which we do **not** see; the failures ride the full ~15 s `playDeadline`, so LOAD was either accepted‑but‑idle or silently unanswered.)

### Fix spec — Secondary (diagnostic‑first, then a minimal serialization)

**Step 1 — make the next live run conclusive. Add three telemetry events** (all in `CastOutputManager`, category `.cast`, keyed by `device`):
- In `afterLaunch` on `.success` (`CastOutputManager.swift:342‑345`): `cast_launch_ok` with `transportID`, `sessionID`, `appID`. Reselect getting the **same** `transportID`/`sessionID` as the just‑torn‑down session is the smoking gun for hypothesis 1.
- In the `load` completion (`CastOutputManager.swift:356‑367`): `cast_load_reply` with `playerState`, `mediaSessionID` (or, on `.failure`, the error) — and a `cast_play_sent` when `play(...)` is issued.
- In `afterReceiverStatus`, log the chosen stream host + the server's bound port once it starts (`afterServerStart`, `CastOutputManager.swift:323‑333`): `cast_server_ready` with `host`, `port`. And wire the server's existing `onRequest` (currently only `session.ring.reset()`, `CastOutputManager.swift:316`) to also emit `cast_http_request` on the **first** GET. Presence/absence of `cast_http_request` cleanly separates hypothesis 1/accepted‑but‑stalled from hypothesis 2/never‑reached.

**Step 2 — the likely fix (apply once telemetry confirms hypothesis 1), minimal:** serialize relaunch behind the prior teardown for the same id. In `CastOutputManager`, when `setDevices` re‑adds an id whose previous `Session` is still tearing down, defer `startRecipe` until `teardown`'s `finish` closure (`CastOutputManager.swift:509‑512`) has run (channel closed + server stopped). Concretely: have `teardown` take a completion, and gate the new `startRecipe` on it (or hold a per‑id "teardown in flight" flag and start the recipe from the teardown completion). This guarantees the receiver has processed STOP before the next LAUNCH, so LAUNCH starts a clean DMR instance. `razor:` mark this as the ceiling — a fixed settle delay would also work but is flakier; prefer the completion chain the teardown already has.

**Tests:** extend `CastOutputManagerTests.swift` (drives the real recipe against `CastFakeReceiver`). Add `func rapidReselectRelaunchesCleanly()`: select → wait for PLAYING → deselect → immediately re‑select → assert the second session reaches PLAYING (and, if Step 2 lands, assert the second LAUNCH observed a fully‑closed prior channel). The fake receiver at `FakeCastReceiver.swift:285` already models LOAD→BUFFERING→fetch→PLAYING and STOP→IDLE, so a reselect race is reproducible in‑process.

**Verify:** `bash scripts/run-tests.sh --filter CastOutputManagerTests`

---

## Gray icon — there is no per‑kind tint bug; the "disabled" look comes from row state, not the Cast glyph

**Evidence against a Cast‑specific tint bug.** `DeviceRowView` tints every device icon unconditionally: `iconView.contentTintColor = Tokens.Color.secondaryLabel` (`DeviceRowView.swift:556`), with a comment "The icon is ALWAYS neutral … no accent-when-selected fill." There is exactly one write to `iconView.contentTintColor` in the file (confirmed by grep), no branch on `kind`, `isAvailable`, `connectionState`, or `supportsAirPlay2`. The Cast symbol `tv.and.hifispeaker.fill` (`Device.swift:52`) is a `.fill` template symbol exactly like the AirPlay kinds (`appletv.fill`, `hifispeaker.fill`, `Device.swift:40‑42`) and BT (`hifispeaker.2.fill`), so the rendering mode is identical. **A Cast icon and an unselected AirPlay icon render the same gray.**

**So what makes it read "disabled."** Two candidates, and the log can't yet distinguish them:
1. **Row availability.** If the Cast row is `isAvailable == false`, the whole row renders disabled — `rowTextColor` returns `disabledControlTextColor` for `!isAvailable` (`DeviceRowView.swift:1898`) and the checkbox/slider disable — while the icon stays `secondaryLabel`, so the icon looks "disabled" next to a normal row. This is plausible for **this specific device**: the Cast browse for the wired Google TV Streamer "reached the Mac only intermittently" (spike log; `applyCastSnapshots` flips `isAvailable=false` the instant a browse omits it, `NativeBackend.swift:7083‑7087`).
2. **No connection halo/armed dot.** Connected AirPlay rows draw the `haloRingView` (`DeviceRowView.swift:566`) and lit `armedDotView` (`DeviceRowView.swift:600`); a Cast row that is `.off`/`.connecting`/stuck shows neither, so it reads as "inert" beside a lit AirPlay row.

**Fix spec.** Add one diagnostic and defer the visual change until it resolves the ambiguity:
- **Diagnostic:** in `applyCastSnapshots` (`NativeBackend.swift:7067`) and `applyCastSessionState` (`NativeBackend.swift:2919`), emit `cast_row_state` (`.cast`) with `isAvailable` and `connectionState`. The next run shows whether the "TV" row was actually `!isAvailable` while it looked gray.
- **If it is availability flapping (hypothesis 1):** don't drop a Cast device to unavailable on a single missed browse — a wired Cast device advertises intermittently. Debounce the `!present` → `isAvailable=false` transition in `applyCastSnapshots` (`NativeBackend.swift:7083‑7087`) behind a short grace (e.g. keep `isAvailable=true` until N consecutive browses omit it, or a few‑second timer), mirroring the "kept vanished" intent already there. Test: extend `NativeBackendCastTests.snapshotSurfacesCastRowsAndKeepsVanishedOnes` to assert one missed snapshot does **not** immediately flip `isAvailable`.
- **If it is the missing halo (hypothesis 2):** that is a deliberate design (icon is always neutral; status reads from ring/dot) — not a bug; no code change, it's a design decision for Alec.

**Verify:** `bash scripts/run-tests.sh --filter NativeBackendCastTests`

---

## Volume on a `controlType: "fixed"` receiver — parse it, and apply fixed‑receiver gain in the feed instead of `SET_VOLUME`

**Root cause.** We always send `SET_VOLUME` (`CastOutputManager.issueLevel → CastClient.setVolume`, `CastClient.swift:106‑108`), and `CastReceiverStatus.parse` does **not** read `controlType` at all (`CastClient.swift:34‑52` — only `level` and `muted`). The Streamer's RECEIVER_STATUS carries `volume.controlType` = `fixed` (HDMI/CEC‑dependent; the spike also saw `attenuation`). With `fixed`, `SET_VOLUME` is a no‑op and the TV shows the "use the remote to adjust the volume" notice — exactly Alec's symptom (5).

**Fix spec.**

1. **Parse it.** Add `public let volumeControlType: String` to `CastReceiverStatus` and read `volume["controlType"] as? String ?? "attenuation"` in `parse` (`CastClient.swift:34‑52`). Surface it up: capture it in `afterReceiverStatus` (`CastOutputManager.swift:301‑321`) onto the `Session` (new `var volumeControlIsFixed: Bool`).

2. **Route the composed level by control type.** In `pushLevel`/`issueLevel` (`CastOutputManager.swift:415‑436`): when `attenuation`/`master`, keep `SET_VOLUME` (17 ms round trip, unchanged). When `fixed`, do **not** call `setVolume`; instead set a per‑session PCM gain used by the feed. The composed level is already the full `Main × Group × Device`, mute = 0 (`NativeBackend.castLevel(forID:)`, `NativeBackend.swift:2439`), so no additional composition is needed.

3. **Where the multiply goes.** Apply it in `CastFeedRing.render(frames:)` (`CastOutputManager.swift:86‑105`), which runs on the server's consumer queue (off the capture IOProc, as requested). Store an `atomic`/lock‑guarded target gain and a running "current gain" on the ring; in `render`, after the `memcpy`, walk the produced `Int16` samples applying gain with a **per‑block linear ramp capped at ≤20 ms** (≤882 frames at 44.1 kHz) from current→target, then hold — this avoids zipper noise on a fader drag and clipping (gain ∈ [0,1], so scaling `Int16` down never overflows; clamp defensively to `[-32768, 32767]`). Reset current‑gain to target on `reset()` so a fresh GET starts at the right level. Only fixed‑receiver rings ever get a non‑unity gain; attenuation receivers keep gain = 1 and the fast `memcpy` path is unchanged (guard the ramp behind `gain != 1 || rampInProgress`).

   `razor:` ceiling — a single scalar gain with a linear ramp; if a fixed receiver later needs mute‑click suppression or dB mapping, extend the ramp target logic here, not at the call sites.

4. **Wire it.** `CastOutputManager.pushLevel` sets `session.ring.setTargetGain(level)` when `volumeControlIsFixed`, else `issueLevel(...)`. Keep the existing latest‑wins coalescing for the `SET_VOLUME` path untouched.

**Tests** (`CastOutputManagerTests.swift`, in‑process against the fake):
- `func fixedReceiverAppliesGainInTheFeedNotSetVolume()`: have `FakeCastReceiver` report `controlType: "fixed"`; drive `setLevel(0.5)`; assert **no** `SET_VOLUME` reached the receiver (add a counter to the fake) and that rendered PCM amplitude ≈ 0.5× (feed a known full‑scale block through the ring and assert the peak).
- `func attenuationReceiverStillUsesSetVolume()`: `controlType: "attenuation"`; assert `SET_VOLUME` is sent and ring gain stays unity.
- `func fixedReceiverGainRampsWithoutZipper()`: unit‑test `CastFeedRing` directly — jump target 1.0→0.0 and assert the first block ramps monotonically over ≤882 frames rather than stepping.
- Update `NativeBackendCastTests.volumeAndMuteReachTheManagerComposed` only if the composed value now routes differently for fixed (it should still call `manager.setLevel` with the same composed value — the fixed/attenuation split lives *inside* the manager, so this backend‑level test is unaffected).

The fake receiver will also need a `SET_VOLUME` handler that records the control type it advertises (`FakeCastReceiver.swift:252` already has a `SET_VOLUME` case and `285` the LOAD path) — extend it to advertise `controlType` in its RECEIVER_STATUS and to count `SET_VOLUME`s.

**Verify:** `bash scripts/run-tests.sh --filter CastOutputManagerTests` and `bash scripts/run-tests.sh --filter NativeBackendCastTests`

---

## Full verification list for an executor
```
bash scripts/run-tests.sh --filter NativeBackendCastTests
bash scripts/run-tests.sh --filter CastOutputManagerTests
bash scripts/run-tests.sh --filter CastFakeReceiverLoopTests
bash scripts/run-tests.sh --filter PopoverDeviceVisibilityTests   # if the icon/availability fix lands
```

## Priority for the next live run
1. **Ship the Primary fix** (`desiredDeviceAudibleLocked` Cast‑connecting gate) — it is the one confirmed, deterministic cause of the instability/PAUSED/nondeterminism, and it is a ~6‑line change in a shared function with a clear regression test.
2. **Add the Secondary + icon telemetry** (`cast_launch_ok`, `cast_load_reply`, `cast_play_sent`, `cast_server_ready`, `cast_http_request`, `cast_row_state`) *before* touching the teardown/relaunch serialization or the availability debounce — the current log genuinely cannot distinguish the Signature‑B causes, and these six events make the next run conclusive.
3. **Volume fixed‑receiver fix** is independent and can land in parallel.

One caveat on my own confidence: the Primary fix is proven from the log. The Secondary (teardown race) and the icon cause are *hypotheses* the telemetry additions are designed to confirm — I have flagged exactly which event distinguishes each, rather than asserting a cause the log doesn't support.