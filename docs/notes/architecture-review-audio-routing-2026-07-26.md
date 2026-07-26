# Architecture review — audio-routing / capture subsystem

**Date:** 2026-07-26
**Status:** Review complete. Re-evaluated against post-merge `main` later the same day — see
[Re-evaluation](#re-evaluation--2026-07-26-against-post-merge-main). The former blocker is gone (both in-flight
branches merged); the implementation plan is now unblocked but NOT yet written.
**Scope reviewed:** Core Audio capture + local playback + permissions + the `NativeBackend` ↔ `AirPlayEngine` binding seam.

---

## Re-evaluation — 2026-07-26, against post-merge main

The original review was written before the reliability-audit and memory-leak branches landed. Both have since
**merged to main** (reliability audit Waves 1–7 via `5d0d54f`; memory-leak waves via `b46402e`), and the merged work
partially acted on this review — `NativeBackend` carries comments literally labelled "Finding 1" and "Finding 2".
Every claim below was re-verified against current `main`; line numbers in the original body are stale (the files
grew: `NativeBackend` 5353 lines, `NativeCaptureCoordinator` 2564, `PerAppCaptureCoordinator` 1332), but the
findings were re-checked by content, not line number. Per-defect status:

**A — STANDS, evidence strengthened (still L).** No shared lifecycle owner was created. The predicted "same fix
written twice" happened again: *both* coordinators now carry their own nominal-sample-rate listener plus a
`(deviceID, rate)` loop-breaker, independently. `PerAppCaptureCoordinator` still lacks the NaN/±inf/≤0 ASBD
`validate(_:)` guard `NativeCaptureCoordinator` has. Silver lining: both files now contain the same proven,
live-shaped pattern, so unification is extraction of working code, not new design.

**B — ROUGHLY HALF-FIXED on main (M → S).** Landed: the whole-system rebind recovery now claims the *same*
`converging` slot as `convergeDevice` (the "Finding 1" fix — one serialization domain per device for engine ops);
rebind-recovery generation/pending bookkeeping is shared across per-app and whole-system scopes
(`RebindScope`, one recovery chain per device); and the T7 invariant keeps app-route targets *out* of the
whole-system output set — a device is either stream-0 or per-app, never both — which structurally prevents the
original failure mode 1 in steady state. The engine also now consults live C device state in
`addOutput`/`removeOutput` and serializes per-output ops (`opsInFlight`). **Remains:** the engine's silent
idempotent no-op when `addOutput(_:streamId:)` hits an already-live session — explicitly documented in
`AirPlayEngine.addOutput(_:streamId:)` as out of scope ("T6's job if needed") — plus the lack of a per-stream
unbind/query primitive, and the scope-*transition* window (a device moving between whole-system and per-app roles)
still crosses the `converging`/`bindTail` seam. The remaining piece is precisely the engine change the original
review warned not to skip.

**C — CORE FINDING UNCHANGED (still S).** `runProbe()` still short-circuits: a TCC read of `.granted` returns
immediately and skips `functionalGrantProbe()` — the behavioural check is still bypassed in exactly the
cdhash-stale-grant scenario it was built for. Periphery improved: permission reads are centralized through
`SystemAudioCaptureTCC` (private `TCCAccessPreflight`, correct 14.4+ `kTCCServiceAudioCapture` bucket), the
duplicated `CGPreflightScreenCaptureAccess` call sites are gone (only `TCCBucketDiagnostic` keeps one, as a
diagnostic), and T5 telemetry now logs *which* method produced every verdict. But the signal count **grew**
(`PermissionStateObserver`, `TCCBucketDiagnostic`, `TCCProbeRunner`, the `tcc-probe` helper) — better instrumented,
not more unified. `AppRelauncher.relaunch()` still has no caller.

**D — STRUCTURALLY UNCHANGED, acute harm patched (still M, urgency lowered).** Still no owner of the device
sample rate; there are now *three* independent reactors (both coordinators + `LocalPlaybackEngine`, each with its
own loop-breaker). But the full reactive repair chain landed: rate change → tap rebuild → **RTP session reset**,
for both scopes (`resetAirPlaySessionForWholeSystem`, `resetAirPlaySessionForRoutedApp`). That is the root-cause
fix for R10 and the Mac+AirPlay mixed-selection dropout — pending live verification. Note this is exactly the
"add more listeners" direction the What-not-to-do section warned against; it fixed the shipping bugs, and it is
why D's consolidation case still holds. Its urgency drops from "live bug" to "future-proofing before
multi-Bluetooth adds a fourth consumer."

**Verdict and order unchanged:** targeted refactor; A + D together, then B's remainder, then C. Revised sizing:
one L (A), one M (D), two S (B-remainder, C). The work is now consolidation of working-but-triplicated code
rather than bug-fixing.

**New sequencing caveat:** much of the just-merged machinery (rate-reset chain, rebind recovery, Firefox routing)
still awaits Alec's live verification. Consolidating A + D would churn exactly that code and invalidate the pending
live checks — run the owed live-test sessions first, or accept re-running them after consolidation.

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

> **Sizing superseded** — see [Re-evaluation](#re-evaluation--2026-07-26-against-post-merge-main): B shrank to S
> (its Swift-side half landed on main), D's urgency dropped (acute bugs patched reactively). Order unchanged.

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
- **Synced local + AirPlay** is built on the architecture whose mixed-selection dropout (same root cause as A/D)
  was not yet fixed at review time. *(Re-evaluation: the root-cause fix — rate listener + tap rebuild + RTP session
  reset — has since landed on `main`, pending live verification; the synced-local branch still needs `main` merged
  in to pick it up.)*

The debt is not merely coexisting with the roadmap; the roadmap multiplies it. Each fix area gains one more
independent consumer if the features land first.

---

## Blocked on: in-flight branches — RESOLVED

> **Resolved 2026-07-26:** both branches merged to `main` (reliability audit Waves 1–7 via `5d0d54f`; memory-leak
> work via `b46402e`). Steps 1–2 of "When unblocked" were performed as part of the
> [re-evaluation](#re-evaluation--2026-07-26-against-post-merge-main) — the two branches' loop-breaker work did not
> conflict (the guards landed per-coordinator, mirrored, exactly as fix A expects to absorb). Step 3 — writing
> `docs/plans/PLAN-AUDIO-ROUTING-CONSOLIDATION.md` — is the open next step, sequenced after the owed live-test
> sessions. The original text is kept below for the record.

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

---

## Correction — 2026-07-26 (later), against the executed implementation branch

`claude/audio-routing-consolidation-92be71` (roadmap item 007) executed the plan this review called for. Several
things differed from even the re-evaluated predictions above; this section documents what actually happened,
per defect, plus one unrelated bug found along the way.

**A — landed as a PARTIAL consolidation, not the full unification originally envisioned.** T4
(`AudiouterCore/Sources/AudiouterCore/TapRebuildLifecycle.swift`) extracted only the parts of the two coordinators'
rebuild machinery that were provably identical: `TapRebuildCoalescer` (the STABILITY(C6) pending-rebuild flag) and
`TapReanchor` (the `rateMoved`/`deviceMoved` re-anchor compare). The claim/teardown/commit choreography itself —
what the original review's line-number citations were pointing at — stays two bodies in
`NativeCaptureCoordinator.swift` and `PerAppCaptureCoordinator.swift`, now cross-referenced by doc comments instead
of merged. The commit message enumerates why per-step: different state stores (one `_state` enum vs. a dictionary of
reference-type slots), different claim payloads, a per-app mid-rebuild process re-resolve with no whole-system
counterpart, opposite orphan-teardown placement, and the whole-system-only audio I/O workgroup leave/join — a shared
template would have been pure control flow injected as closures, judged harder to audit than the two direct bodies.
Also, by the time of implementation the review's literal file/line structure was stale (both files had grown further
and moved), and the actual sample-rate/loop-breaker duplication turned out to be *less* than the re-evaluation
implied in one respect: once T1 (`DefaultOutputDeviceMonitor`) landed, both taps' compare-before-rebuild decisions
route through the same `TapRebuildDecision` helper the monitor already used, so that specific piece of "written
twice" collapsed into one shared piece as a side effect of fixing D, ahead of A being finished. A is still open work:
the two rebuild bodies remain separately written.

**B — closed for the scope-transition failure mode; two residual risks left explicitly open, not silently dropped.**
T6 added `OutputBindResult` (`AirPlayEngine/Sources/AirPlayEngine/AirPlayEngine.swift`), `boundStreamId(for:)`, and
`rebindOutput(_:toStreamId:)` to `AirPlayEngine`, replacing the silent idempotent no-op the review flagged with a
queryable result and a real move operation. T7 routed both `NativeBackend` paths through one call site,
`bindOutput(_:toStream:)`, which asks the engine which stream a device is really on and moves it if it differs from
the wanted stream — closing the "device changes scope (Selected Device ↔ per-app redirect target) and keeps
streaming its old stream while Swift bookkeeping shows the new one" failure mode. Two things T7's commit message
calls out as deliberately NOT fixed here, carried forward as open items:
- Scope exclusivity (a device is either stream-0 or per-app, never both) is still enforced only in
  `GroupController`, not in `NativeBackend` itself.
- Cross-FIFO ordering between `converging` and `bindTail` is arbitrated *within* a single transition (via the
  engine's per-`OutputID` `opsInFlight` slot) but ordering *between* the two FIFOs across an in-flight transition —
  i.e. a second transition starting on the other FIFO while the first is still in flight — is still unarbitrated.

**C — fixed via code-identity gating, not by removing the short-circuit.** The re-evaluation's core finding stood:
`runProbe()` skipped `functionalGrantProbe()` whenever a fast TCC read already said `.granted`, exactly the
cdhash-stale-grant case the audible tone probe exists to catch. The fix (`ed502dd`) does not remove that fast path —
removing it would mean an audible probe tone on every single permission check, not just the ones that need it.
Instead `CoreAudioTonePermissionProbe` gates the fast path on the CURRENT binary's code identity
(`kSecCodeInfoUnique`) matching the fingerprint that last proved the grant out loud
(`shouldRunFunctionalProbe(tccStatus:storedIdentity:currentIdentity:)`); `SystemAudioCaptureTCC` gained
`provenCodeIdentity()`/`recordProvenCodeIdentity(_:)` to store that fingerprint. No stored fingerprint, or a
mismatch (e.g. after a rebuild), re-runs the audible functional probe.

**D — consolidated behind `DefaultOutputDeviceMonitor`, watcher-only, as decided.** T1 added
`DefaultOutputDeviceMonitor.swift`: exactly one `kAudioHardwarePropertyDefaultOutputDevice` listener and one
`kAudioDevicePropertyNominalSampleRate` listener for the whole process, fanning out to subscribers, each evaluated
against its own tracked device/rate via the shared `TapRebuildDecision` helper. It is a pure watcher — reads and
listener add/remove only, never `AudioObjectSetPropertyData` — consistent with the JUCE `AudioDeviceManager`
external baseline the original review cited (one broadcaster owns device state; no pinning or restoring of hardware
config). T2 migrated both `CoreAudioSystemTap` and `CoreAudioProcessTap` onto it; T5 migrated
`LocalPlaybackEngine` onto the same shared instance (`SharedDefaultOutputMonitor.instance`). All three of the
review's independent reactors now share one listener pair; the reactive repair chain (rate change → tap rebuild →
RTP session reset) the re-evaluation described is unchanged, just fed by one owner instead of three.

**New open finding, not fixed in this branch:** while porting the whole-system tap's guard pattern into the per-app
coordinator (T3), it surfaced that per-app taps still have no equivalent of the whole-system tap's `deviceMoved`
dropout-prevention identity compare (`NativeCaptureCoordinator.swift`, via `TapReanchor.deviceMoved`) —
`PerAppCaptureCoordinator` reacts to rate divergence (T3) but not to the same device-identity-changed check. Flagged
as a candidate follow-up; not fixed here.

**Unrelated bug found and fixed along the way (T-DIAG):** investigating this subsystem for the consolidation work
surfaced a telemetry misattribution bug, not one of the four lettered defects. Two live `PerAppCaptureCoordinator`
instances exist over the same bundle IDs (`NativeBackend.perAppCapture` for routing, `NativeBackend.meteringCapture`
for metering-only), and both emitted `capturePA` transitions with nothing distinguishing which instance spoke —
read together, the interleaved streams described an impossible sequence (a `capturing -> stopping` transition with
no preceding `-> capturing`). Fixed by stamping each transition with the coordinator's existing `name` field as
`coordinator`. Full resolution and per-hypothesis verdict recorded in
`docs/plans/PLAN-LIVE-TEST-HANDOFF-2026-07-25.md`.
