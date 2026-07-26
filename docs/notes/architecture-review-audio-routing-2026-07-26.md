# Architecture review — audio-routing / capture subsystem

**Date:** 2026-07-26
**Status:** Review complete. Verdict issued. Implementation plan NOT yet written (deliberately deferred — see [Blocked on](#blocked-on-in-flight-branches)).
**Scope reviewed:** Core Audio capture + local playback + permissions + the `NativeBackend` ↔ `AirPlayEngine` binding seam.

---

## The question

Is the growing number of interacting pieces in the audio-routing/capture subsystem a sign of poor separation of
concerns that warrants addressing — or is it inherent to the problem domain (real-time audio over shared OS device
state)?

## Method

Six parallel research streams against the then-current `main`:

| Stream | What it did |
|---|---|
| T1 | Mapped duplication between `PerAppCaptureCoordinator` and `NativeCaptureCoordinator` |
| T2 | Mapped `NativeBackend`'s two locking disciplines + traced device-sample-rate ownership |
| T3 | Mapped the competing "is permission granted" signals |
| T4 | Cross-referenced six prior audit/incident memory files for bugs that trace to boundary defects |
| T5 | External research — JUCE, Apple's process-tap API, Rogue Amoeba, single-writer/actor patterns |
| T6 | Synthesis + graded recommendation |

---

## Answer

**Some of both, but substantially more addressable than domain-inherent.**

The domain does impose real constraints: Core Audio exposes one notification channel that many components need to
react to, TCC permission state is genuinely unreliable at the OS level, and audio hardware cannot be copied the way
data can. But in every one of those cases, the established solution is **one owning component per shared resource** —
which is precisely what this subsystem lacks in four places.

**Verdict: targeted refactor.** Not "no change," not a rewrite.

---

## The four boundary defects

### A — Two capture coordinators that duplicate and drift

`AudiouterCore/Sources/AudiouterCore/PerAppCaptureCoordinator.swift` and
`AudiouterCore/Sources/AudiouterCore/NativeCaptureCoordinator.swift` independently re-implement the same
"detect device/rate change → rebuild tap" machinery. There is no shared base class, protocol, or helper that owns
that lifecycle.

Confirmed drift, in both directions:

- `PerAppCaptureCoordinator.swift:939-977` has a `kAudioDevicePropertyNominalSampleRate` listener; on `main` at
  review time `NativeCaptureCoordinator` had **none** (identity-change listener only, `:1015-1037`).
- `NativeCaptureCoordinator` has a NaN/±inf/≤0 ASBD guard (`:875-884`) plus a coordinator-level
  `validate(_:)` (`:353-358`); `PerAppCaptureCoordinator` has neither.
- `PerAppCaptureCoordinator`'s per-buffer pts derivation calls the static always-resample helper
  (`:878`) rather than `NativeCaptureCoordinator`'s cached, self-healing instance path — a divergence
  `NativeCaptureCoordinator.swift:1089-1094` explicitly documents as the slower option.

Both additionally hand-reimplement the same claim-under-lock / teardown-off-lock / commit-under-lock shape, the same
STABILITY(C6) pending-device-change coalescing flag, the same aggregate-device dictionary construction, and the same
teardown ordering. Each is separately written; a fix to one has no structural path to reach the other.

The one genuinely shared abstraction is `AudioProcessResolver.swift`, consumed correctly by both.

### B — Two locking disciplines racing over one engine resource

In `AudiouterCore/Sources/AudiouterCore/NativeBackend.swift`:

- `converging` (`:287`) serializes the whole-system "Selected Devices" path — engine `stream_id` 0.
- `bindTail` (`:368`) is a separate global FIFO serializing the per-app redirect path — `stream_id` ≥ 1.

Each serializes itself correctly. Neither knows the other exists, and both drive the same
`AirPlayEngine.addOutput`/`removeOutput` against the same device. `AirPlayEngine.swift:713-759` permits exactly one
live session per device and responds to a mismatched stream-id assumption with a **silent idempotent no-op, not an
error**. `added` and `streamBindings` never cross-invalidate.

Two confirmed failure modes:

1. A per-app bind silently no-ops when the device is already added at stream 0. Swift bookkeeping records the app as
   routed; the C session never moved. Audio is written to a stream the device never joined — the app shows as routed
   and is inaudible.
2. A whole-system add/remove silently kills or fails to rebind a live per-app session.

Part of the root cause is structural in the engine layer — there is no primitive to unbind one stream without tearing
down the device's whole session, and no way to query which stream currently owns it. A Swift-side-only fix would
look complete while leaving the silent no-op intact.

### C — Competing permission signals

Four signals, imperfectly reconciled:

| Signal | File | Role |
|---|---|---|
| `SystemAudioCaptureTCC.isGranted()` | `SystemAudioCaptureTCC.swift:39-80` | **Canonical.** Correctly gates every real tap creation. |
| Tone-probe + `currentStatusSilently()` | `AudioCapturePermissionProbe.swift:96-249` | UI-only; drives `SetupModel.audioStatus` / `PermissionRowView` |
| `CGPreflightScreenCaptureAccess` | two independent call sites | pre-14.4 fallback, duplicated rather than shared |
| System Settings' own toggle | — | uncontrolled fourth signal the user actually sees |

The part that matters is done right: the capture gate consults the canonical check. The defect is in the secondary
readers.

Sharpest finding: the functional tone-probe — which exists specifically to catch grants that TCC reports as
`.granted` but the OS will not honor (the cdhash-pinned stale-grant case) — **short-circuits and skips its own
behavioural verification whenever the TCC read already says granted** (`AudioCapturePermissionProbe.swift:136-145`).
It is bypassed in exactly the scenario it was built for.

Also flagged: `AppRelauncher.relaunch()` has no external caller. (Correction to an earlier draft of this review:
`AppRelaunchCommand.swift` lives in `AudiouterCore`, is live, and is covered by a test — only `relaunch()` itself is
uncalled.)

### D — The unowned shared sample rate

**No component owns the default output device's nominal sample rate.**

- `LocalPlaybackEngine.swift` perturbs it — `setDeviceID` on every cold `start()` (`:650`) — with no coordination
  check against anything currently depending on the existing rate.
- `PerAppCaptureCoordinator`'s taps react correctly.
- `NativeCaptureCoordinator`'s whole-system tap (which feeds AirPlay's stream 0) reacted only to device *identity*
  swaps, not in-place rate renegotiation.
- `AirPlayEngine` is fully insulated — writes its own fixed internal format, never touches the HAL device.

This is the direct root cause of the live bug: selecting the Mac alongside an AirPlay device kills AirPlay. Opening
the built-in output renegotiates the shared device 48↔44.1 kHz, the whole-system tap goes to all-zero buffers, and
nothing triggers a rebuild. The meter keeps showing activity because it reads buffer *cadence*, not content.

---

## Evidence this is causing real harm

Eight distinct, already-diagnosed bugs across three separate audit files trace to these defects. Bugs that did *not*
trace to them (process-resolution gaps, UI validation, vendored-C memory safety, dead-code omissions) were explicitly
excluded rather than force-fit.

| Bug | Defect |
|---|---|
| R10 — whole-system tap silent on mic engagement, UI still "connected" | A (+D) |
| Synced-local mixed-selection dropout (Mac + AirPlay kills AirPlay) | A + D |
| `.currentDevice` local playback dies through mic | D — a *third* component reacting incompletely |
| coreaudiod CPU/fan storm — many independent per-tap rate listeners on one device, no shared debounce | D |
| Storm loop-breaker had to be landed **twice**, once per coordinator | A + D |
| T16 whole-system self-heal "mirroring the per-app path" | A |
| L1 tap-resurrection race (orphan muted tap silences app system-wide) | weak/other — flagged, not counted |

The recurring signature: *the same fix, written twice, because nothing owns the thing being fixed.*

---

## External baseline

| Source | Finding |
|---|---|
| JUCE `AudioDeviceManager` | One `ChangeBroadcaster` owns device state. JUCE itself shipped a staleness bug when a second internal cache diverged — fixed by re-centralising, not by adding listeners. |
| Apple Core Audio process taps | **One** API surface (`CATapDescription`) covers per-process *and* system-wide capture via a parameter. Two coordinators is not something the API forces. |
| Rogue Amoeba | Publicly consolidated Loopback / Audio Hijack / SoundSource / Airfoil from separate backends onto one shared ARK capture engine. |
| TCC / permissions | Genuinely flaky at the OS layer. Accepted mitigation everywhere: **one wrapper with an internal fallback chain** — never multiple independently-trusted checks that can disagree at runtime. |
| Single Writer Principle / actor model | Named, established pattern. "You cannot take a copy of the hardware." Two ad-hoc locking disciplines over one binding is a textbook violation; Swift actors are a first-class fix. |

No source treats duplicated coordinators, dual locking, or multiple disagreeing permission checks as intentional
design. All treat this shape as normal organic accumulation, resolved by a deliberate consolidation pass — which is
what both JUCE and Rogue Amoeba actually did.

The scale here is larger than a healthy resting state, but entirely consistent with a small team building real Core
Audio integration against thin, under-documented Apple APIs. It is not evidence of a rotten foundation.

---

## Recommended fixes

| # | Fix | Size | Rationale |
|---|---|---|---|
| A | Unify the two capture coordinators behind one shared lifecycle owner | **L** | Largest, most safety-critical files; changes the tap-rebuild trigger surface, so most of the calendar cost is live-audio testing, not typing |
| B | One device-session arbiter shared by both `NativeBackend` paths | **M** | Swift-side arbitration is contained, but budget for a small `AirPlayEngine` change — the silent no-op must become queryable or an error |
| C | One canonical permission wrapper; reconcile UI readers through it | **S** | The hard part (the capture gate) is already correct. Low risk. Confirm the `relaunch()` dead path while in here |
| D | An explicitly-owned device-sample-rate component | **M** | Conceptually small, but coordinates three existing components; same live-audio testing surface as A |

**Order: A + D together first, then B, then C.** A and D touch the same trigger surface and share a test pass —
splitting them means testing it twice.

Rough total: one L, two M, one S. A coherent consolidation pass for one engineer who knows this code, with most of
the elapsed time in live verification.

## What not to do

- **No rewrite / "full architecture overhaul."** The canonical permission gate and the shared process resolver
  already work. A rewrite would re-risk the by-ear-verified AirPlay path for no proportional gain.
- **Don't treat this as an emergency.** This coupling level is a normal resting state for the constraints involved.
- **Don't fix B on the Swift side alone** — it would look done while the engine's silent no-op survives.
- **Don't add more listeners or checks to paper over C or D.** Every external source says the fix is *fewer,
  centralised* owners. Adding another listener is how JUCE got its bug.

---

## Roadmap impact

Both unbuilt features make this worse if the foundation is left alone:

- **Multi-Bluetooth** (`docs/plans/PLAN-UNIVERSAL-SYNC.md`) explicitly proposes a **third** parallel routing path
  (`BTSyncedSink`) alongside the AirPlay-engine and local paths, independently touching the same unowned
  device-rate/clock surface — and contains no remediation of its own. Two things that drift apart become three.
- **Synced local + AirPlay** is built on the architecture whose mixed-selection dropout (same root cause as A/D) is
  not yet fixed.

The debt is not merely coexisting with the roadmap; the roadmap multiplies it. Each fix area gains one more
independent consumer if the features land first.

---

## Blocked on: in-flight branches

The implementation plan was deliberately **not** written yet. Two branches carry unmerged work that changes the
starting state:

1. **`claude/reliability-audit-0defe7`** — already adds to `NativeCaptureCoordinator` a nominal-sample-rate listener,
   a `lastNominalSampleRateKey` field, `handleNominalSampleRateChanged`, an `onNominalSampleRateChanged` seam on
   `CoreAudioSystemTap`, and a `(deviceID, rate)` compare-before-rebuild **loop-breaker guard** (labelled
   "W2-T1, fixes R10"). This *ports/mirrors* the `PerAppCaptureCoordinator` pattern — it does not unify it. Also
   carries unrelated fixes: R1/R2/R9/R14 (process resolution), R11/R12 (dead/offline speakers), R13 (BT follows
   default device).
2. **`memory-leak-investigation-…`** — Waves 1–3: five leak fixes, a storm loop-breaker (possibly the *same* guard as
   above — must be checked, not assumed), hygiene/backpressure work, and a Firefox multi-process routing fix.

**Do not merge-block either branch on this review.** Landing them fixes real bugs now and leaves one already-tested
pattern to fold into the unified component later — strictly easier than unifying from a blind start. Fix A absorbs
that work; it does not duplicate or revert it.

**Why planning is deferred:** both branches share an old merge-base and `main` has advanced since, so a naive
`git diff main..branch` conflates branch changes with `main`'s own progress. Any "assumed starting state" derived
that way is untrustworthy. Write the implementation plan once both branches are rebased onto current `main` — or
merged.

### When unblocked

1. Diff both branches against current `main` for: `NativeCaptureCoordinator.swift`, `PerAppCaptureCoordinator.swift`,
   `NativeBackend.swift`, `SystemAudioCaptureTCC.swift`, `AudioCapturePermissionProbe.swift`, `AirPlayEngine.swift`,
   `LocalPlaybackEngine.swift`.
2. Diff the two branches against **each other** for line-level conflicts — especially any overlapping loop-breaker
   work in `NativeCaptureCoordinator`.
3. Write `docs/plans/PLAN-AUDIO-ROUTING-CONSOLIDATION.md` against that real starting state, self-contained enough for
   an agent with no context to execute.

Standing project rules apply to the eventual execution: work in a dedicated worktree (not the live `main` checkout),
staff-level review before it reaches Alec, and no merge without his explicit go-ahead.
