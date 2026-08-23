# Plan — Universal Sync: Bluetooth speakers as a first-class output

Status: **PLAN ONLY — no code written.** All 6 planning decisions locked by Alec 2026-07-24 (see "Decisions locked").
Author in a dedicated worktree/branch off `main`; `main` is merge-only (never `git commit` on main). Merge only after Alec live-tests and explicitly says go (standing rule — especially here: real-time-audio correctness + a new Bluetooth permission).

Goal: make a **Bluetooth speaker feel as natural to add, group, and sync as an AirPlay device** — analyzed critically/antagonistically so every Bluetooth inconvenience is designed around, not hand-waved.

---

## Decisions locked (2026-07-24)

1. **Quality bar = "blend, not phase-lock."** Tight enough that BT + AirPlay across rooms sounds like one system and same-room BT+BT blends without slap-echo (~<20 ms alignment; drift held so any beating swells slower than ~7 s). Explicitly **not** studio-grade/phase-perfect (physically impossible over A2DP) and **not** lip-sync-to-video.
2. **v1 scope = both BT-only and BT-mixed-with-AirPlay.** BT-only (Mac → BT speaker(s) on the Mac's own clock) is the simpler sync case and users expect it; BT-mixed is the harder/more valuable case. Ship both; treat BT-mixed as the primary tested path.
3. **Reconnect = auto-connect, then fall back.** Attempt `IOBluetoothDevice.openConnection()` for an already-paired-but-disconnected speaker; if it doesn't return as an audio device within a few seconds, one-tap deep-link into Bluetooth Settings. (Pairing itself is an unavoidable one-time Settings trip — Apple owns it.)
4. **Magic-pair auto-offset = fast-follow.** v1 ships a genuinely good MANUAL offset flow (per-device ms + A/B "nudge until it blends", seeded by a per-brand table). Add mic-loopback auto-offset only after `BT-SPIKE-OFFSET` proves it survives on real hardware.
   **AMENDED 2026-08-07 (Alec): auto-offset is CUT, not fast-follow.** The Mac's mic position is uncontrollable — it may not hear all speakers (different rooms is our GOOD case) and can't identify which speaker is which. Revisit only if Alec raises it. Consequences: `BT-SPIKE-OFFSET` and `BT-OFFSET-AUTO` are removed from the task list; the R-A2DP/HFP risk shrinks to runtime HFP *detection* (BT-RECONNECT) only; manual offset (BT-OFFSET-UI) is the shipping story, sharpened by the 2026-08-07 research (`dev/notes/bt-output-research-2026-08-07.md`): signed numeric ms, ±500 ms, 10 ms coarse / 1 ms fine, tuned live while music plays, persisted per device UID, per-brand seeds, plus the A/B alternating-click aid (no competitor ships one). Research also notes every product that automated calibration still kept manual as the fallback — manual-only is a complete product, not a stopgap.
5. **License = extract a clean shared `SyncCore`.** Pull the pure timing + drift-control (PI) math into a new clean-room file (no GPL header) consumed by BOTH the Mac-local sink and the BT sink; each sink's `AVAudioEngine` wiring stays in its own file. (Note: the shipping binary is already GPL via OwnTone/RAOP — this is about keeping the individual BT sender FILE relicensable/clean, per Alec's discipline.)
6. **Sequencing = land Mac-sync (synced-local-airplay) to `main` first,** then build BT on top of its proven delayed-sink + continuous drift-correction machinery. Avoids re-inventing the grandmaster/hostTime/PI loop and avoids two unmerged real-time-audio branches editing the same hot files.

---

## A. End-state overview

Bluetooth speakers become a first-class Audiout output type that a user adds, groups, and syncs with the same mental model as AirPlay: a BT speaker appears in the device list, can be dropped into a group alongside AirPlay devices and the Mac, stays **visible-but-greyed** when off/out-of-range (never vanishes), and reconnects with at most a single tap. Audio is kept aligned by treating the AirPlay presentation timeline (which we author as PTP **grandmaster**) as the reference and rendering each BT speaker through a per-device, deliberately-delayed app-layer `AVAudioEngine` sink — pinned to that speaker's Core Audio device, offset by a per-device latency figure, and held from drifting by the same continuous rate-correction loop the Mac-local sink uses. When no AirPlay device is present the Mac's own `hostTime` becomes the reference. The honest quality bar (Decision 1): "sounds like one system" — excellent across rooms, good for same-room casual listening, not sample-accurate for same-room BT+BT, and not lip-sync to video.

## B. Feasibility verdict — **GO-WITH-CAVEATS, gated by two hardware spikes**

**Core routing/sync: GO.** One `AVAudioEngine` per BT Core Audio device, pinned via `setDeviceID`, fed the same captured PCM+pts as AirPlay and delayed to the reference timeline, is proven by the `bt-multi-spike` harness (N engines alive + audible, per-device delay nudge works, real-DAC drift meter reads ~30 ppm on built-in). The clock machinery already exists (grandmaster + `mHostTime`↔`CLOCK_MONOTONIC` rebase at `NativeCaptureCoordinator.swift:1049-1093`; presentation delay is a constant we set). **Verified good news:** BT is *non-local*, so `GroupController` already permits BT-in-a-mixed-set (the `localMixRefusalReason`/`wouldMixLocalWithAirPlay` block at `GroupController.swift:210-215,255-256` only refuses `isLocalDevice==true`), and `reconcileCaptureGate` (`NativeBackend.swift:3140-3141`) already trips the tap for any selected non-local device — much less friction than the Mac-local sibling fights.

**Q-CONNECT (the make-or-break UX question) — answer:** **Pairing must be user-driven in System Settings — no public no-UI pairing API; treat as fixed.** **Connecting an already-paired-but-disconnected speaker is *probably* automatable** via `IOBluetoothDevice.openConnection()` (opens a baseband connection); whether that reliably re-establishes A2DP *and* re-exposes the speaker as a Core Audio output is **not guaranteed by docs and varies by speaker/OS — `BT-SPIKE-CONNECT` must prove it on real hardware.** Requires the Bluetooth entitlement (`com.apple.security.device.bluetooth`), an `NSBluetoothAlwaysUsageDescription` Info.plist string, and triggers a Bluetooth TCC prompt (classic IOBluetooth access gated starting ~macOS 14 Sonoma — confirm exact version in the spike). Guaranteed fallback that always works: deep-link `x-apple.systempreferences:com.apple.BluetoothSettings` (Ventura+) + a clear nudge. We can read connected/paired state and connection notifications to keep the row's greyed/available state accurate.

**Q-OFFSET-AUTO (the "magic pair" investigation) — answer:** **Feasible in principle but sits on top of a macOS trap that can kill it — spike-gated, shipped as fast-follow (Decision 4).** The probe (emit a chirp/click to the BT speaker, record via the Mac mic, cross-correlate for round-trip, subtract known paths) requires playing A2DP *while* recording — and macOS forces a BT device to narrowband **HFP** whenever *its own* mic is opened, which would corrupt the probe and even steal system input. Mitigation: **pin recording to the Mac's built-in mic, never the BT device's mic** — the HFP downgrade is triggered by requesting the *BT* input, so a built-in-mic probe *should* leave A2DP intact. "Should" is the whole risk: **`BT-SPIKE-OFFSET` must prove on real hardware that A2DP output survives while the built-in mic records.** If it doesn't, mic auto-offset is dead and we ship manual + brand-seed table (a perfectly good product). `kAudioDevicePropertyLatency` on BT is commonly misreported — a weak prior only, never the truth.

**Q-SYNC-CLOCK (how BT + AirPlay "share one clock" without PTP) — answer:** BT never shares a clock in the AirPlay sense. Instead — **reference-timeline scheduling.** AirPlay present → the AirPlay presentation timeline (~2 s buffer, authored by us as grandmaster) is the reference; each BT speaker is delayed by `presentationDelay − perDeviceBTOffset (+ userOffset)` (≈1.7–1.8 s) so its sound lands at the same wall-clock instant, then continuous ppm rate-correction (the sibling's PI loop, driven by the BT device's real DAC clock via `AudioDeviceGetCurrentTime`) nulls residual drift. BT-only → the Mac's `hostTime` is the reference (small fixed buffer + per-device offset + drift correction; no 2 s AirPlay delay). BT + Mac-local + AirPlay → AirPlay stays the single reference; both the Mac-local sink and every BT sink delay to it (one reference, many delayed sinks).

**Caveats that gate the GO:** (1) programmatic-connect reliability — `BT-SPIKE-CONNECT`; (2) mic-loopback auto-offset survivability — `BT-SPIKE-OFFSET`; (3) same-room BT+BT and video lip-sync are **stated limitations, not bugs**; (4) distribution is Developer-ID/notarized, so App Sandbox multi-BT legality is **moot** (note only).

## C. The "add a Bluetooth device" user journey

1. **Discover.** List BT speakers macOS already knows (paired): merge Core Audio enumeration (transport == Bluetooth, aggregates excluded) with the IOBluetooth paired-device list. A never-seen speaker isn't ours to conjure.
2. **Pair (one-time, unavoidable Settings trip).** If not yet paired, the row offers "Pair in Bluetooth Settings…" → deep-links `x-apple.systempreferences:com.apple.BluetoothSettings`. **The one moment we cannot remove** — Apple owns pairing. Make it a single labeled tap and, on return, auto-detect the newly paired device (connection notification) so the user lands on a ready row.
3. **First connect + Bluetooth permission.** First IOBluetooth touch triggers the Bluetooth TCC prompt (usage string explains why). Once paired+connected, the speaker is a normal selectable row.
4. **Add to a group / select.** Identical to AirPlay: toggle it on, or drop it into a group with an AirPlay device and/or the Mac. No refusal (BT is non-local). The tap turns on automatically; the BT sink spins up pinned to the device.
5. **Magic-pair auto-offset moment (fast-follow; the "ideally nothing" step).** On first add of a speaker beside the Mac, the app *offers* (or, if configured, silently runs) a ~1–2 s probe: a soft click plays, the built-in mic listens, the per-device offset is computed and saved — the user sees a brief "Tuning sync…" then "In sync." If auto is off/unavailable (v1), seed from the per-brand table (Sonos ~30–50 ms, HomePod ~70–100 ms, generic DAC ~0–30 ms) and expose the manual nudge.
6. **Use.** Plays in sync per the quality bar. The saved offset persists per-device (by UID) across relaunch and reconnect.

## D. The disconnection / reconnection story (mapped to AirPlay's greyed-not-vanished model)

`Device.isAvailable = false` greys the row without removing it (matches the AirPlay model, `Device.swift:44-46`). A `connectionState` (`off/connecting/connected/reconnecting/failed`) drives the dot.

| State | What the user sees | What the app does automatically | What we must ask the user |
|---|---|---|---|
| **Powered off / out of range** | Row greyed, "Disconnected", stays in group | Detect via IOBluetooth `isConnected` + connect/disconnect notifications; mark unavailable; keep group membership | Tap the row to attempt reconnect |
| **Tap-to-reconnect (paired)** | Row spins `.connecting` | `openConnection()`; on A2DP + Core-Audio reappearance within timeout → `.connected`, resume sink | If not back in ~few s → one-tap deep-link to Bluetooth Settings |
| **Stolen by phone / another host** | Greyed, "Connected elsewhere" | Detect not-connected-to-this-Mac; can't politely force-steal | Nudge: reconnect from the speaker or Settings |
| **HFP downgrade (some app opened the BT mic)** | Warning badge: "Call audio in use — sync paused / quality reduced" | Detect transport/format flip to narrowband; pause or de-prioritize the BT sink; auto-restore to A2DP when the mic closes | Optional: "close the app using the mic" hint |
| **Sleep/wake** | Brief reconnect spinner | On `NSWorkspace.didWake`: re-enumerate, re-open connections, rebuild sinks, re-seed drift (mirror sibling T-LIFECYCLE) | Nothing, ideally |
| **Codec/sample-rate renegotiation mid-stream** | No visible change (the danger) | Listen for the BT device's nominal-rate change and **rebuild the sink** — the per-app silent-tap bug (memory) applied to BT | Nothing |

**Design rule:** BT reconnect must feel like AirPlay's — the row never disappears, a single tap is the most we ask, and Settings is the last-resort fallback, not the default.

## E. Universal-sync design

- **Sink architecture: a shared clean-room `SyncCore` (timing math + PI phase controller) consumed by BOTH sinks; the BT sink is a *parallel, N-instance* manager (`BTSyncedSink`), not an extension of the 1-instance `SyncedLocalSink`.** BT needs N independent sinks, each pinned to a distinct Core Audio device with its own per-device offset and its own drift correction (BT DACs drift independently, ±50 ppm, worse than built-in ~30 ppm). Physically merging the two sink classes later (Mac-local = "one BT-style sink pinned to built-in") is a reasonable post-merge cleanup, not a v1 blocker. Satisfies Decision 5 (fresh Apple-only sink file + shared clean-room core).
- **Reference selection:** AirPlay present → AirPlay presentation timeline is reference; BT delayed by `presentationDelay − perDeviceBTOffset (+ userOffset)`, clamped ≥0, read from the *live* engine value (never a hardcoded 250 ms — sibling R4). BT-only → Mac `hostTime` reference, small fixed buffer + offset. Mixed → single AirPlay reference, all sinks delay to it.
- **Drift strategy:** per-device ppm estimate from the BT device's real DAC clock (`AudioDeviceGetCurrentTime` query-first, IOProc fallback — the spike's proven mechanism) fed into the sibling's continuous micro-rate correction (PI loop) to null residual phase, click-free. No hard periodic resyncs (audible).
- **Quality bar per scenario (stated, not buried — Decision 1):** different rooms → **good**; same-room BT + AirPlay → **good** with correct per-device offset; same-room **BT + BT → marginal** (independent DACs; blends but can beat slowly on sustained tones); **video/lip-sync → no**. Display these limitations honestly.

## F. Antagonistic risk register

- **R-A2DP/HFP mic conflict (highest — kills auto-offset if unmanaged).** Opening the BT device's mic downgrades it to narrowband HFP and can steal system input. *Mitigation:* auto-offset probe pins recording to the **built-in mic only**; runtime HFP detection pauses/de-prioritizes the BT sink + shows a badge; **`BT-SPIKE-OFFSET` must prove built-in-mic recording doesn't trip HFP.** *Accepted if spike fails:* no mic auto-offset; manual + brand table.
- **R-single-owner A2DP routing.** Only one app "owns" A2DP routing at the OS level; other apps can grab it. *Mitigation:* detect route loss, grey + offer reconnect; don't fight the OS aggressively (Decision 3 is "auto then fall back," not aggressive).
- **R-silent codec/rate renegotiation desync.** Same family as the per-app sample-rate all-zero silent-tap bug (memory). *Mitigation:* nominal-rate listener per BT device → rebuild sink + reset drift. Explicit test.
- **R-partition bug (central integration risk).** `NativeBackend.setOutputSet` (`:1113-1114`) only routes ids with an AirPlay engine handle; a BT device is non-local **and** has no handle → silently dropped. Any `filter { !isLocalDevice }` (e.g. `GroupController.swift:358,760`) would wrongly hand a BT id to the AirPlay engine. *Mitigation:* partition the output set into {AirPlay receivers → engine} and {BT devices → `BTSyncedSink`}; `supportsAirPlay2=false`; exclude BT from AirPlay-only paths (per-app AP1 exclusion, RTP). Exhaustive tests + backend spy.
- **R-2.4 GHz airtime at N≥3.** BT scheduler degrades past ~4–6 concurrent streams. *Mitigation:* soft cap + a "too many Bluetooth speakers" warning; document the ceiling.
- **R-latency misreporting.** BT devices lie about `kAudioDevicePropertyLatency`. *Mitigation:* weak prior only; manual offset is the day-one escape hatch; auto-offset (fast-follow) supersedes.
- **R-pairing can't be automated.** *Accepted limitation:* one guided Settings trip, made a single tap with auto-detect-on-return.
- **R-sleep/wake + tap-outputNode crash.** Tapping `outputNode` throws an uncatchable AVFAudio exception (spike gotcha) — **tap `mainMixerNode`.** Sleep/wake rebuilds sinks + re-seeds drift.
- **R-echo / feedback loop.** The whole-system tap must exclude every BT sink's render client, or it re-captures delayed output. *Mitigation:* self-exclude (shared with sibling T-FANOUT); Goertzel tone test.
- **R-Bluetooth TCC/entitlement first-run friction.** New permission prompt. *Mitigation:* clear usage string; degrade gracefully to Settings deep-link if denied.
- **R-two-unmerged-audio-branches collision.** synced-local + BT both edit `NativeCaptureCoordinator`/`NativeBackend`/`GroupController` (memory: parallel agents in shared worktrees clobber). *Mitigation:* **Decision 6 — land synced-local first**, removing most of this risk.

## G. Task list

Format matches the sibling `synced-local-airplay-plan.md`. Anchors are from the 2026-07-24 read — re-confirm exact lines before editing.

**BT-SPIKE-COMMIT — preserve the existing spike**
Files: commit `dev/bt-multi-spike/` (currently UNTRACKED in the `.claude/worktrees/bt-multi-spike` worktree — unrecoverable if pruned) onto its branch; add `.build` to ignore.
Kind: chore · Depends on: — · **Model: haiku 4.5 · Effort: low.**
Verify: `git show` lists the 5 spike files + README.

**BT-SPIKE-CONNECT — programmatic connect/reconnect feasibility (hardware gate)**
Files: throwaway harness under `dev/` (extend `bt-multi-spike`) + notes in `dev/notes/`.
What: on real paired hardware, prove whether `IOBluetoothDevice.openConnection()` reliably restores A2DP + a Core Audio output; measure timeout/success across ≥2 brands; confirm the entitlement + `NSBluetoothAlwaysUsageDescription` + TCC-prompt behavior and which macOS version gates it; validate the `com.apple.BluetoothSettings` deep-link + connect-notification round-trip.
Kind: investigation · Depends on: — · **Model: opus 4.8 · Effort: high.**
Verify: written finding + go/no-go; **Alec checkpoint before BT-CONNECT is built.**

**BT-SPIKE-OFFSET — mic-loopback auto-offset feasibility (hardware gate)**
Files: throwaway harness under `dev/` + notes.
What: prove A2DP output **survives while the built-in mic records** (the HFP trap); implement a click/chirp cross-correlation round-trip probe; measure accuracy vs by-ear manual offset across ≥2 brands; characterize failure modes (room reflections, AGC, HFP flip).
Kind: investigation · Depends on: — · **Model: opus 4.8 · Effort: high.**
Verify: finding + go/no-go; **Alec checkpoint before BT-OFFSET-AUTO.**

**BT-DEVICE — `Device.Kind.bluetooth` + UID identity**
Files: `Device.swift` (Kind enum `:14-34`, symbol `:24`, init).
What: add `.bluetooth` kind (confirm an AppKit-valid SF Symbol), a BT `id` from the stable `kAudioDevicePropertyDeviceUID` (survives drop/rejoin), `supportsAirPlay2=false`, an `isBluetooth` helper.
Kind: new-code · Depends on: — · **Model: sonnet 5 · Effort: low.** Hot file `Device.swift`.
Verify: identity-stability + kind-mapping unit test.

**BT-ENUM — production BT enumeration + discovery→model**
Files: new clean-room `AudioutCore/Sources/AudioutCore/BTDeviceEnumerator.swift` (re-derive from the spike, Apple-only) + wire into discovery so BT speakers emit `Device` snapshots via `BackendEvent`.
What: Core Audio devices with Bluetooth transport (aggregates excluded) merged with the IOBluetooth paired list; `isAvailable` reflects connected state.
Kind: new-code · Depends on: BT-DEVICE · **Model: sonnet 5 · Effort: medium.**
Verify: devices appear as rows; aggregate-exclusion + transport-filter unit test.

**BT-GROUPCTL — confirm BT selection semantics (verification, not new refusal logic)**
Files: `GroupController.swift` (`:210-215, 255-296, 358, 760`).
What: BT is non-local → mixing already allowed; **verify** BT+AirPlay / BT+BT / BT-only selection, the current-device floor interplay (`:279-280`), and that `filter { !isLocalDevice }` sites don't misroute BT to the AirPlay engine. Add BT tests; leave the Mac-local refusal untouched.
Kind: backend · Depends on: BT-DEVICE · **Model: sonnet 5 · Effort: medium.** Hot file `GroupController.swift`.
Verify: selection-matrix tests green.

**BT-SINK — per-device delayed BT sink manager**
Files: new clean-room `AudioutCore/Sources/AudioutCore/BTSyncedSink.swift`; shared `SyncCore` (Decision 5).
What: N-instance manager, one `AVAudioEngine` per BT device pinned via `setDeviceID`, delayed on the reference timeline via shared `SyncCore`; per-device offset; tap `mainMixerNode` (NOT outputNode); config-change/rate rebuild.
Kind: new-code · Depends on: BT-ENUM, synced-local T-SINK/T-CORRECTION **landed on main** (Decision 6) · **Model: opus 4.8 · Effort: high.**
Verify: offline harness — known ramp+pts, first-non-silence lands at computed hostTime within tolerance, per device.

**BT-REFSEL — reference-timeline selection**
Files: `BTSyncedSink.swift` / `SyncCore`.
What: AirPlay-presentation reference when AirPlay present; Mac-`hostTime` reference when BT-only; recompute delays on group-composition change.
Kind: new-code · Depends on: BT-SINK · **Model: opus 4.8 · Effort: high.**
Verify: unit tests for each composition (BT-only, BT+AP, BT+AP+Mac).

**BT-DRIFT — per-device drift correction wiring**
Files: `BTSyncedSink.swift`, reuse `SyncCore` PI loop.
What: read each BT device's DAC clock (`AudioDeviceGetCurrentTime` query-first, IOProc fallback — spike mechanism), feed the sibling's rate-correction loop per device.
Kind: new-code · Depends on: BT-SINK, synced-local T-CORRECTION · **Model: opus 4.8 · Effort: high.**
Verify: synthetic-drift unit test converges/holds per device; by-ear in BT-DOCS-LIVE.

**BT-FANOUT — feed capture to BT sinks + self-exclude**
Files: `NativeCaptureCoordinator.swift` (write path ~`:375`), `NativeBackend.swift` tap-exclude.
What: fan the same PCM+pts to every active BT sink (one capture, many consumers); add each BT sink's render client to the tap exclude list (echo prevention).
Kind: backend · Depends on: BT-SINK · **Model: opus 4.8 · Effort: high.**
Verify: Goertzel tone test — tap doesn't re-capture BT output.

**BT-BACKEND — partition the output set + enable/disable sinks**
Files: `NativeBackend.swift` (`setOutputSet` `:1096-1148`, `reconcileCaptureGate` `:3133-3147`).
What: split `expectedSelected` into {AirPlay ids → engine} and {BT ids → `BTSyncedSink`}; enable/disable BT sinks on selection transitions; confirm the capture gate already trips for BT (it does — `:3140-3141`).
Kind: backend · Depends on: BT-FANOUT, BT-SINK, BT-REFSEL · **Model: opus 4.8 · Effort: high** (the R-partition risk lives here; large hot file).
Verify: backend-spy asserts BT sink enable/disable + no BT id sent to the AirPlay engine.

**BT-CONNECT — IOBluetooth connect/reconnect + deep-link fallback** *(only if BT-SPIKE-CONNECT = GO)*
Files: new `AudioutCore/Sources/AudioutCore/BTConnectionManager.swift`; entitlements + Info.plist usage string.
What: `openConnection()` reconnect with timeout → fallback deep-link; availability via `isConnected` + connect notifications; Bluetooth TCC handling.
Kind: new-code/backend · Depends on: BT-SPIKE-CONNECT, BT-ENUM · **Model: sonnet 5 · Effort: medium.**
Verify: greyed row → tap → reconnect (or fallback) on hardware (BT-DOCS-LIVE).

**BT-RECONNECT — disconnection state machine + HFP detection**
Files: `BTConnectionManager.swift`, `NativeBackend` connection-state plumbing.
What: implement the Section-D table; map to `isAvailable` greying + `connectionState`; detect HFP downgrade (transport/format flip) → pause/badge + auto-restore.
Kind: backend · Depends on: BT-CONNECT, BT-BACKEND · **Model: sonnet 5 · Effort: medium.**
Verify: state-transition unit tests + hardware.

**UI SPEC LOCKED 2026-08-07 (Alec, via mockup review — binding for BT-OFFSET-UI and BT-UI):**
Bluetooth devices are their own "Bluetooth Devices" subsection in OUTPUT DEVICES, rows
identical to AirPlay rows (rail/tether select on the left, meter under the name, VOLUME
slider + %, FEED pill far right). **SYNC is a column title in the Bluetooth subsection
only**, sitting between VOLUME and FEED: compact − / bare-ms-value / + stepper (±500 ms,
10 ms steps; value field allows 1 ms typing) plus an align-by-ear icon button —
**`metronome.fill`** SF Symbol (fall back to outline `metronome` if the fill clots at
final size) with a hover TOOLTIP explaining its purpose. Disconnected rows keep their
saved value read-only. **AMENDED same day (Alec): no instructional sublabels** —
BT rows express connection state through the SAME rail/node + ring vocabulary
AirPlay rows already use (greyed row + dimmed hollow node = paired-but-
disconnected; the node's connecting state during a reconnect attempt; failure-
hue ring + failure headline sublabel on `.failed`). "Click to connect" is the
row's ordinary click behavior, never a printed instruction; sublabels stay
reserved for failure headlines ("Connected elsewhere", "Couldn't connect") and
feed info, exactly as AirPlay rows use them.
**Device-tier handling (Alec, 2026-08-07, locked):** (1) remembered/paired but
disconnected → normal greyed row, click connects (the macOS-Bluetooth-menu
behavior; already built + live-tested); selecting a greyed row = "play when
up", auto-starts on connect. (2) pairing record genuinely deleted while app
data (group/trim/icon) still references the id → row survives wherever that
data puts it; click fails fast with a distinct "Not paired" failure headline +
Bluetooth-Settings deep-link suggestion (new `ConnectionFailure.Cause`, UI
wave); never auto-purge — the MAC-derived id resurrects trim + membership on
re-pair. (3) never-paired → NO rows, no scanning (unpairable rows are dead
ends); the OUTPUT DEVICES `+` menu gains "Pair a Bluetooth speaker…" →
`SystemSettingsPane.bluetooth` deep-link, and the row auto-appears on return
(connect notification → enumerator refresh, already built). Hide the Bluetooth
subsection entirely when it would be empty. The align aid plays a REAL metronome-style tick (sharp woodblock
transient — the ear detects double-hits/flams down to ~10–20 ms) on BOTH the reference
device and the BT device on the same beat; the user nudges until the flam collapses to a
single tick. Beat spacing must dodge offset aliasing: at 120 BPM (500 ms) a fully-offset
device sounds aligned one beat late — use ~70–80 BPM (750–850 ms) or a slightly
irregular interval.

**ALIGNMENT WIZARD UX LOCKED 2026-08-08 (Alec — binding for the wizard track):**
Two-tier tuning: the WIZARD is the setup-time path; everyday touch-up is a live
scrubber (separate track, popover surface). Wizard = lateralization bisection —
probe-validated live (clear which-side signal at 7–15 ms even on a broken
baseline; the confusing manual-centre step of the probe does NOT exist in the
wizard, whose bisection self-centres from the answers). **No seed table exists**
(no data source — confirmed by research); a fresh BT speaker's default is raw,
so the FIRST mixed playback is exactly when it sounds wrong. Hence the
**first-mix intercept**: the click that first puts a never-aligned BT speaker
into a mix with any other device connects the speaker and starts its stream but
holds it SILENT; an anchored card (never a modal) explains in one sentence
("Bluetooth speakers each run on their own delay — a quick alignment keeps
everything in step") and offers: (1) Align with your music (unmute both, live
tuning — control design belongs to the touch-up track), (2) Align with ticks
(the wizard: continuous ticks + which-side buttons named after the actual
devices + "Can't tell"; ~5 answers; narrowing progress; ms number shown only as
a closing receipt with Keep / Try again; two "can't tell" = graceful exit
"these speakers are far apart — they're already as aligned as they need to
be"), (3) Not now (unmute, play as-is). The intercept fires ONCE per device
EVER on its own — "Not now" is final, no reminders ("if they're happy, they're
happy"); re-launch stays available forever via the row's metronome button in
the speakers/groups window, and the wizard's closing copy educates the popover
scrubber for everyday touch-ups. Aligned once → trim saved → never intercepted
again. SYNC stepper column placement (popover vs window-only) is deliberately
left to reconcile with the touch-up track's scrubber design — don't move it
until that lands.

**BT-OFFSET-UI — per-device manual offset (numeric ms + nudge) + persistence**
Files: Settings Audio tab (match the existing "Advanced buffer ms" precedent), `AppSettings.swift`, `BTSyncedSink.swift` (consume), per-brand seed table.
What: per-device numeric ms offset (bare number/unit — house rule on numeric controls), an A/B "nudge until it blends" affordance, per-brand seed defaults, persisted per device UID.
Kind: new-code · Depends on: BT-SINK, BT-REFSEL · **Model: sonnet 5 · Effort: medium.**
Verify: changing offset shifts that device live; persists across relaunch/reconnect; store unit test.

**BT-UI — device rows, connect nudge, state display**
Files: `PopoverController`/row views, Groups window.
What: BT rows with correct symbol + greyed/available/HFP badges; "Pair/Connect in Bluetooth Settings…" affordance; "Tuning sync…/In sync" states.
Kind: new-code · Depends on: BT-DEVICE, BT-RECONNECT · **Model: sonnet 5 · Effort: medium** (AppKit row/menu dispatch has bitten this repo — test via real dispatch, memory "Row selection tests bypass AppKit dispatch").
Verify: rows render + toggle through real dispatch on hardware.

**BT-OFFSET-AUTO — mic-loopback magic-pair (production)** *(fast-follow; only if BT-SPIKE-OFFSET = GO)*
Files: new `AudioutCore/Sources/AudioutCore/BTOffsetProbe.swift`.
What: production probe — built-in-mic-pinned click/cross-correlation → per-device offset auto-saved; "Tuning sync…" UX; graceful fallback to manual on low confidence.
Kind: new-code · Depends on: BT-SPIKE-OFFSET, BT-OFFSET-UI · **Model: opus 4.8 · Effort: high.**
Verify: probe offset matches by-ear within tolerance on hardware.

**BT-TESTS — coverage sweep**
Files: new tests in `AudioutCore/Tests/…`.
What: identity stability, enum/aggregate filter, group selection matrix, reference-selection per composition, drift convergence, output-set partition (no BT→engine), tap self-exclude tone test, offset store/persistence, reconnect transitions.
Kind: test · Depends on: BT-BACKEND, BT-DRIFT, BT-REFSEL, BT-OFFSET-UI, BT-RECONNECT · **Model: sonnet 5 · Effort: medium.**
Verify: `swift test --parallel` green; new tests subclass `IsolatedTestCase`.

**BT-DOCS-LIVE — docs + gated by-ear hardware test**
Files: `PROGRESS.md`, `AudioutCore/AGENTS.md`, `dev/notes/`, this plan.
What: document the shipped design + limitations (same-room BT+BT marginal, no video); run the user-present, PTP-port-gated by-ear test: BT+AirPlay blend, BT-only, reconnect flow, HFP badge, offset effect, sleep/wake.
Kind: docs + manual test · Depends on: all above · **Model: haiku 4.5 (docs); the live test is Alec-run · Effort: low.**
Verify: Alec confirms by ear against the Decision-1 bar; findings recorded.

## H. Parallelization

**Hot files (never edit concurrently):** `Device.swift` (BT-DEVICE); `GroupController.swift` (BT-GROUPCTL); `NativeCaptureCoordinator.swift` write path + `NativeBackend.swift` (BT-FANOUT, BT-BACKEND — keep in different waves); `BTSyncedSink.swift`/`SyncCore` (BT-SINK, BT-REFSEL, BT-DRIFT, BT-OFFSET-UI wiring — serialize); `AppSettings.swift`/Settings (BT-OFFSET-UI); row views (BT-UI).

- **Wave 0 (parallel, gates):** BT-SPIKE-COMMIT ∥ BT-SPIKE-CONNECT ∥ BT-SPIKE-OFFSET. Two Alec checkpoints. **Prereq for all production waves: synced-local-airplay landed on `main` (Decision 6).**
- **Wave 1 (parallel):** BT-DEVICE → BT-ENUM ∥ BT-GROUPCTL — different files.
- **Wave 2 (serial foundation):** BT-SINK → BT-REFSEL → BT-DRIFT (same file, serialize).
- **Wave 3:** BT-FANOUT → BT-BACKEND (both touch `NativeBackend`, serialize). BT-CONNECT ∥ here (different file, gated by spike).
- **Wave 4:** BT-RECONNECT ∥ BT-OFFSET-UI ∥ BT-UI ∥ (BT-OFFSET-AUTO if GO).
- **Wave 5:** BT-TESTS → BT-DOCS-LIVE (gated live, last).

**Critical path:** synced-local (T-SINK→T-CORRECTION) landed → BT-SINK → BT-REFSEL → BT-DRIFT → BT-FANOUT → BT-BACKEND → BT-TESTS → BT-DOCS-LIVE. The per-device synced-sink chain is the long pole; the two spikes gate the branches feeding BT-CONNECT and BT-OFFSET-AUTO.

## I. Execution recommendation — **watched agents** (matches the sibling)

Judgment-heavy real-time-audio work with a hard serial audio chain, two built-in hardware go/no-go checkpoints (BT-SPIKE-CONNECT, BT-SPIKE-OFFSET), a dependency on another branch landing first, and a final by-ear gate — not a uniform mechanical fan-out, so a workflow's determinism/barriers aren't earned and mid-flight visibility is valuable. Launch Wave 0's spikes first and **stop for Alec at each checkpoint** (they decide whether BT-CONNECT / BT-OFFSET-AUTO exist at all). Run the mechanical cluster (BT-DEVICE, BT-ENUM, BT-OFFSET-UI, BT-UI, docs) as ordinary agents in their waves. (If Alec later wants that mechanical cluster run with enforced per-task effort/barriers, split it into a small `hybrid` workflow sub-batch — but the real-time chain + gates keep the primary recommendation at watched agents.)

## J. Composition with the two in-flight branches

- **synced-local-airplay (not yet executed; `SyncTiming` stub exists, GPL-marked):** build the grandmaster-referenced delayed sink + PI phase controller here. **Land it to `main` first (Decision 6);** BT reuses its `SyncCore` (extracted clean per Decision 5), never re-inventing the hostTime/PI machinery.
- **bt-multi-spike (uncommitted throwaway):** reuse its *findings* and the enumeration/N-engine/drift-meter approach; **commit it first (BT-SPIKE-COMMIT)** so it isn't lost. Do **not** merge the CLI into main — production `BTDeviceEnumerator`/`BTSyncedSink` are fresh Apple-only re-derivations (Decision 5).
- **Sequencing:** synced-local → main; commit spike; run Wave-0 spikes (gates); then BT production Waves 1–5 on top of landed synced-local.

## K. Test + docs/registry impact

- New `IsolatedTestCase` tests under `AudioutCore/Tests/…`, green under `swift test --parallel`.
- Existing `GroupController`/`NativeBackend` selection tests may need BT cases added (BT-GROUPCTL/BT-TESTS) — in scope, not optional.
- New persisted `AppSettings` per-device offset keys — cover load/default/persist.
- Entitlements + `Info.plist` (`NSBluetoothAlwaysUsageDescription`, `com.apple.security.device.bluetooth`) added — note in the signing/notarization checklist.
- Docs: `PROGRESS.md`, `AudioutCore/AGENTS.md`, `dev/notes/`, this plan; record the stated quality-bar limitations. Read the nearest `AGENTS.md` before editing any subsystem; verify every backticked symbol via `git grep`.
- **Merge to `main` only after Alec's live by-ear test + explicit go-ahead** (standing rule; especially here — real-time-audio correctness + a new BT permission).

## L. Open risks to confirm during execution

- Programmatic-connect reliability + which macOS version gates IOBluetooth TCC (14 vs 15) — **BT-SPIKE-CONNECT.**
- A2DP-survives-built-in-mic-recording — **BT-SPIKE-OFFSET** (kills auto-offset if false).
- The output-set partition (R-partition) — the single highest-risk integration edit; exhaustive tests + spy.
- Same-room BT+BT drift acceptability vs the Decision-1 bar — confirm by ear at BT-DOCS-LIVE.
- SF Symbol validity for the BT kind; confirm an AppKit-usable glyph.

---

## Sources (external, feasibility claims)

- [IOBluetoothDevice / openConnection() — Apple Developer](https://developer.apple.com/documentation/iobluetooth/iobluetoothdevice/openconnection())
- [Apple Developer Forums — Bluetooth A2DP as output / no public A2DP sink API](https://developer.apple.com/forums/thread/5787)
- [A2DP→HFP downgrade when the mic opens](https://umatechnology.org/why-do-bluetooth-headphones-sound-bad-when-using-the-mic/)
- [macOS System Settings URL schemes (com.apple.BluetoothSettings)](https://macmost.com/mac-settings-links)
- Prior art: PairPods (MIT — multi-BT on macOS, Apple-only), Airfoil (commercial).

---
*Produced 2026-07-24 via the `planner` sub-agent (opus/high), code-verified against `main`, with 6 decisions locked by Alec. Companion to `docs/plans/synced-local-airplay-plan.md` (its sync engine is the prerequisite foundation).*
