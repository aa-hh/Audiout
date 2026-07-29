<!--
Handoff plan. Self-contained: a fresh agent with no prior conversation context can
execute from this file alone. Produced by a research-grounded planning pass (read-only,
claims verified against source at the file:line refs below) on 2026-07-29.
Feature is NOT started — this is the spec to implement. SPIKE FIRST (§5).
-->

# Implementation Plan — "Consistent Main Out: pin the whole-system capture rate"

**Status:** READ-ONLY research complete. No code written. This document is the complete handoff — a fresh agent needs nothing else.
**Worktree:** `/Users/alechenderson/Projects/AirPlay Controller/.claude/worktrees/audio-dropout-investigation-5c2a1f`
**Branch:** `claude/audio-dropout-investigation-5c2a1f` (NOT merged to main; live test owed on prior pause-on-call work already on this branch).

---

## 1. Context / background (everything a cold reader needs)

**What Audiouter is.** A native AppKit macOS menu-bar app that captures the Mac's whole-system audio and streams it to one or more AirPlay 2 speakers. The shipping audio backend is `NativeBackend` (`AudiouterCore/Sources/AudiouterCore/NativeBackend.swift`), which drives a vendored AirPlay 2 sender (`AirPlayEngine`). "Main Out" is the product name for the whole-system capture → AirPlay pipeline (as opposed to per-app redirects).

**How whole-system capture works (the pipeline this plan touches).** `NativeCaptureCoordinator` (`AudiouterCore/Sources/AudiouterCore/NativeCaptureCoordinator.swift`, 3377 lines) owns an in-process Core Audio capture pipeline:
1. It creates a **system process tap** (`CATapDescription(stereoGlobalTapButExcludeProcesses:)`) — `createTapAndReadFormat()` at line 2555.
2. It wraps that tap in a **private aggregate device** — `createAggregate()` at line 2624. The aggregate pins its clock/main sub-device to the Mac's **current default output device** via `kAudioAggregateDeviceMainSubDeviceKey: outputUID` (line 2643), with **sub-tap drift compensation ON** (`kAudioSubTapDriftCompensationKey: true`, line 2652).
3. A realtime **IOProc** on the aggregate delivers PCM buffers — `startIOProc()` at line 2717.
4. Each buffer is converted to the engine's **hardwired S16LE / 44100 / 2ch** format (`AVFormatConverter`, line 3264) and written to `AirPlayEngine`. The engine is **hardwired to 44.1 kHz** — verified at `NativeCaptureCoordinator.swift:29` ("The engine is HARDWIRED to S16LE / 44100 / 2ch — there is no engine 'quality' setter"). So a pipeline that delivers exactly 44100 makes the converter a passthrough (rate-wise).

**The follow-the-device behavior (the problem).** The aggregate's **nominal sample rate follows its main sub-device** — i.e. whatever rate the current default output device is running at. This is documented in the long root-cause comment at `NativeCaptureCoordinator.swift:2794–2816` and enforced by `reconcileFormatWithAggregate()` (line 2817): after the aggregate starts, it reads the aggregate's REAL nominal rate (`readNominalSampleRate(aggregateID)`, line 2819) and rewrites `format`/`asbd` to match (`reconciledFormat`, pure, line 2838). This exists to fix a pitch-shift bug (a bare-tap read of 44100 while the aggregate actually ran at 48000 made the converter mis-resample by ~8.8%).

**The specific symptom the user wants fixed.** When a Bluetooth headset connects, macOS's BT stack momentarily negotiates HFP and the output device's nominal rate flaps — measured live as **`44100→16000→44100→16000` in 0.9 s** (`DefaultOutputDeviceMonitor.swift:267`). Because the aggregate follows the device, the whole-system capture **downscales to 16 kHz to meet the headset, then resyncs back up** — a visible blip/rebuild on every BT connect. Each rate change tears the tap+aggregate down and rebuilds them (see §2 below), and each device/rate-caused rebuild also re-anchors the AirPlay RTP session (`onDeviceRateRebuild` → `resetAirPlaySessionForWholeSystem`, `NativeBackend.swift:1284, 2384`) — the audible "downscale, then resync" churn.

**The goal.** Keep the Main Out capture pipeline at a **consistent fixed rate (44100)** regardless of the current default output device's rate, so a device **rate** flap no longer downscales the Main Out or triggers a rebuild/resync. A device **identity** change (BT → built-in speakers, etc.) must still move the aggregate to the new device (the existing make-before-break rebuild).

---

## 2. How rate changes drive a rebuild today (the machinery to change)

There is **one process-wide watcher**, `DefaultOutputDeviceMonitor` (`AudiouterCore/Sources/AudiouterCore/DefaultOutputDeviceMonitor.swift`), that owns the single HAL listener pair for `kAudioHardwarePropertyDefaultOutputDevice` (device identity) and `kAudioDevicePropertyNominalSampleRate` (device rate), with a 1.2 s **settle window** (leading + trailing, F-SETTLE) that absorbs the BT negotiation burst. It fans out to subscribers.

The whole-system tap (`CoreAudioSystemTap`) subscribes in `subscribeToDefaultOutput()` (line 2980):
- Its **`tracked` closure** (lines 2984–3003) reports what THIS tap is built on: `Tracked(deviceID: self.tappedOutputDeviceID, rate: self.hfpTrackedRate ?? self.format.sampleRate)`.
- The monitor fires the subscriber's **`onChange`** only when the live reading diverges from `tracked` — either `deviceDiverged` (live default-output device id ≠ tracked device id) **OR** `rateDiverged` (live device nominal rate ≠ tracked rate). See `DefaultOutputDeviceMonitor.swift:347–353`.
- The tap's **`onChange`** (lines 3004–3061) currently calls `self.onDefaultDeviceChanged?()` **unconditionally** at line 3060 (after some pause-on-call handling and telemetry labeling via `shouldRebuildForNominalRate`, line 3051).
- `onDefaultDeviceChanged` → `handleDeviceChange()` (line 1078) → `recreateTap(cause: .deviceOrRateChange)` (line 1084) → full tap+aggregate teardown+rebuild, and (because the cause is `.deviceOrRateChange`) fires `onDeviceRateRebuild?()` (line 1413) → whole-system RTP session reset.

**Critical consequence for the pin design.** Once the aggregate is pinned to 44100, `reconcileFormatWithAggregate()` reads back 44100 and `format.sampleRate` stays 44100, so `tracked.rate == 44100` always. When the device flaps to 16000/48000, the monitor sees `rateDiverged == true` and fires `onChange` — which today rebuilds. **The pin alone does not stop the rebuild.** Part 2 (the rebuild-decision change) is mandatory: `onChange` must **not** rebuild on a same-device rate flap when the rate is pinned; it must still rebuild on a device-identity change.

**The single most important empirical risk (why we spike first).** The whole-system tap rebuilds on device rate change today *specifically because a process tap goes SILENT (all-zero PCM) when its tapped device renegotiates its nominal rate* — an Apple-unresolved bug (Developer Forums 825780), documented at `NativeCaptureCoordinator.swift:2951–2968` ("the only reliable recovery is a FULL teardown + rebuild"). The pin bet is that **a 44100-pinned aggregate with drift compensation insulates the tap from the sub-device's renegotiation**, so the tap keeps delivering clean 44100 without a rebuild. **If that bet is wrong — if the tap still goes silent when the underlying device renegotiates even under a pinned aggregate — then suppressing the rebuild produces permanent silence.** This is exactly what the spike must prove on real BT hardware before any of the part-2 work is trusted.

---

## 3. Design

Two parts, both behind one env flag `AUDIOUTER_PIN_CAPTURE_RATE` (model the flag on the existing `AUDIOUTER_PAUSE_ON_CALL` pattern at `NativeCaptureCoordinator.swift:2441`: `static let pinCaptureRateEnabled = ProcessInfo.processInfo.environment["AUDIOUTER_PIN_CAPTURE_RATE"] == "1"`).

Scope decision (recommended): **whole-system only.** The per-app path (`PerAppCaptureCoordinator`) is a structural sibling — same aggregate build (`createAggregate(bundleID:)` at `PerAppCaptureCoordinator.swift:1140`, `kAudioAggregateDeviceMainSubDeviceKey` at :1160, drift comp at :1169, `reconcileFormatWithAggregate` at :1443) — but per-app redirects are not the user's complaint and doubling the surface doubles the live-test risk. Leave per-app on follow-the-device. Note in code/docs that per-app would need the identical change if ever extended.

### Part 1 — Pin the aggregate's nominal rate to 44100

The constant to pin to is `PCMFormat.airplay.sampleRate` (= 44100; the engine's fixed rate — do not hardcode a bare `44100`, use the symbol, as the rest of the file does, e.g. line 736).

In `createAggregate()` (`NativeCaptureCoordinator.swift:2624`), **after** `AudioHardwareCreateAggregateDevice` succeeds (line 2666–2670) and **before** `startIOProc()` runs, set the aggregate's nominal sample rate:

```
// gated on Self.pinCaptureRateEnabled
AudioObjectSetPropertyData(aggregateID, &kAudioDevicePropertyNominalSampleRate-address, ... 44100.0)
```

There is **no existing precedent for a set-on-aggregate** in this codebase (the only `AudioObjectSetPropertyData` calls are `SystemOutputVolume.swift:303,313`; `DefaultOutputDeviceMonitor` is explicitly watcher-only, never a writer — `DefaultOutputDeviceMonitor.swift:22–28`). So add a small static helper next to `readNominalSampleRate` (line 2867), e.g. `static func setNominalSampleRate(_ deviceID:, _ rate: Double) -> OSStatus`, so it is unit-visible and symmetric with the read.

`reconcileFormatWithAggregate()` (line 2817) already reads the aggregate's ACTUAL nominal rate and corrects `format` to it. This gives a **free safety net**: if the pin did not take (aggregate came up at 16000 anyway), reconcile reads 16000 and the format degrades to today's follow-the-device behavior automatically — no silence, no crash.

Add one telemetry line in `createAggregate` after the set: `aggregate_rate_pinned` with `{requested, readBack, ok}` (read back via `readNominalSampleRate(aggregateID)`), so the live A/B is greppable.

**Record whether the pin held.** Add an instance flag `private var ratePinnedAndHeld = false`, set true only when the read-back after the set equals 44100 (± rounding). This gates Part 2's rebuild suppression so that a *failed* pin never causes the rebuild to be wrongly suppressed.

### Part 2 — Suppress the rebuild for a same-device rate flap (only when the pin held)

In the tap's `onChange` (`NativeCaptureCoordinator.swift:3004–3061`), change the final unconditional `self.onDefaultDeviceChanged?()` (line 3060) so that, **when `Self.pinCaptureRateEnabled && self.ratePinnedAndHeld`**, a delivery whose device identity is unchanged does **not** rebuild:

- Compute `identityChanged = (snapshot.deviceID == nil) || (snapshot.deviceID != self.tappedOutputDeviceID)`. (A nil/failed device read counts as changed → rebuild, matching the codebase-wide "failed read is not evidence of no-change" rule, e.g. `TapRebuildDecision`, line 2283.)
- If pinned-and-held and **not** `identityChanged`: this is a device **rate** flap under a held pin → the pinned aggregate + drift comp keeps the tap at 44100 → **return without rebuilding**. Emit a new telemetry line `rate_pinned_no_rebuild` (with the observed device rate) instead of `rate_changed_rebuild_triggered`, so the live pass-criterion ("no `rate_changed_rebuild_triggered` on a same-device flap") holds.
- Otherwise (identity changed, or pin not held, or flag off): fall through to today's `self.onDefaultDeviceChanged?()` — the existing make-before-break identity rebuild (`recreateTap`'s `makeBeforeBreak` at lines 1270–1297) and, for a real re-anchor, `onDeviceRateRebuild` (line 1413) are unchanged.

The `tracked` closure (lines 2984–3003) can be left reporting `format.sampleRate` (= 44100 when pinned). It will make the monitor keep firing `onChange` on each device-rate flap (rateDiverged), but `onChange` now cheaply returns for same-device flaps — bounded (one leading + one trailing delivery per settle burst), no storm. Do **not** try to make the tracked closure report the device's live rate to pre-suppress at the monitor; that adds a HAL read on the monitor queue and is less testable than the explicit `onChange` guard.

**Do not touch the monitor (`DefaultOutputDeviceMonitor`) or `TapRebuildDecision`.** The whole change is local to `CoreAudioSystemTap` (`createAggregate`, the new helper/flag, and `onChange`). This keeps the storm loop-breaker and the per-app tap byte-identical.

---

## 4. Interaction with existing machinery (all verified)

- **Make-before-break identity rebuild** (`recreateTap`, lines 1270–1297): unchanged. Identity changes still fall through to `onDefaultDeviceChanged` → `handleDeviceChange` → `recreateTap(cause: .deviceOrRateChange)`. The new aggregate is pinned to 44100 on the new device.
- **F-REANCHOR / `onDeviceRateRebuild`** (`NativeBackend.swift:1284 → resetAirPlaySessionForWholeSystem`, :2384): fires only on an actual rebuild (line 1413). Because Part 2 removes the *same-device rate-flap* rebuild, it also removes that rebuild's session reset — which is precisely the "resync blip" the user dislikes. Identity-change rebuilds still fire it; the `TapReanchor` clock-moved safety net (line 1399–1402) still catches a device that moved inside the teardown window. Net: strictly fewer spurious resets, none removed that were needed.
- **`reconcileFormatWithAggregate`** (line 2817): with a held pin it reads back 44100 and is a no-op; with a failed pin it corrects to the device rate (the fallback). No change needed to this function itself.
- **F-SETTLE settle window** (`DefaultOutputDeviceMonitor`, 1.2 s): unchanged and still useful — it coalesces the burst so `onChange` fires at most twice per connect even before Part 2 short-circuits.
- **Pause-on-call** (`AUDIOUTER_PAUSE_ON_CALL`, currently OFF by default — `NativeCaptureCoordinator.swift:2434–2442`): independent and out of scope. It composes cleanly (a held 44100 pin actually *helps* — the `SilenceFeeder` already writes 44100 buffers, so a pinned format matches the feeder). Keep it OFF for this work; do not entangle the two flags. Note only: when both are on, a real HFP call still routes through pause-on-call's gate; the pin does not change that path.
- **Per-app coordinator** (`PerAppCaptureCoordinator`): out of scope (see §3). No edits.

---

## 5. SPIKE FIRST (the single most important step)

**Purpose:** answer the two load-bearing empirical unknowns on REAL Bluetooth hardware before investing in the full task:
1. **Does the 44100 pin HOLD** while the aggregate's main sub-device is a 16 kHz/48 kHz Bluetooth headset with drift compensation on? (read-back = 44100?)
2. **Does the tap keep delivering clean, non-silent 44100 audio across a BT rate renegotiation WITHOUT a rebuild?** (i.e. does pin + drift-comp actually prevent the silent-tap bug that the rebuild exists to work around?)

**Spike scope (minimal, all behind `AUDIOUTER_PIN_CAPTURE_RATE=1`, flag OFF = today byte-for-byte):**
- Add `static let pinCaptureRateEnabled` (env read) + `private var ratePinnedAndHeld` to `CoreAudioSystemTap`.
- In `createAggregate()`: after create, if flag on, set `kAudioDevicePropertyNominalSampleRate = 44100` on the aggregate via a new static helper; read it back; set `ratePinnedAndHeld`; log `aggregate_rate_pinned {requested, readBack, ok}`.
- In `onChange`: if `pinCaptureRateEnabled && ratePinnedAndHeld && !identityChanged`, return without calling `onDefaultDeviceChanged?()`; log `rate_pinned_no_rebuild`.
- Nothing else. No monitor changes, no per-app, no docs beyond a one-line code comment.

**How the user A/Bs it (state these steps in the handoff):**
- Build the real `.app` (`scripts/make-app.sh` — required; a bare `swift run` loses the TCC grant). Fully quit any running Audiouter first (single-instance rule, §9).
- Baseline: launch WITHOUT the flag, select an AirPlay speaker, connect the BT headset → hear/see the downscale+resync blip; note `format_reconciled`/`rate_changed_rebuild_triggered`/`aggregate_create` telemetry.
- Pinned: relaunch WITH `AUDIOUTER_PIN_CAPTURE_RATE=1` (via the `launchctl setenv`-then-`open` path the team already uses for env-gated builds), repeat the BT connect.

**Live PASS criteria (all must hold):**
- `aggregate_rate_pinned` shows `readBack == 44100, ok == true` — the pin held even while the BT device was at 16 k/48 k.
- No `rate_changed_rebuild_triggered` on the same-device BT flap; instead `rate_pinned_no_rebuild` lines appear.
- Main Out audio stays **clean**: no dropout/silence across the HFP↔A2DP transition, no pitch shift, no audible 16 kHz "downscale" or resync blip.
- A genuine device-identity change (BT → built-in) still rebuilds and re-anchors (audio follows).

**Live FAIL signals (each dictates a different response):**
- `readBack != 44100` (pin didn't hold) → try spike variants B/C below; if none hold, fall back to §8 "pin cannot be honored" (keep follow-the-device, abandon Part 2).
- Audio goes silent/gargled across the flap even though `readBack == 44100` → the tap does NOT survive renegotiation under a pinned aggregate; **the core bet is wrong** — do not ship Part 2's suppression; report back for redesign (options: keep the rebuild but always pin the new aggregate to 44100 so at least each rebuild is uniform — a smaller win that still has a blip).
- Pitch shift → the pin held but drift comp is not resampling onto it; treat as FAIL, variant B/C.

**Spike variants to try if variant A (plain nominal-rate set) does not hold the pin** (the empirical fallbacks for §1's "would the pin be overridden by the 16 kHz main sub-device"):
- **Variant B:** also enable drift compensation on the sub-**device** (`kAudioSubDeviceDriftCompensationKey: true` inside `kAudioAggregateDeviceSubDeviceListKey`, alongside the existing sub-*tap* drift comp), so the physical output is itself drift-corrected and the aggregate can hold an independent nominal rate.
- **Variant C:** drop `kAudioAggregateDeviceMainSubDeviceKey` and instead nominate a clock via `kAudioAggregateDeviceClockDeviceKey`, or leave the aggregate master-less so it free-runs at the set nominal rate. Riskier (clock/timing implications for `pts`); only if B fails.

Only after the spike returns a clean PASS does the full task (§6) proceed. If it fails, stop and report — the plan below is contingent on the spike.

---

## 6. Task breakdown (post-spike)

All tasks live in `AudiouterCore/Sources/AudiouterCore/NativeCaptureCoordinator.swift` and its test file `AudiouterCore/Tests/AudiouterCoreTests/NativeCaptureCoordinatorTests.swift`, so they **serialize** (same-file collision) — do them sequentially, not in parallel. This is a small, focused change; one agent end-to-end is the right shape.

| # | Task | Scope / files | Depends on | Model + effort |
|---|---|---|---|---|
| **T0** | **Spike** (§5) | `NativeCaptureCoordinator.swift` (`createAggregate`, `onChange`, new flag/helper). No tests beyond a compile check. | — | Sonnet, **low** (small, mechanical; the risk is in the live result, not the code) |
| **T1** | **Productionize Part 1**: promote the spike's pin into clean form — the `setNominalSampleRate` static helper next to `readNominalSampleRate` (line 2867), the `ratePinnedAndHeld` flag set from read-back, the `aggregate_rate_pinned` telemetry, and a `razor:` comment marking "whole-system only; per-app deliberately not pinned (upgrade path: mirror in `PerAppCaptureCoordinator.createAggregate`)". | Same file, `createAggregate` region (2624–2690) + helpers region (2863–2878). | T0 PASS | Sonnet, **low** |
| **T2** | **Productionize Part 2**: the `onChange` identity-vs-rate guard gated on `pinCaptureRateEnabled && ratePinnedAndHeld`; restructure the telemetry so a suppressed flap logs `rate_pinned_no_rebuild` and a real rebuild still logs `rate_changed_rebuild_triggered`. | Same file, `onChange` region (3004–3061). | T1 | Sonnet, **medium** (the correctness-critical bit; must get identity-vs-rate and the nil-device rule right) |
| **T3** | **Hermetic tests** (§7). Extend `NativeCaptureCoordinatorTests` using the existing `TapMonitorFakeHAL` / `test_seedTrackedState` / `subscribeToDefaultOutput` / `_drainForTesting` seams: prove (a) with pin-held, a same-device rate flap does NOT fire `onDefaultDeviceChanged`; (b) an identity change STILL fires; (c) with the flag off, behavior is unchanged (the existing `wholeSystemTapReportsItsOwnStateLiveToTheMonitor` test at line 2043 must still pass); (d) `reconciledFormat`/`ratePinnedAndHeld` fallback when read-back ≠ 44100 does NOT suppress. Add a `test_` seam to force `ratePinnedAndHeld` in the fake path if needed (the fake tap never calls the real `createAggregate`). | Test file only. | T2 | Sonnet, **medium** |
| **T4** | **Docs**: update the two AGENTS.md that describe this path — `AudiouterCore/AGENTS.md` (the `TapRebuildDecision` rules region and the Map entry near line 527) and `AudiouterCore/Sources/AudiouterCore/AGENTS.md` (the capture narrative) — to record the pin invariant, the flag, "whole-system only", and the fallback. Docs land WITH the code in the same branch (docs-first house rule). Add a short note to memory per project convention (not a repo file). | AGENTS.md files. | T2 | Sonnet, **low** |

**Model-critic note:** every task above is Sonnet/low–medium. Nothing here warrants Opus — it is a localized change to one well-understood file with strong existing test seams and an automatic format-reconcile fallback. The genuine difficulty is empirical (the live spike), not reasoning depth. Reserve an Opus **adversarial review pass** of T1–T3 as a final gate before asking the user to live-test (this branch's history shows adversarial review caught three silent-forever criticals in the pause-on-call work — the same class of risk lives here: a wrongly-suppressed rebuild is silent-forever).

---

## 7. Test strategy

**Hermetic (fast, in `swift test`).** Use the existing seams — no live Core Audio:
- `TapMonitorFakeHAL(deviceID:rate:)` + `DefaultOutputDeviceMonitor(hal:settleWindow: 60)` + `CoreAudioSystemTap(name:monitor:)` + `tap.test_seedTrackedState(deviceID:sampleRate:)` + `tap.subscribeToDefaultOutput()` + `hal.fire(...)` + `monitor._drainForTesting()` + `TapMonitorFireCounter` on `onDefaultDeviceChanged`. This is exactly the shape of the existing test at `NativeCaptureCoordinatorTests.swift:2043–2075`.
- New cases (see T3). Key one: seed `tracked` device=42/rate=44100, force `ratePinnedAndHeld=true`, set `hal.rate=16000`, `fire(nominalSampleRate)` + drain → assert `fires.count == 0` (rate flap suppressed). Then `hal.deviceID=43`, `fire(defaultOutputDevice)` + drain → assert `fires.count == 1` (identity still rebuilds).
- `reconciledFormat` (pure, line 2838) and the new `setNominalSampleRate`/read-back path can be unit-tested for the fallback (read-back ≠ 44100 ⇒ `ratePinnedAndHeld == false` ⇒ no suppression).
- The **real pin (`AudioObjectSetPropertyData` on a live aggregate) and the silent-tap-survives-renegotiation question are NOT hermetically testable** — they need real hardware. Do not fake them; assert only the decision logic.
- Run scoped: `swift test --filter NativeCaptureCoordinatorTests`. Full suite runs at commit via the pre-commit Guard 4 (`scripts/run-tests.sh`).

**Live gate (the real proof).** Exactly the spike A/B in §5, run on real BT hardware with a real AirPlay speaker selected. Pass/fail criteria are in §5. This is owner-run (single-instance, §9). Because real audio is involved, run it as a **deliberate feature test**, never during routine build verification (project rule: no audio tests during a live session unless explicitly testing the feature).

---

## 8. Risks, fallbacks, known limitations

**Risks & fallbacks:**
- **Pin not honored** (older macOS, exotic/16 kHz-only device, drift-comp refusal). Fallback is automatic: `reconcileFormatWithAggregate` corrects `format` to the aggregate's actual rate, and `ratePinnedAndHeld == false` disables Part 2's suppression → the code degrades to today's follow-the-device rebuild. Never silence, never hang. The `setNominalSampleRate` set is best-effort (`OSStatus` checked; failure just leaves `ratePinnedAndHeld == false`).
- **Tap goes silent on renegotiation even under a held pin** (the core bet fails). This is caught by the spike, before Part 2 ships. If it fails, Part 2 must not ship; report for redesign. Do NOT let T2 land on the strength of the hermetic tests alone — they cannot see this.
- **Flag left on with a device where the pin flaps between held/not-held** across identity changes: `ratePinnedAndHeld` is recomputed on every `createAggregate` (every rebuild), so it always reflects the current aggregate. No stale state.
- **Regression to the existing pause-on-call / F-SETTLE / F-REANCHOR paths.** Mitigated by keeping the change local to `CoreAudioSystemTap` and gating entirely behind the (default-off) flag; flag-off must be byte-identical behavior (assert via the unchanged existing test).

**Known limitations to document (T4):**
- **Format consistency, not content quality.** Pinning keeps the *format* at 44100; audio *sourced* while the headset is genuinely in 16 kHz HFP is still 16 kHz-quality content resampled up. The win is removing the rate churn/blip, not improving fidelity during HFP. State this plainly so no one expects the pin to make HFP audio sound like A2DP.
- **Resampling artifacts.** Resampling a 16 kHz source up to 44100 via aggregate drift comp may differ subtly from the current teardown-and-rebuild-at-16k path. The live test must LISTEN for added artifacts (warble/aliasing) versus the baseline. If audible, note it as a tradeoff (still likely preferable to the blip, but the user decides).
- **Whole-system only.** Per-app redirects still follow the device (deliberate; upgrade path documented in the `razor:` comment).

---

## 9. Standing project rules the executing agent MUST honor (reader is cold — these are not optional)

- **Only ONE live native test instance at a time.** The PTP helper binds UDP ports 319/320 exclusively — fully **quit any running Audiouter** (including the `/Applications` copy, which is the user's live build — do not touch or overwrite it) before a live test. Build a side-by-side copy via `scripts/make-app.sh` with `APP_NAME`/`BUNDLE_ID` overrides if needed. Before native live tests, sweep stale PTP daemons: `scripts/purge-stale-ptp-helpers.sh` (the `--apply` form needs sudo, so it is owner-run, never mid-session).
- **Never merge** branch→main or worktree→shared **without the user's explicit go-ahead.** The user live-tests first. A global hook also prompts on any `git merge`. This branch is unmerged and stays that way until the user says so.
- **`main` is merge-only** — never commit while standing on `main`, and do not even edit the `main` checkout (a write-guard hook enforces this). All work happens in this worktree.
- **Stage commits by explicit pathspec** (`git add <path> ...`), never `git add -A` / `git add .` — other sessions' uncommitted work may sit in the tree.
- **The pre-commit hook runs the full suite** (`scripts/run-tests.sh`, Guard 4) whenever staged files touch AudiouterCore Swift sources/tests, and blocks on failure. Budget for it. Use `swift test --filter NativeCaptureCoordinatorTests` for the inner loop; never a bare `swift test` for a full run (use `scripts/run-tests.sh`).
- **Docs land with code** in the same branch/commit (docs-first house rule); a symbol you name in an AGENTS.md must exist in that commit's source (Guard 2 warns otherwise). Verify every backticked symbol with `git grep` before writing it.
- **Do not reintroduce a bare `44100`** — use `PCMFormat.airplay.sampleRate`. Do not add a second env-flag style; mirror `AUDIOUTER_PAUSE_ON_CALL` exactly. Mark the deliberate whole-system-only ceiling with a `razor:` comment naming the per-app upgrade path.

---

## Key file:line index (for the cold reader)

_Line numbers are as of the plan date; re-anchor with `git grep`/symbol search before editing — the file is edited by other work on this branch._

- `NativeCaptureCoordinator.swift:2624` `createAggregate()`; **:2643** main-sub-device pin; **:2652** sub-tap drift comp; **:2666** the create call; **:2680** `aggregate_create` telemetry.
- `:2817` `reconcileFormatWithAggregate()`; **:2838** pure `reconciledFormat`; **:2794–2816** the follow-the-device root-cause comment.
- `:2867` `readNominalSampleRate` (add `setNominalSampleRate` beside it).
- `:2980` `subscribeToDefaultOutput()`; **:2984–3003** `tracked` closure; **:3004–3061** `onChange`; **:3060** the unconditional rebuild call to change.
- `:1078` `handleDeviceChange()` → **:1084** `recreateTap(cause: .deviceOrRateChange)`; **:1178** `RebuildCause`; **:1270–1297** make-before-break identity gate; **:1399–1413** re-anchor detection + `onDeviceRateRebuild` fire.
- `:2441` `pauseOnCallEnabled` env-flag pattern to copy; **:29** engine-hardwired-44100 note.
- `DefaultOutputDeviceMonitor.swift:290` `handleNotification`; **:335–362** `deliverToSubscribers` (device OR rate divergence fan-out); **:267** the measured BT `44100→16000→44100→16000` burst.
- `NativeBackend.swift:1284` `onDeviceRateRebuild` wiring; **:2384** `resetAirPlaySessionForWholeSystem`.
- Tests: `NativeCaptureCoordinatorTests.swift:2043` the existing monitor-subscription test to preserve; **:2102** `TapMonitorFakeHAL`; **:2160** `TapMonitorFireCounter`.
- Per-app sibling (out of scope): `PerAppCaptureCoordinator.swift:1140, 1160, 1169, 1443`.
