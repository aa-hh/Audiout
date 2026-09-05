# Plan — Synced local output (Mac speakers + AirPlay on one clock)

Status: **APPROVED plan, Stage 4 checkpoint cleared 2026-07-22 — execution NOT YET STARTED.**
Worktree: `.claude/worktrees/synced-local-airplay`, branch `claude/synced-local-airplay`, based off `main` at `4e3fa30`.
Say "go" to launch Wave 1. Per standing rule: commits to this branch don't need sign-off; **merging into `main` does** — wait for the owner's explicit go-ahead, and only after they've live-tested it.

## Feasibility verdict

**Feasible with public Apple APIs for the core "delayed synced local sink."** Three de-risking facts from research:
- We are the PTP grandmaster, not a slave — `AirPlayEngine/Sources/ptp-helper/main.c:216` starts libairptp as master; RTP timing is off our own `CLOCK_MONOTONIC` (`AirPlayEngine/Sources/CAirPlayEngine/sender/airplay.c:557-570`). Every receiver disciplines *its* clock to *us* — no network-clock conversion to invent.
- The presentation delay is a known constant we set, not something to measure: `startBufferMs − 250 ms` (`AirPlayEngine.swift:48-49`; `sender/airplay.c:1229`, `AIRPLAY_AUDIO_LATENCY_MS = 250` at `airplay.c:94`).
- The clock-domain reconciliation ("the hard part") already ships: `AudioutCore/Sources/AudioutCore/NativeCaptureCoordinator.swift:1049-1093` already converts Core Audio `mHostTime` ↔ `CLOCK_MONOTONIC` with a per-instance, sleep-aware rebase offset.

**One decision materially raises the risk: the owner chose studio-grade, phase-perfect sync** over the simpler ~10ms/periodic-hard-resync design. That pulls in a continuous micro-rate control loop and may exceed what `AVAudioEngine`'s public scheduling APIs cleanly deliver — see Risk R7. A feasibility spike (T-SPIKE-PHASE) is inserted before the expensive DSP task specifically to prove this on real hardware before committing, rather than discovering a public-API ceiling late.

External reality check: there is no public Apple API that hands you the AirPlay presentation clock to delay a local copy against — you build it yourself (this plan). macOS's own Multi-Output/Aggregate devices do NOT keep AirPlay in sync with local speakers (drift-correction/resampling fallback, widely reported to still drift). Apple's genuinely synchronized multiroom lives only inside Music.app, not as a system API. So "be the grandmaster + schedule a deliberately-delayed local sink on `hostTime`" is the right and essentially only public-API path.

There's also a prior engineering brief worth reading before executing, not re-deriving: `dev/notes/p2b-synced-local-brief.md` (§4 latency formula, §5 API choice, §6 drift strategy, §7 device/sleep handling). And a prior decision doc that recommended the UI-only fallback first: `docs/plans/phase-3-findings/proposals/local-mix.md` — the owner explicitly chose to build the real feature instead (see decisions below), so that doc's recommendation is superseded for this plan; mark it resolved once this ships.

## End state

The Mac's own speakers become a first-class, PTP-aligned Audiout output. Selecting the Mac alongside ≥1 AirPlay device mutes the Mac's raw system output (already `.mutedWhenTapped`) and renders a deliberately delayed copy of the captured audio through a new app-layer `AVAudioSourceNode`-backed sink, scheduled in `hostTime` and held phase-locked by a continuous micro-rate correction loop (studio-grade target). A user-facing numeric ms offset (Audio settings) biases the target for devices that misreport latency. The `GroupController` local-mix refusal is lifted with a precise, unchanged auto-drop rule; the popover allows the combined selection; correctness is confirmed by a gated by-ear hardware test.

## Decisions locked (were open questions — all confirmed by the owner)

- **Q1 → BUILD NOW.** Full plan proceeds.
- **Q2 → APP LAYER**, sibling to `LocalPlaybackEngine`. T-PLACEHOLDER retires/deprecates the engine's `localOutput`/`setLocalOutputEnabled`/`LocalOutputSink` placeholder rather than filling it in.
- **Q3 → MANUAL OFFSET SLIDER IN V1.** New task T-OFFSET-UI (numeric ms control in Audio settings + persistence).
- **Q4 → STUDIO-GRADE, PHASE-PERFECT.** T-DRIFT replaced by T-CORRECTION (continuous micro-rate correction) preceded by T-SPIKE-PHASE (feasibility spike). See Risk R7.
- **Q5 → AUTO-DROP FOR FIRST-TIME AIRPLAY USE ONLY** (not removed entirely). Precise state-transition spec is in T-GROUPCTL below.
- **Cost-check outcome:** the model-critic flagged T-SPIKE-PHASE as a candidate downgrade (opus→sonnet, high→medium) since it's throwaway test code. The owner chose to **keep it on opus/high** — its real job is correctly judging real-hardware measurements and picking the right technical approach for T-CORRECTION (the hardest task in the plan); a wrong call there is expensive to unwind. **No other downgrades applied — the table below is the final, approved assignment.**

## Task list

> Anchors from a `warm-signal-v2`-era read of the codebase, 2026-07-22 — re-confirm exact line numbers before editing (this worktree is based off `main`, not `warm-signal-v2`, and may differ). Executors should read `dev/notes/p2b-synced-local-brief.md` rather than re-derive, and read the nearest `AGENTS.md` for whatever subsystem they're editing first.

**T-LATENCY — Core Audio output-latency measurement helper**
Files: new `AudioutCore/Sources/AudioutCore/LocalOutputLatency.swift`
What: read `kAudioDevicePropertySafetyOffset` + `kAudioDevicePropertyLatency` (device/output scope) + `kAudioStreamPropertyLatency` (active stream) + `kAudioDevicePropertyBufferFrameSize` for the default output device; frames→seconds via `kAudioDevicePropertyNominalSampleRate` (brief §4b).
Kind: new-code · Depends on: — · **Model: sonnet 5 · Effort: medium**
Verify: unit test asserts plausible non-zero latency; log measured vs reported on a real device.

**T-ENGINE-DELAY — expose the AirPlay presentation delay**
Files: `AirPlayEngine/Sources/AirPlayEngine/AirPlayEngine.swift` (~line 48 / EngineConfig), maybe `AirPlayTypes.swift`
What: expose the effective `startBufferMs`/`output_buffer_samples`-derived delay as a readable value so the sink computes from the SAME source the sessions use (R4), never a hardcoded copy.
Kind: backend · Depends on: — · **Model: sonnet 5 · Effort: low**
Verify: unit test reads it back, matches configured buffer.

**T-SINK — the delayed local sink (foundation)**
Files: new `AudioutCore/Sources/AudioutCore/SyncedLocalSink.swift`
What: app-layer `AVAudioSourceNode`-backed `AVAudioEngine` fed by a lock-free ring; render block silent until `hostTime` reaches `capture_pts + presentationDelay − localOutputLatency − safetyMargin (+ userOffset later)`, then emits; reuse the mach↔`CLOCK_MONOTONIC` rebase (`NativeCaptureCoordinator.swift:1049-1093`). Build the graph so a rate-correction node (T-CORRECTION) and a phase-error readout (render-block `AVAudioTime`) can be inserted (brief §5.1/§1).
Kind: new-code · Depends on: T-LATENCY, T-ENGINE-DELAY · **Model: opus 4.8 · Effort: high**
Verify: offline harness feeds a known ramp+pts, asserts first-non-silence frame lands at the computed `hostTime` within tolerance.
Note: this file becomes the shared hot file T-LIFECYCLE, T-CORRECTION, and T-OFFSET-UI all edit later — never edit it concurrently with those.

**T-SPIKE-PHASE — studio-grade feasibility spike (kept opus/high per the owner)**
Files: throwaway harness under `dev/` + notes in `dev/notes/`
What: on real hardware, measure the achievable phase-lock precision of the T-SINK graph — how tight a phase error the render-block `AVAudioTime` feedback + a rate-correction node (`AVAudioUnitTimePitch` / `AVAudioUnitVarispeed`, or a custom fractional resampler) can hold, and whether public `AVAudioEngine` scheduling can hit sub-ms or bottoms out at buffer granularity (which would force raw-HAL + custom resampler). Recommend the concrete correction mechanism for T-CORRECTION and confirm/renegotiate the "phase-perfect" target with the owner (R7).
Kind: investigation · Depends on: T-SINK · **Model: opus 4.8 · Effort: high**
Verify: written finding with measured phase-error numbers + a go/no-go mechanism recommendation; **The owner confirms the target before T-CORRECTION starts — this is a checkpoint, not a pass-through.**

**T-CORRECTION — continuous micro-rate correction loop (studio-grade)**
Files: `SyncedLocalSink.swift` (+ possibly a new `PhaseController.swift`)
What: replaces the original periodic-hard-resync design. Estimate the residual phase error between the reference timeline and the local output device clock (ppm clock drift between capture-device and output-device domains), and drive a continuous rate correction (mechanism per T-SPIKE-PHASE) via a PI-style control loop that nulls phase error to the studio-grade target, click-free. No audible pitch artifact at ppm-level corrections.
Kind: new-code · Depends on: T-SPIKE-PHASE · **Model: opus 4.8 · Effort: xhigh**
Verify: unit test drives synthetic clock drift and asserts the loop converges and holds phase within target without over/under-shoot; by-ear confirmation in T-DOCS-LIVE.

**T-FANOUT — fan capture to the sink + self-exclude to kill the feedback loop**
Files: `NativeCaptureCoordinator.swift` (write path ~line 375) and/or `AppRouteMixer.swift`; tap-exclude in `NativeBackend.swift`
What: feed the SAME PCM+pts that goes to `engine.write(pcm:pts:)` to the sink (one capture, two consumers); CRITICAL — add the sink's render process/client to the whole-system tap's exclude list so the tap doesn't re-capture the delayed output (echo) (brief §8).
Kind: backend · Depends on: T-SINK · **Model: opus 4.8 · Effort: high**
Verify: Goertzel tone test confirms the tap does NOT pick up sink output; no echo by ear.

**T-PLACEHOLDER — retire the engine `localOutput` placeholder**
Files: `AirPlayEngine.swift:1107-1125, 1347-1353`
What: deprecate/remove `localOutput` / `setLocalOutputEnabled` / `LocalOutputSink` (dead — the sink lives app-side per Q2); update doc comments/TODOs. Confirm no caller depends on it (research showed none do).
Kind: pure-delete/backend · Depends on: — · **Model: sonnet 5 · Effort: low**
Verify: package builds with the symbols gone; `git grep` shows no live callers; engine tests green.

**T-LIFECYCLE — device-change + sleep/wake rebuild**
Files: `SyncedLocalSink.swift`
What: listen for `kAudioHardwarePropertyDefaultOutputDevice` and `NSWorkspace.didWake/willSleep`; on either, stop → re-measure latency → re-seed the mach↔MONOTONIC offset → reset the correction loop → restart ("always rebuild, don't diff", brief §7/§3).
Kind: new-code · Depends on: T-SINK · **Model: sonnet 5 · Effort: medium**
Verify: unit test listener→rebuild; manual sleep/wake in T-DOCS-LIVE.

**T-OFFSET-UI — manual ms sync-offset control**
Files: Settings window Audio tab (existing "Advanced buffer ms" control is the precedent to match), `AppSettings.swift` (persistence), `SyncedLocalSink.swift` (consume the value)
What: a numeric ms offset field (bare number + unit — NOT a named preset, per house rule on localization in numeric controls), persisted in `AppSettings`, added to the sink's delay target as a static user bias on top of the computed+corrected delay.
Kind: new-code · Depends on: T-SINK (wiring), T-CORRECTION (target must be defined) · **Model: sonnet 5 · Effort: medium**
Verify: changing the field shifts local timing by that amount live; value persists across relaunch; unit test on the store + delay-calc contribution.

**T-BACKEND — wire local-output enable into `NativeBackend`**
Files: `NativeBackend.swift` (large, central)
What: when the selection includes Mac + ≥1 AirPlay device, enable the app-layer sink and ensure raw output is muted; disable otherwise. Talks to the app-layer sink directly (not through the retired engine flag).
Kind: backend · Depends on: T-FANOUT, T-SINK · **Model: sonnet 5 · Effort: medium**
Verify: backend spy asserts enable/disable on the right selection transitions.

**T-GROUPCTL — lift the local-mix refusal + Q5 auto-drop spec**
Files: `GroupController.swift` (search `localMixRefusalReason`/`wouldMixLocalWithAirPlay`)
What: remove the local-mix refusal so the Mac may join a mixed set, keeping the auto-drop rule EXACTLY as specified below.

**Precise state-transition spec** (S = `selectedDeviceIDs` before the change; L = local/Mac id; A = an AirPlay/non-local id):
- **ADD an AirPlay device A:**
  - if `S == {L}` (Mac is the *sole* member) → **auto-drop L**, then insert A ⇒ `{A}` (`autoSwapped=true`). *[first-time AirPlay from Mac-only — the one case that fires]*
  - if `S` already contains L *and* ≥1 AirPlay (already mixed) → **do NOT drop**; insert A ⇒ `S ∪ {A}` (Mac stays). *[the newly reachable mixed state]*
  - if `S` contains only AirPlay device(s), or `S` is empty → insert A, no drop.
- **ADD the local device L:** always **allowed** (refusal lifted), never drops anything ⇒ `S ∪ {L}`. *(Previously refused when S held AirPlay.)*
- **REMOVE any device:** remove it, then apply the **current-device floor** unchanged — if the result is empty, re-insert L. When Mac already coexists in a mixed set, removing the last AirPlay device naturally leaves `{L}` (the floor's old "reverse-auto-swap restore" is subsumed).

Key finding from research: the existing auto-swap guard is precisely `!d.isLocalDevice && selectedDeviceIDs == [local]` — it *already* fires only when the Mac is the sole member, i.e. it already encodes this spec. The substantive change is: (1) delete the refusal block and its `wouldMixLocalWithAirPlay` gate for the local-add path, (2) keep the auto-swap guard as-is, (3) reconcile the removal-side floor/reverse-swap now that the mixed state is reachable, (4) exhaustive tests.

Kind: backend · Depends on: — · **Model: opus 4.8 · Effort: high**
Verify: exhaustive unit cases for every transition above + all prior selection tests updated and green.

**T-UI-ALLOW — allow the combined toggle in the popover**
Files: `PopoverController` (grep `localMixRefusalReason`) + row view
What: stop greying-out/tooltip-blocking the Mac row when AirPlay is selected; allow the checkbox.
Kind: new-code (small) · Depends on: T-GROUPCTL · **Model: sonnet 5 · Effort: low**
Verify: toggling the Mac row into a mixed set is accepted and routes. (Note: AppKit row/menu dispatch has bitten this codebase before — see memory "Row selection tests bypass AppKit dispatch" — test via real dispatch, not delegate shortcuts.)

**T-TESTS — coverage across the new surface**
Files: new tests in `AudioutCore/Tests/...`; update existing `GroupController` tests
What: unit-cover T-LATENCY, the mach↔hostTime scheduling math, the T-CORRECTION convergence/hold behavior, the T-GROUPCTL transition matrix (every case above), the T-OFFSET-UI store+delay contribution, and the tap self-exclude tone test.
Kind: test · Depends on: T-CORRECTION, T-GROUPCTL, T-FANOUT, T-OFFSET-UI · **Model: sonnet 5 · Effort: medium**
Verify: `swift test --parallel` green; new tests subclass `IsolatedTestCase`.

**T-DOCS-LIVE — docs + gated by-ear hardware test**
Files: `PROGRESS.md`, `AudioutCore/AGENTS.md` / `AirPlayEngine/AGENTS.md`, `dev/notes/`, mark `docs/plans/phase-3-findings/proposals/local-mix.md` resolved (Option A built)
What: document the shipped design; run the user-present, PTP-port-gated by-ear test with a real AirPlay 2 receiver + Mac speakers — confirm phase alignment against the studio-grade target, no echo (R2), sleep/wake resync (R3), and offset-slider effect (R1).
Kind: docs + test · Depends on: all above · **Model: haiku 4.5 (docs); the live test is a manual owner-run step · Effort: low**
Verify: The owner confirms by ear against the studio-grade target; findings recorded.

## Parallelization

Hot files — never edit concurrently: `SyncedLocalSink.swift` (T-SINK, T-LIFECYCLE, T-CORRECTION, T-OFFSET-UI wiring); `AirPlayEngine.swift` (T-ENGINE-DELAY, T-PLACEHOLDER); `NativeBackend.swift` (T-FANOUT tap-exclude, T-BACKEND); `GroupController.swift` (T-GROUPCTL); `AppSettings.swift`/Settings views (T-OFFSET-UI); `PopoverController` (T-UI-ALLOW).

- **Wave 1 (parallel):** T-LATENCY ∥ T-ENGINE-DELAY ∥ T-GROUPCTL ∥ T-PLACEHOLDER — four different files, none depend on the sink.
- **Wave 2 (serial foundation):** T-SINK.
- **Wave 3:** T-SPIKE-PHASE ∥ T-FANOUT ∥ T-LIFECYCLE. (T-SPIKE-PHASE only reads/prototypes against the sink in a throwaway harness — keep its edits out of the shipping `SyncedLocalSink.swift` to avoid contention with T-LIFECYCLE, which does edit that file this wave.)
- **Wave 4:** T-CORRECTION (after T-LIFECYCLE + T-SPIKE-PHASE) ∥ T-BACKEND (after T-FANOUT). Do not overlap T-FANOUT's tap-exclude edit with T-BACKEND — different waves here.
- **Wave 5:** T-OFFSET-UI (after T-CORRECTION) ∥ T-UI-ALLOW (after T-GROUPCTL) ∥ T-TESTS (after correction/groupctl/fanout land).
- **Wave 6:** T-DOCS-LIVE (gated by-ear, last).

**Critical path:** T-ENGINE-DELAY → T-SINK → T-SPIKE-PHASE → T-CORRECTION → T-OFFSET-UI → T-TESTS → T-DOCS-LIVE. The studio-grade DSP chain (T-SINK → T-SPIKE-PHASE → T-CORRECTION) is the long pole.

## Execution mode: **watched agents** (not a workflow)

Judgment-heavy real-time-audio work with one hard serial chain everything hangs off, a built-in go/no-go decision point (T-SPIKE-PHASE may find the studio-grade target isn't achievable with public APIs and need to come back to the owner), and a real-hardware gate at the end. Not a uniform mechanical fan-out, so workflow overhead isn't earned. Launch Wave 1's four independent tasks together; each wave waits for the previous to land; pause for review at T-SPIKE-PHASE (before committing to T-CORRECTION) and at T-DOCS-LIVE (the live listening test only the owner can run).

## Test + docs impact

- New unit tests subclass `IsolatedTestCase`, pass under `swift test --parallel`.
- Existing `GroupController` selection tests WILL break when the refusal is lifted — updating them is in-scope (T-GROUPCTL/T-TESTS), not optional.
- Tap self-exclude needs the Goertzel tone-test pattern (feedback-loop proof).
- T-OFFSET-UI adds a persisted `AppSettings` key — cover load/default/persist.
- Docs: `PROGRESS.md`, both `AGENTS.md`, mark `local-mix.md` resolved, remove retired `LocalOutputSink` placeholder references.
- **Merge to `main` only after the owner live-tests and explicitly gives the go-ahead** — standing rule, applies especially here given the real-time-audio correctness stakes.

## Open risks

- **R7 (NEW, from the studio-grade choice — highest risk in the plan): "phase-perfect" may exceed public `AVAudioEngine` scheduling.** Render-block `AVAudioTime` feedback is buffer-granular, and `AVAudioUnitTimePitch`/`Varispeed` add their own latency and aren't guaranteed sample-accurate/click-free on rate changes — sub-ms continuous phase-lock may require a custom fractional resampler and possibly a raw HAL IOProc instead of AVAudioEngine. Also: "phase-perfect" between a Mac speaker and a cross-room AirPlay speaker is physically bounded by acoustic propagation (~3ms/m) and room geometry — the target is meaningful at the electronic-output boundary, not necessarily at the listener's ear. **T-SPIKE-PHASE exists specifically to measure this and confirm/renegotiate the target with the owner before T-CORRECTION is committed.** If the spike shows a public-API ceiling, escalate scope (raw HAL + custom resampler) or revisit the studio-grade choice — do not silently ship a looser result.
- **R1:** Bluetooth/exotic devices misreport `kAudioDevicePropertyLatency` — the T-OFFSET-UI manual slider is the day-one escape hatch. Still measure vs observed on real hardware.
- **R2:** feedback-loop/echo if the tap self-exclude targets the wrong process identity — audible, easy to miss in a quiet test. Explicit tone test required (T-FANOUT/T-TESTS).
- **R3:** sleep/wake + device-change are silent failure modes (stale offset/drift, not a crash), easy to under-test on an always-awake dev machine. Manual test required (T-DOCS-LIVE).
- **R4:** the sink must read the engine's REAL buffer config (T-ENGINE-DELAY), never a hardcoded copy — else a later buffer tune silently de-syncs local playback.
- **R6:** native live-test contention — PTP ports 319/320 are single-instance; coordinate T-DOCS-LIVE as a committed-SHA handoff, not two concurrent sessions.

---
*Produced via `/orchestrate` 2026-07-22 (planner: opus/high via the `planner` sub-agent; cost-check: `model-critic`). Original research conversation happened in the `warm-signal-v2` session before this dedicated worktree was created — this file is the durable record.*
