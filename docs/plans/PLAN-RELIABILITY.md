# PLAN-RELIABILITY — audio always comes out where you pointed it

*Drafted 2026-07-24 from the two-round reliability audit (branch
`claude/reliability-audit-0defe7`). Audit was code-reading only — no audio was
played, no code changed. Every finding cites the file/line it was verified at.*

---

## Execution status (updated 2026-07-24)

**Waves 1–3 are code-complete, adversarially reviewed, and merged with `main`
— all on `claude/reliability-audit-0defe7`, NOT yet merged into `main`.**
Nothing here has ever been verified with real audio; every claim below is
build + hermetic-test only, per the standing no-agent-plays-audio rule. Live
verification is a separate, not-yet-done step (see "What remains").

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

1. **One fix needs to be redone.** The final adversarial pass on the merge
   found a real regression: our teardown-race guard (re-check `started &&
   !suspended` before the whole-system RTP reset re-adds engine outputs) was
   dropped in favor of main's mechanism, which turns out NOT to cover the
   **sleep** interleaving — `handleSystemWillSleep` (unlike `stop()`) never
   clears the in-flight rebind-recovery state, so a sleep landing mid-reset
   can strand a selected AirPlay device silent after wake with no
   self-recovery. An agent was assigned to restore the guarantee and
   re-instate the dropped regression test, but the session was interrupted
   before it committed — **no code change landed; this still needs to be
   done from scratch.** Low urgency (mitigated by the R11 watchdog falling
   back to local audio) but a real, confirmed gap.
2. **Live testing — not yet done, and not this session's job right now.**
   Per Alec's 2026-07-24 decision, all live audio testing is consolidated
   into the `claude/memory-leak-live-testing` session (bundle-id / PTP-port
   collision risk from running two Audiouter instances). The full live
   checklist per wave is unchanged and listed under each wave below. Two
   live-testing findings from that session, for context (not this branch's
   bugs): the ~8% pitch-up was root-caused and fixed there (a per-app tap
   format-reconciliation bug, commit `196e5b7` on their branch — this
   branch's Wave 1–3 work never touched that code path); a judder→stop→
   silence symptom on redirecting Firefox is still being chased there.
3. **R9's dedicated regression test was not re-ported** after the merge
   (the underlying fix — `refreshExcludedProcessSet` called from both
   `handlePerAppCaptureHealthChange` and `handleAppLaunched` — is confirmed
   still wired and functional; only its explicit unit test is missing).
4. **A minor completeness gap in the surgical RTP reset**, found by the
   post-merge adversarial pass: an exclusion-only tap rebuild that lands in
   the narrow window between the old tap's teardown and the new tap's
   listener arm can silently re-anchor onto a different default device's
   clock without triggering a reset. Self-heals on the next device/rate
   event; transient silence window only. Not yet fixed — low priority.
5. **Waves 4–7 have not been started** (R5, R8, R6's resume affordance, R3,
   R16, and Wave 7's regression-armor items). Out of scope for this
   execution pass per the original instruction to run only Waves 1–3.

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

The goal: make Audiouter one of the most reliable audio-switching apps that
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
| R16 | P2 | Nothing tells the user "Audiouter owns the audio" — macOS Sound settings keeps showing the physical device | Process-tap architecture; only a virtual output device changes the Sound panel |

Verified healthy along the way: native backend is the default (mock is
opt-in, `OwnToneBackend.swift:806`); the alert-device selector
(`DefaultSystemOutputDevice`) is fully purged; the LocalPlaybackEngine
lock-inversion fix is present in this tree (live smoke test still owed).

---

## The program

Ordered by user pain, not by code area. Each wave ends with a silent
verification I do (build + hermetic tests) and a short **live checklist Alec
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

*Live checklist (Alec, with BT headphones):* passthrough with BT — all normal;
route an app to Current Device while wearing BT — audio in the headphones, not
the room; start a stream, then plug/unplug headphones — speakers keep playing.

### Wave 4 — Per-app route durability *(fixes R5, R8; revisits R6)*

- **Grace period instead of silent reset.** A route whose target goes
  unavailable is **kept**, badged "speaker offline", and auto-resumes when the
  device returns. It is only cleared by the user. (Replaces the
  reset-on-unavailable in `PopoverController.update`; the store's silent
  fallback remains only for devices gone > a long horizon, e.g. days.)
- **Connection dot for redirect targets.** A device receiving a per-app stream
  shows the same connected/connecting state a Selected device does — driven
  from the stream-binding lifecycle instead of the output-set lifecycle.
- **R6 stays as decided** (quit clears a device route — deliberate,
  2026-07-22), but the relaunch path gets a lightweight "Resume route to
  *Kitchen*?" affordance on the app's row instead of silent nothing.

### Wave 5 — Same-speaker multi-app quality *(R3 — decide after Wave 1)*

Two options, decided once Wave 1's converter infrastructure is in:
**(a)** proper shared-clock mixing (resample members onto the capture clock of
the newest contributor rather than the wall-clock grid), or **(b)** keep the
limitation and say so in the UI — the second app routed to an already-routed
speaker gets a one-line "may reduce quality" note. (a) is the real fix; (b) is
the honest stopgap if (a) slips.

### Wave 6 — "We are the output" visibility *(R16 + Alec's Sound-panel idea)*

- **Now (cheap, recommended):** the popover's System row reads as an explicit
  statement — **"Audio Out → Kitchen + Move 2"** / "→ This Mac" — and the
  menu-bar icon carries a streaming state, so one glance answers "who owns my
  audio right now". Group editor also gains the R4 fix here: the same
  local-mix block + explanation the popover already shows (until the
  synced-local engine work lands and lifts the restriction for real).
- **Decision item (the literal ask):** shipping a **virtual output device**
  named "Audiouter" that appears in macOS Sound settings. Upside: the exact
  visibility Alec described, plus the industrial-strength capture path
  (SoundSource/Loopback-class); downside: an AudioServerPlugIn driver to
  build, sign, install, and keep alive — a genuinely large lift the SPEC
  deliberately avoided. Recommendation: do the labeling now, schedule a
  half-day spike on the driver before committing either way.

### Wave 7 — Regression armor

- **Selector guard in CI:** a test that greps the tree for
  `DefaultSystemOutputDevice` and fails if it ever returns (this bug has
  drifted back in twice).
- **Route-truth test suite:** for every R# above, a hermetic test that models
  the triggering sequence against fake taps/process lists and asserts the
  invariant — so no future refactor can silently reintroduce one.
- **Cross-plan landings folded in:** LocalPlaybackEngine deadlock fix live
  smoke test; CPU-storm T8/T10 (arrives inside Wave 2); memory-leak audit
  waves proceed on their own plan (shared tap-lifecycle code — coordinate
  merges, single live session per the single-instance PTP rule).
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
merged only after Alec's live checklist passes (standing rules: staff review
before surfacing, no merge without explicit go-ahead, one live-test session at
a time).
