# PLAN-RELIABILITY — audio always comes out where you pointed it

*Drafted 2026-07-24 from the two-round reliability audit (branch
`claude/reliability-audit-0defe7`). Audit was code-reading only — no audio was
played, no code changed. Every finding cites the file/line it was verified at.*

---

## Execution status (updated 2026-07-25)

**Waves 1–7 are ALL code-complete** — all on `claude/reliability-audit-0defe7`,
NOT yet merged into `main`. Nothing here has ever been verified with real
audio; every claim below is build + hermetic-test only, per the standing
no-agent-plays-audio rule. Live verification is a separate, not-yet-done step
(see "What remains").

### Waves 4–7 (2026-07-25)

Executed via `/orchestrate` (research → explicit tasks → per-task model/effort
→ parallelization waves → watched background agents), with every batch
reviewed against spec + a real build/test pass before committing — not just
trusted from an agent's own report (see the T6/T9 note below on why that
distinction mattered in practice).

| Landed as | Fixes | Files | Commit |
|---|---|---|---|
| Gap-closing (pre-Wave-4) | Sleep must clear in-flight rebind recovery | `NativeBackend.swift` | `1c68727` |
| Gap-closing | Re-ported R9 regression test | `NativeBackendTests.swift` | `5510593` |
| Gap-closing | Exclusion-rebuild clock re-anchor window (completeness gap #4 below) | `NativeCaptureCoordinator.swift` | `5d42fb7` |
| T1 (Wave 4, R5) + T11 (Wave 7 armor) | Per-app route survives target going briefly unreachable; `DefaultSystemOutputDevice` selector guard | `AppRoutingController.swift`, `PopoverController.swift`, `NativeBackend.swift` + new `OutputSelectorGuardTests.swift` | `1da459f` |
| T2, T4, T7 (Wave 4 cont'd + Wave 6/R4) | Failed per-app bind stops lying about streaming; "Resume → device" offer after relaunch; Mac+AirPlay groups actually play everywhere | `NativeBackend.swift`, `AppRoutingController.swift`, `PopoverController.swift`, `AppRowView.swift`, `GroupController.swift`, `AppDelegate.swift` | `850922f` |
| T3, T6 (Wave 4 cont'd + Wave 5 stopgap) | `.device` routes clear on every app launch; "may reduce quality" note for same-speaker double-routing | `AppRoutingController.swift`, `AppDelegate.swift`, `PopoverController.swift` | `fe452ae` |
| T8, T9 (Wave 6, R16) | Popover states the real Audio Out destination; menu-bar icon distinguishes idle/streaming | `PopoverController.swift`, `Package.swift`, `AppDelegate.swift`, `StatusItemController.swift` + new `MenuBarStatus.swift` | `7ad75e6` |

R5's actual shape ended up broader than the plan's one-line "keep the route,
badge it offline" sketch, resolved live with the owner before implementation: the
app rejoins normal system audio while its target is unreachable (not silence,
not forced local-only), the route clears only on TRUE device disappearance or
an Audiout relaunch (not the old "isAvailable == false" trigger — that now
keeps the route), and `NativeBackend` computes an *effective* route table (a
`.device` route whose target can't carry audio right now reads as
`.noRedirect` for every per-app mechanism — capture start/stop, the
whole-system tap's exclusion set, the mixer, local playback, metering — while
`lastRoutes`, the user's real intent, is untouched) so the redirect re-engages
itself the instant the device is reachable again, with no route-table edit in
either direction.

R4's real mechanism, corrected from the original finding: it is NOT that
`GroupEditorViewController` offers the Mac while `GroupController.applyRouting`
filters it back out with no explanation (that popover-side local-mix block was
already retired when synced-local playback shipped — verified via
`GroupController.canSelectLocalSpeaker` unconditionally returning `true`). The
actual bugs were `GroupController.activateGroup` never filtering the local
device out of `setOutputSet` (violating that call's own documented contract)
and `NativeBackend`'s synced-local-sink arming decision reading
`isSpeakerSelected` (Selected Devices only) instead of true Main Out
membership — so a group containing the Mac never armed the sink. Fixing the
second bug also fixed a third, previously-unknown one for free: the old wiring
could arm the sink WRONGLY, playing the Mac when an AirPlay-only group was
active and the Mac merely still sat in the untargeted Selected Devices set.

**R3 (Wave 5) is the honest stopgap now, with a build recommendation for
later, not a decision to leave it as-is.** A dedicated investigation (T5)
confirmed the root cause precisely — two independently-scheduled per-app
Core Audio taps get nearest-frame-quantized onto a shared nominal-44100Hz
wall-clock grid with zero fractional interpolation
(`AppRouteMixer.swift:342-350`'s own comment names this) — and found the two
hardest components a real fix would need (a resampler proven click-free to
±200ppm, and a control loop proven convergent/non-oscillatory) **already
exist in this codebase**, built for the unrelated synced-local-sink problem
(`PhaseController.swift`'s `FractionalResampler`/`PhaseController`). The
investigation's recommendation: build the real fix as a near-term follow-up
rather than treat the label as permanent — it's well-scoped integration work,
not open-ended DSP risk. Not scheduled; needs its own task when picked up.

**R16's virtual-output-device idea (Wave 6, the bigger half) got a dedicated
research spike (T10), not a build.** The literal ask — a single "Audiout"
entry in System Settings → Sound that becomes the visibly-selected output
while routing, so a glance there makes obvious what's active — is achievable
only via the legacy `AudioServerPlugIn` HAL-plugin API (DriverKit/
AudioDriverKit explicitly does not support virtual devices, confirmed twice in
Apple's own docs). Recommendation: **don't build the full driver.** It's
root-installed and reboot-gated on install/uninstall, and — the decisive
point — if Audiout crashes or is force-quit while set as the default output,
the user is left silent with no real device selected, which inverts the
safety rationale that motivated the feature (today a crash leaves you on real
speakers). Instead, the spike surfaced a cheap ~1-day alternative worth trying
first: a *public* `AudioAggregateDevice` named "Audiout"
(`kAudioAggregateDeviceIsPrivateKey: false` — the tap coordinators already
create aggregates, just always private) — no root, no install, no reboot,
using an API this app already calls. Two things are unverified and would need
testing before trusting it: whether a public aggregate actually surfaces in
the Sound *pane* (only Audio MIDI Setup's manual "make default" is documented),
and whether "aggregate of aggregates" breaks the existing capture taps built on
top of it (one third-party forum report says it does; not confirmed here).
Not scheduled; the cheap visibility half (T8/T9 above) shipped instead.

**A process note worth keeping**: the first attempt at T6 (Wave 5's stopgap
label) came back from a background agent as a fully-described, verified
success — specific test names, a stash-based pre/post-fix proof, all of it —
but `git status`/`git diff` afterward showed ZERO trace of any change; the
actual edits were lost, most likely mishandled during the agent's own
`git stash` verification step in a worktree shared with other concurrently
running agents. Caught only because every agent batch in this run was diffed
and independently rebuilt/retested before committing, never taken on the
strength of its report alone — re-implemented directly rather than trust a
second report without re-verifying. Worth remembering next time multiple
agents share one worktree: `git stash` there is riskier than it looks, and a
completion report is a claim, not proof.

### Done and committed

| Wave | Fixes | Commits |
|---|---|---|
| 1 — Multi-process capture core | R1, R2, R9, R14 | `106b5e4`→`06b017b` (7 commits) + remediation `e3e577c` |
| 2 — Never-silent guardrails | R10, R11, R12 | `e42e629`, `4eac431`, `ea83e48`, `6c74057` + remediation `219ceaf` |
| 3 — Default-output correctness | R13 | `ca446a3`, `8bb042f` + hardening `8337445` |

Three rounds of adversarial (skeptic-agent) review ran against this work —
one per wave, plus a final pass — and every REFUTED finding they produced was
fixed before the next wave started. Two lower-severity PLAUSIBLE items were
deliberately deferred (see below).

**Merge with `main` (2026-07-24, commits `fe19ce8` + `a20ce72`):** `main` had
independently grown a telemetry system and a "dropout-fix" workstream that
duplicated several of the same fixes (whole-system RTP reset, nominal-rate
listener, `convergeDevice` serialization) with a more surgical trigger
(reset only on a device/rate rebuild, never on the routine per-connect/
exclusion rebuild — main's version, kept). 122 conflict blocks were resolved
on the rule "prefer main's version for the overlapping audio fixes, keep our
unique reliability fixes, take main's unique fixes + telemetry." A dedicated
adversarial pass then challenged that reconciliation itself (not just the
code) — 5 of 6 decisions held; one did not (below). Verified post-merge:
1059+ tests green, serial, on Xcode 27 / Swift 6.4 (the toolchain default
changed mid-session; see build note at bottom).

**Superseded by the merge, not by us:** the `ProcessSetResolver` /
`AppProcessResolver` seam from Wave 1 was replaced by main's
`AudioProcessResolver`, with our Wave-1 hardening (live-membership diffing,
the exclusion storm-guard, the translated-object-set leak fix) ported onto
it. **This retires the Wave 7 "Finding 5 — Chrome channel over-match" entry
below**: `AudioProcessResolver.resolve(bundleID:)` matches on an *exact*
effective bundle ID (own reported id, or a parent-pid walk) — there is no
dotted-prefix string match anywhere in the code that's actually in the tree
now, so the Chrome Canary/Beta/Dev sibling-capture bug the old resolver had
does not exist in the current implementation. No action needed; the entry
is kept below only as history.

### What remains

Items 1, 3, and 4 from the original list (sleep/rebind-recovery gap, R9's
missing test, the exclusion-rebuild clock window) are CLOSED — see the
gap-closing commits at the top of the table above. What's actually left:

1. **Live testing — not yet done, not this session's job right now.** Per
   the owner's 2026-07-24 decision, all live audio testing is consolidated into
   the `claude/memory-leak-live-testing` session (bundle-id / PTP-port
   collision risk from running two Audiout instances). The full live
   checklist per wave is unchanged and listed under each wave below, now
   joined by Waves 4–7's own checklist items. Two live-testing findings from
   that session, for context (not this branch's bugs): the ~8% pitch-up was
   root-caused and fixed there (a per-app tap format-reconciliation bug,
   commit `196e5b7` on their branch — this branch's work never touched that
   code path); a judder→stop→silence symptom on redirecting Firefox is still
   being chased there.
2. **R3's real fix** (shared-clock resampling instead of the wall-clock
   frame grid) — sized and recommended by T5's investigation above, not yet
   scheduled as its own task.
3. **R16's virtual-output-device idea** — spiked and NOT recommended as a
   full driver build by T10 above; the cheap public-aggregate alternative is
   unverified and untried. Not scheduled.
4. **A CONFIRM item from the original findings register worth reconsidering
   now that Waves 4-7 are done**: R7 (AirPlay-1 speakers excluded from
   per-app destinations) is a deliberate product decision documented at
   `PopoverController.swift` (search `availableAirPlayDestinations`'s doc
   comment) — NOT a defect, and intentionally never had a task in this
   execution pass.

### Build note for whoever picks this up

The machine's toolchain changed mid-session — `xcode-select` now defaults to
Xcode 27 / Swift 6.4. A clean rebuild of `CAirPlayEngine` needs
`CPATH=/opt/homebrew/include:/opt/homebrew/opt/libevent/include` set (Xcode
27's explicit-module scanner can't find `event2/thread.h` otherwise);
incremental builds with a warm cache don't need it. `main` has since gained
commits capping test-suite parallelism at 4 workers and pinning
`--build-system native` for Xcode 27 compat — both already merged into this
branch. Prefer **serial** `swift test` over `--parallel` when verifying;
`PerAppCaptureCoordinatorTests` has a known pre-existing signal-5 crash
under parallel load, unrelated to this plan's changes.

---

The goal: make Audiout one of the most reliable audio-switching apps that
exists. Concretely, that means four invariants the app must uphold at all
times. Every wave below exists to make one of them true.

## The four invariants

1. **Selection is truth.** Sound comes out of exactly the devices the user
   pointed it at — never fewer (silent speaker), never more (leak into the
   system mix), never doubled (same app on two paths).
2. **Never silent without saying why.** Any state where *nothing* is audible
   for more than a few seconds must self-heal to local playback — without
   erasing the user's selection — and show a reason in the popover.
3. **Intent survives hiccups.** Wi-Fi blips, sleep/wake, app relaunches,
   sample-rate renegotiation, and headphone/BT switches never erase what the
   user chose. Only the user changes intent.
4. **The UI never lies.** "Connected" means audibly streaming; meters mean
   real captured audio; device labels name the real device.

---

## Findings register

Severity: **P0** = headline feature silently broken · **P1** = total silence /
wrong physical device · **P2** = confusing or degraded, workaround exists.

### Round 1 — routing model

| # | Sev | Finding | Root cause (verified at) |
|---|-----|---------|--------------------------|
| R1 | **P0** | Routing a browser / Electron / Chromium app (Firefox, Chrome, Spotify, Discord…) to a speaker does nothing; the app follows Main Out instead | Per-app capture and stream-0 exclusion resolve `bundleID → first main pid` only; these apps play audio from a **child process**. `AppDelegate.swift:43`, `NativeCaptureCoordinator.swift:354` |
| R2 | **P0** | Excluding a browser/Electron app in Settings does not keep it local — it still streams | Same single-pid resolution feeding the exclusion set |
| R3 | P2 | Two apps routed to the **same** speaker → warbling/slowed audio | Multi-contributor timeline mix is documented known-imperfect. `AppRouteMixer.swift:365` |
| R4 | P1 | Groups editor lets you build a group of **Mac + AirPlay speaker**; activating it silently drops the Mac (only the speaker plays) | Editor offers the local device (`GroupEditorViewController.swift:223`) but `applyRouting` filters it out (`GroupController.swift:358`). The popover's Selected Devices path blocks this same mix *with an explanation* (`GroupController.swift:255`); the editor doesn't |
| R5 | P1 | A per-app-routed speaker that goes **briefly** unavailable has its route silently and permanently reset | Any `isAvailable == false` snapshot resets the route. `PopoverController.swift:404` → `AppRoutingController.handleDeviceUnavailable` |
| R6 | P2 | A routed app that quits (or self-updates/relaunches) loses its route | Deliberate product decision 2026-07-22 (`AppDelegate.swift:332`) — kept, but see Wave 4's "resume" affordance |
| R7 | P2 | AirPlay-1 speakers never appear as per-app destinations; mixed AP1+AP2 groups drift out of sync | AP1 filtered by design (`PopoverController.swift:1107`); no shared clock for AP1 in groups |
| R8 | P2 | A speaker receiving only a per-app stream shows no connected dot | Connection state is driven by the Selected-Devices path only |
| R9 | P2 | Routing an app before it plays sound can double-send briefly once it starts | Exclusion pids resolved before the process is audible |

### Round 2 — capture/device layer

| # | Sev | Finding | Root cause (verified at) |
|---|-----|---------|--------------------------|
| R10 | **P0** | Join a Zoom/FaceTime call while streaming → **every speaker goes silent, UI says connected**. Mic engagement renegotiates the output sample rate; the tap keeps delivering all-zero buffers | Whole-system tap has **no** `kAudioDevicePropertyNominalSampleRate` listener (`NativeCaptureCoordinator.swift` — only the identity listener at :1015). The per-app tap has the fix (`PerAppCaptureCoordinator.swift:965`) |
| R11 | **P1** | Main Out → group whose speakers fail or are offline → **Mac muted + total silence, indefinitely** | Capture gate keys on intent, ignoring availability by design (`NativeBackend.swift:3112`); the `.failed` cleanup only runs for Selected-Devices members (`isSpeakerSelected` guard, `PopoverController.swift:893`) — group members have no fallback |
| R12 | P1 | A Selected-Devices speaker that fails one reconnect is **auto-unselected forever**; when it returns, audio stays on the Mac | `.failed` edge calls `setDeviceSelected(id, false)` — erases intent. Opposite of R11's behavior; both surprising |
| R13 | **P1** | User listens on Bluetooth headphones; a "Current Device" app plays **out loud from the built-in speakers** | `LocalPlaybackEngine` is pinned to built-in output deliberately (`LocalPlaybackEngine.swift:103`) to avoid an AirPlay-default loop — but has no follow-with-guard logic. Includes the deferred "dies through mic" config-change bug |
| R14 | **P0** | An excluded **or** routed app that relaunches leaks back into the system mix (excluded: plays on speakers anyway; routed: plays **doubled** — target + Main Out) | Exclusion pids re-resolve only when the bundle-ID *union* changes or the tap is recreated (`NativeCaptureCoordinator.swift:314`); `handleAppLaunched` restarts the per-app tap but never touches the system tap (`NativeBackend.swift:1635`) |
| R15 | P1? | Plugging in / switching headphones mid-stream rebuilds the system tap with **no AirPlay session reset** — the per-app path documents exactly this rebuild as "desynced… receiver stays silent" and resets; stream 0 doesn't | `NativeBackend.swift:1401` (per-app reset) has no stream-0 counterpart. Needs one live check to confirm severity |
| R16 | P2 | Nothing tells the user "Audiout owns the audio" — macOS Sound settings keeps showing the physical device | Process-tap architecture; only a virtual output device changes the Sound panel |

Verified healthy along the way: native backend is the default (mock is
opt-in, `OwnToneBackend.swift:806`); the alert-device selector
(`DefaultSystemOutputDevice`) is fully purged; the LocalPlaybackEngine
lock-inversion fix is present in this tree (live smoke test still owed).

---

## The program

Ordered by user pain, not by code area. Each wave ends with a silent
verification I do (build + hermetic tests) and a short **live checklist the owner
runs** — per the standing rule, no audio is ever played by an agent.

### Wave 1 — Multi-process capture core *(fixes R1, R2, R9, R14 + dead browser meters)*

The umbrella fix for the browser bug, and the highest-leverage change in the
whole program. This executes the already-approved
PLAN-FIREFOX-ROUTING-LEAK scope (that plan lives in the
memory-leak-investigation worktree; this wave subsumes its capture half).

- **Process-set resolver replaces single-pid lookup.** Enumerate
  `kAudioHardwarePropertyProcessObjectList`, read each process object's bundle
  ID and pid, and group helpers to their owning app (bundle-ID prefix match +
  responsible-pid walk — Chrome helpers carry `com.google.Chrome.helper`,
  Firefox children carry the parent's identity). One bundle ID resolves to a
  **set** of process objects.
- **Tap the set.** `CATapDescription(stereoMixdownOfProcesses:)` already
  accepts multiple objects; the per-app tap taps the full set. The system
  tap's exclusion (`stereoGlobalTapButExcludeProcesses`) excludes the full set.
- **Live membership.** Browsers spawn/kill audio children per tab. The
  process-object-list listener (already installed for resume self-heal,
  `PerAppCaptureCoordinator.swift:467`) additionally diffs per-bundle process
  sets; a change rebuilds the affected tap / exclusion — debounced, guarded by
  a `(deviceID, processSet)` compare-before-rebuild so churn can't thrash
  (same discipline as the CPU-storm loop-breaker).
- **Relaunch correctness for free:** a relaunched app's new pids enter via the
  same listener → R14 dies with the same stone. Spike first:
  `kAudioTapPropertyDescription` may allow updating a live tap's process list
  without a full recreate — if it works, rebuilds get dramatically cheaper.

*Silent proof:* hermetic tests with a fake process list modeling a
multi-process app (spawn/kill children, relaunch, exclusion). *Live checklist:*
route Firefox → speaker (audio moves, Mac silent); exclude Chrome while
streaming (stays local); quit+relaunch Spotify mid-route (no double audio).

### Wave 2 — Never-silent guardrails *(fixes R10, R11, R12; hardens R5's cousin)*

Invariant 2 becomes structural instead of accidental.

- **Port the rate fix to the system tap.** Nominal-sample-rate listener →
  tap rebuild → stream-0 session reset, exactly as the per-app path does —
  plus the `(deviceID, nominalRate)` compare-before-rebuild loop-breaker from
  the CPU-storm diagnosis (T8/T10), so the fix can't reintroduce the rebuild
  storm.
- **Generalized silence watchdog.** Whenever the capture gate is ON but zero
  desired devices are `.connected` for T seconds (default ~10 s; same settings
  family as the wake-restore delay), un-gate capture — Mac becomes audible —
  **without clearing intent**, and show a popover banner: *"Speakers
  unreachable — playing on this Mac. Will resume automatically."* A reconnect
  re-engages the gate seamlessly. This is the wake watchdog generalized to
  every path, which closes R11 (group of dead speakers) outright.
- **Unify failure semantics: keep intent, always.** Stop auto-unselecting on
  `.failed` (R12). The row shows the failed state + diagnosis panel as today;
  the watchdog keeps the Mac audible; when discovery sees the device again, it
  re-converges automatically (the converge loop already re-kicks on discovery
  updates). Groups and Selected Devices behave identically.

*Live checklist:* stream to one speaker, power it off → within T seconds Mac
plays + banner; power on → audio moves back without touching the UI. Join a
Zoom call mid-stream → speakers keep playing.

### Wave 3 — Default-output correctness *(fixes R13, R15; the Bluetooth layer)*

- **Follow-real-output-with-guard for `.currentDevice` playback.** The local
  engine follows `kAudioHardwarePropertyDefaultOutputDevice` **unless** the
  default is an AirPlay-class device or one of our own aggregates (loop
  guard) — then it falls back to built-in. BT headphones now receive
  "Current Device" app audio, as expected. Also rebuild on the
  config-change path that currently kills it (the deferred "dies through
  mic" bug).
- **Stream-0 continuity across tap recreate.** Add the same post-rebuild
  session reset the per-app path has (or prove live it isn't needed — one
  checklist item). Covers plugging in headphones / switching default output
  mid-stream (R15).
- **System-AirPlay guard.** If the user sets an AirPlay device as the *system*
  default output while we stream, surface a note (double-path audio /
  echo risk) rather than silently capturing an AirPlay-bound mix.

*Live checklist (the owner, with BT headphones):* passthrough with BT — all normal;
route an app to Current Device while wearing BT — audio in the headphones, not
the room; start a stream, then plug/unplug headphones — speakers keep playing.

### Wave 4 — Per-app route durability *(fixes R5, R8; revisits R6)* — EXECUTED

- **Grace period instead of silent reset — DONE, shape resolved live with
  the owner.** Rather than "keep + badge 'speaker offline'", the app REJOINS
  normal system audio while the target is unreachable (the smallest, safest
  option of three considered — a forced local-only mode was rejected as
  higher-risk, silence-with-a-badge was rejected as violating invariant 2)
  and the route clears only on a TRUE disappearance or an Audiout relaunch
  (simpler than "gone > a long horizon" — no new persisted timestamp needed).
  See "Execution status" above for the full mechanism (`1da459f`, `fe452ae`).
- **Connection dot for redirect targets — folded into the R5 work, smaller
  than scoped.** R8 as originally described (no dot at all for a
  redirect-only device) turned out to already be fixed in this tree by the
  time this wave ran; what remained was that a bind FAILURE still falsely
  claimed to stream (`850922f`, T2) — that's now fixed. `Device
  .connectionState` itself was deliberately left untouched (out of scope —
  feeds the diagnosis panel/failedGate/R11 watchdog, a separate concern).
- **R6's relaunch affordance — DONE** (`850922f`, T4): a "Resume → Kitchen"
  entry in the app's destination dropdown, in-memory only (forgotten on
  Audiout's own quit, not persisted), consumed the moment any destination
  is picked.

### Wave 5 — Same-speaker multi-app quality *(R3 — decide after Wave 1)* — EXECUTED (stopgap; real fix sized, not built)

The stopgap (b) shipped (`fe452ae`, T6): a device already carrying a
different app's redirect gets "Already in use — may reduce quality" on its
own destination-menu entry. The real fix (a) was investigated, not built
(`T5`) — see "Execution status" above for the recommendation: it's
well-scoped integration work (the hard DSP primitives already exist in this
codebase for an unrelated problem), worth doing as a near-term follow-up
rather than leaving the label as the permanent answer.

### Wave 6 — "We are the output" visibility *(R16 + the owner's Sound-panel idea)* — EXECUTED (cheap half; driver half spiked, not built)

- **The cheap half — DONE** (`7ad75e6`, T8/T9): the popover's Audio Out row
  states the real destination ("→ Kitchen + Move 2" / "→ This Mac" / "→
  Kitchen Group" for a saved group — named, not enumerated), and the
  menu-bar icon distinguishes idle (outline) from actively streaming (filled,
  system accent color) — "streaming" counts either Main Out or a live
  per-app route, not just the former.
- **R4 (the group-editor half of this wave) — DONE, but the real bug was
  different from this plan's description**, and no editor UI change was
  needed. See "Execution status" above: the popover-side local-mix block this
  entry describes was already retired before this wave ran; the actual fix
  was backend wiring (`850922f`, T7).
- **The virtual-output-device decision item — SPIKED, not built** (`T10`):
  don't build the full driver (reboot-gated install, and a crash while set as
  default output leaves the user silent — inverts the safety rationale that
  motivated it). A cheap public-aggregate-device alternative surfaced instead,
  unverified. See "Execution status" above.

### Wave 7 — Regression armor — PARTIALLY EXECUTED

- **Selector guard in CI — DONE** (`1da459f`, T11): `OutputSelectorGuardTests`
  scans `AudioutCore/Sources` + `AirPlayEngine/Sources`, comment-stripped,
  for `kAudioHardwarePropertyDefaultSystemOutputDevice`.
- **Route-truth test suite — NOT a separate task; folded into each
  implementing task's own hermetic tests** instead (a dedicated omnibus task
  would have been redundant with what T1/T2/T3/T4/T6/T7/T8/T9 each already
  needed to prove their own fix). Every R# fixed in Waves 4-6 above has its
  own regression coverage, each independently confirmed to fail pre-fix.
- **Cross-plan landings** (LocalPlaybackEngine deadlock live smoke test,
  memory-leak audit coordination) — untouched by this execution pass, still
  open, tracked on their own plans.
- **Finding 5 — Chrome channel over-match in `ProcessSetResolver`
  (RETIRED — see "Execution status" at top; `ProcessSetResolver` no longer
  exists, superseded by main's `AudioProcessResolver` during the 2026-07-24
  merge, which does not have this bug. Kept below as history only, not a
  remaining Wave-7 task.):** `ProcessSetResolver.pids(forBundleID:)`
  groups helpers by a bare dotted-prefix match — a candidate bundle ID matches the
  target when it equals it OR `hasPrefix(bundleID + ".")`. That prefix
  over-captures Chrome *channel* siblings: `com.google.Chrome.canary`,
  `com.google.Chrome.beta`, and `com.google.Chrome.dev` all begin with
  `com.google.Chrome.`, so routing (or excluding) regular `com.google.Chrome`
  also sweeps in Chrome Canary/Beta/Dev — a wrong-device + silenced-app bug
  (their audio is captured/excluded as if they were the routed app's helpers).
  - **False confidence in the guard test:** `ProcessSetResolverTests`
    (`testChromeHelpersGroupToParentByPrefix` / `testExactBundleIDIsNotPrefixMatchedIntoAnotherApp`)
    asserts non-match against the string `com.google.ChromeCanary` (no dot).
    That correctly does NOT match `com.google.Chrome.` — but it is **not the real
    channel bundle id**. The actual id is `com.google.Chrome.canary` (dotted),
    which DOES hit the prefix and IS over-matched; the real over-matching id is
    currently untested, so the suite looks like it guards this and does not.
  - **Fix direction (when this wave runs):** replace the bare dotted-prefix with
    a known-helper-infix allowlist (e.g. require the sub-identifier to contain
    `.helper`, which real Chrome/Firefox render/GPU helpers carry) OR gate helper
    grouping behind responsible-pid confirmation instead of string prefix; and
    fix the test to use the real dotted id `com.google.Chrome.canary` (asserting
    it does NOT group under `com.google.Chrome`). Do NOT change
    `ProcessSetResolver.swift` behavior before this wave — the Wave-1 exclusion
    fixes deliberately left it untouched.

---

## Order and rationale

**1 → 2 → 3** are the reliability core and should land in that order: Wave 1
fixes the headline feature, Wave 2 makes silence impossible, Wave 3 fixes the
wrong-physical-device class. **4** rides on 1's infrastructure. **5–7** are
quality/insurance and can interleave. Each wave is a separate branch off main,
merged only after the owner's live checklist passes (standing rules: staff review
before surfacing, no merge without explicit go-ahead, one live-test session at
a time).
