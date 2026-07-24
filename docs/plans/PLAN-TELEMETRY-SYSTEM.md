# PLAN — Structured Runtime Telemetry / Decision Log

Status: DRAFT (not executed). Planner-authored; author in a worktree, land as a merge
(`main` is merge-only — AGENTS.md). Target: `main` (worktree `great-keller-379901`,
tip `0c8f77d`, identical to `main`).

## A. End-state overview

Audiouter gains an **always-on, structured, bounded, agent-readable decision log**: a
Foundation-only `Telemetry` facility in `AudiouterCore` that appends one JSON object per
line to a stable file under the user's `~/Library/` (no Full Disk Access needed to read
it — the app is not sandboxed, confirmed: `scripts/Audiouter.entitlements` has no
`com.apple.security.app-sandbox` key). The four subsystems that have actually produced
"only-reproduces-live, no evidence to read afterward" bugs are instrumented at their real
decision points: **permission/TCC gate checks and reported-vs-actual divergence**
(`SystemAudioCaptureTCC.isGranted()` sites + `SetupModel`'s silent-status reconciliation),
**whole-system capture state transitions** (`NativeCaptureCoordinator.transition(to:)`),
**per-app capture transitions + output sample-rate rebuilds**
(`PerAppCaptureCoordinator`), and **AirPlay bind/rebind/session-reset + device-selection
decisions** (`NativeBackend` `setOutputSet`/`desiredOn`/`rebindRecoveryGen`). The writer is
non-blocking (hands off to its own serial queue, never calls back into callers, never
touches the real-time IOProc render path) and self-neutralizes under `swift test` via the
existing `HeadlessRuntime.isActive` seam so the always-on default cannot pollute or race
the suite. When Alec next hits a live bug, an assisting agent `Read`/`grep`s one file and
reconstructs the causal chain instead of reasoning blind from static source.

This is an MVP: instrument the four proven-hot subsystems only, on a small reusable helper.
It is **not** a metrics/analytics system, not a live dashboard, and requires nothing of
Alec at the time a bug occurs.

---

## B. OPEN QUESTIONS — needs confirmation

These are genuine design calls. Each is framed plainly; recommended option first with its
downside stated too. None should be decided silently.

**Q1 — Always-on, or opt-in?**
- **Always-on (recommended).** Upside: you never have to remember anything — whatever
  session breaks, the evidence was already being captured. Downside: the app always does a
  little background disk-writing, and a (small, capped) log file always exists on disk.
- Opt-in (a setting or env var). Upside: zero footprint until switched on. Downside:
  defeats the entire purpose — you'd have to predict which session goes wrong and arm it
  beforehand, which is exactly what you can't do. This is the whole reason for the ask.

**Q2 — Where does the file live?**
- **`~/Library/Logs/Audiouter/telemetry.jsonl` (recommended).** Upside: the standard macOS
  place for app logs, easy to find in Finder (Go ▸ Library ▸ Logs), and an agent reads it
  directly with no special permission. Downside: it's a different folder from the app's
  other data (`~/Library/Application Support/Audiouter/`), so there are two app folders.
- Alongside existing data at `~/Library/Application Support/Audiouter/` (reuses the proven
  `GroupStore` base-dir pattern, `GroupStore.swift:73`). Upside: everything in one folder.
  Downside: less discoverable as "logs"; mixes debug logs with real user data.
  Either is equally agent-readable (neither needs Full Disk Access).

**Q3 — How much history to keep (size bound)?**
- **~10 MB total, rotating 2 files, keep newest (recommended).** Upside: bounded disk use,
  always retains the most recent activity (where a just-hit bug lives). Downside: a bug
  reported days later could have scrolled off after heavy use in between.
- Larger cap (e.g. 50 MB / more days). Upside: longer memory. Downside: more disk, slower
  for an agent to grep. (The number is trivial to change later.)

**Q4 — Touch the real-time audio path in v1, or only the decisions around it?**
- **Only the surrounding decision points, NOT the per-buffer render path (recommended).**
  Upside: zero risk to audio quality — the real-time IOProc render path
  (`NativeCaptureCoordinator.swift:376-403`, "Allocation beyond the converter's own scratch
  is avoided on this path") stays untouched; still captures every routing/permission/rebind
  decision, which is where the bugs you've hit actually live. Downside: no buffer-by-buffer
  detail (e.g. "audio went to zeros at 18:03:04.512"); only "capture rebuilt/stopped,"
  inferred around it.
- Also add a lightweight counter on the render path (reuse the existing `AudioDiag.tick()`
   1st-and-every-100th pattern, `AudioDiag.swift:32`). Upside: can see the exact moment
  audio silently went to zeros. Downside: any code on that path risks glitches/dropouts,
  needs extra care/testing, higher risk for modest extra detail.

**Q5 — Is unified logging (os_log / Console) enough, or do we need our own file?**
- **Our own JSON-lines file, and leave existing os_log where it is (recommended).** Upside:
  an agent reads a plain file directly, days later, with no special access — the whole
  point. During THIS session an agent's `log show --last 5m` had already rolled past the
  moment the bug happened, and it separately couldn't get the Full Disk Access it needed;
  os_log `.debug`/`.info` are not reliably persisted to disk and roll off fast. Downside: a
  little duplication with the existing Console logging (`DACPServer.swift:50`,
  `AirPlayEngine`), one more file to maintain.
- Rely on os_log/Console only. Upside: nothing new to build, Apple-standard channel.
  Downside: demonstrated to fail this session — detail levels aren't durably kept and
  after-the-fact reads often need access an agent doesn't have.

**Q6 — (minor) Log device names and app bundle IDs in cleartext?**
- **Yes (recommended).** The file is local-only (never uploaded); names like
  "Kitchen HomePod" / "com.google.Chrome" are exactly what makes a failure legible. Upside:
  immediately diagnosable. Downside: if you ever hand the raw file to someone it reveals
  your device/app names (nothing leaves the Mac unless you send it).
- Hash/abbreviate identifiers. Upside: less identifying if shared. Downside: much harder to
  read; you'd have to de-reference to make sense of it.

**Q7 — (minor) Retire the existing env-gated `AudioDiag` logger, or leave it?**
- **Leave `AudioDiag` in place; new telemetry covers the same hot spots always-on, and the
  couple of existing `AudioDiag.log` calls at the targeted subsystems (e.g.
  `PerAppCaptureCoordinator.swift:959`) also emit structured telemetry (recommended).**
  Upside: no churn/risk to working dev tooling; both available. Downside: two logging
  helpers coexist until a later cleanup.
- Reimplement `AudioDiag` on top of the new telemetry now. Upside: one logging path.
  Downside: extra refactor risk on working code for little near-term benefit.

---

## C. Task list

Proposed shared API contract (executor may refine names; fixing it here de-risks the
parallel fan-out). Foundation-only, in `AudiouterCore`:

```
public enum Telemetry {
    // Categories map 1:1 to the instrumented subsystems.
    public enum Category: String { case permission, captureWS, capturePA, airplay, lifecycle }

    /// Non-blocking. Formats cheaply on the caller thread, hands the line to an
    /// internal serial writer queue. MUST NOT call back into callers or block.
    /// MUST NOT be called from the IOProc/render path (see Q4).
    public static func log(_ cat: Category, _ event: StaticString, _ fields: [String: String] = [:])

    public static var isEnabled: Bool            // false under HeadlessRuntime.isActive

    // Test seams (mirror GroupStore.init(directory:) + a capture sink):
    public static func _resetForTesting(directory: URL?)
    public static func _installTestSink(_ sink: (@Sendable (String) -> Void)?)
}
```

Line schema (one JSON object per line):
`{"ts":"<ISO8601 ms, UTC>","sid":"<per-launch uuid>","cat":"...","evt":"...", ...fields}`

Concrete examples the executor should be able to produce:
```
{"ts":"2026-07-24T18:03:11.482Z","sid":"A1B2","cat":"permission","evt":"gate_check","site":"NativeCaptureCoordinator","granted":"false","preflight":"undetermined"}
{"ts":"...","cat":"permission","evt":"reported_vs_actual","reported":"granted","silent":"denied","diverged":"true"}
{"ts":"...","cat":"captureWS","evt":"transition","from":"creatingTap","to":"capturing","format":"44100/2"}
{"ts":"...","cat":"capturePA","evt":"rate_rebuild","device":"Kitchen","oldRate":"48000","newRate":"44100"}
{"ts":"...","cat":"airplay","evt":"rebind","device":"Kitchen","gen":"3","attempt":"2","trigger":"recapture","outcome":"scheduled"}
{"ts":"...","cat":"airplay","evt":"set_output_set","added":"[Kitchen]","removed":"[]","desiredOn":"[Kitchen,Office]"}
```

---

### T1 — Telemetry core (the logger)
- **files:** NEW `AudiouterCore/Sources/AudiouterCore/Telemetry.swift`
- **what:** Implement the always-on structured JSON-lines writer per the API above.
  Generalize the proven `AudioDiag` shape (`AudioDiag.swift`: static facade, off-thread
  serial `DispatchQueue`, `isEnabled` fast-path) but always-on, structured, size-bounded
  with rotation, and **neutralized under `HeadlessRuntime.isActive`** (`HeadlessRuntime.swift:35`
  — detects XCTest) so tests never write/rotate real files or race under `--parallel`.
  Compute the default production path lazily like `GroupStore.swift:73`; inject directory +
  clock for tests. Emit a one-line session banner (uuid, app version/build, macOS version)
  on first write so an agent can find session boundaries. Fail safe on disk-full/write
  error (drop, never crash).
- **kind:** new-code
- **depends_on:** —
- **recommended_model:** sonnet 5 — foundational shared utility; the concurrency pattern
  is already proven in-repo (`AudioDiag`), so no opus, but it is always-on in every prod
  session and everything depends on it being correct.
- **recommended_effort:** high — must get non-blocking hand-off, rotation/size-bound, and
  test-neutralization right once; whole system depends on it.
- **verify:** `swift test --filter TelemetryTests` (T6) green; manual: run a non-test binary,
  confirm a bounded JSON-lines file appears at the chosen path; confirm `swift test` creates
  no file at the production path.

### T2 — Whole-system capture instrumentation
- **files:** `AudiouterCore/Sources/AudiouterCore/NativeCaptureCoordinator.swift` (single
  choke point `transition(to:)` at line **563**; also `handleDeviceChange()`,
  `updateRouting(...)` exclusion changes, `pendingDeviceChange` coalescing ~line **118**,
  and its own gate check at line **841**); tests in `NativeCaptureCoordinatorTests.swift`.
- **what:** Emit `captureWS` events at every state transition (idle→creatingTap→capturing→
  stopping→failed, carrying `TapFormat`), on device-change rebuild triggers, exclusion-list
  changes, coalesced pending rebuilds, and the `isGranted()` gate result. All are on the
  coordinator's serial `queue` (non-RT); do NOT touch the IOProc `deliver` path (line 376+).
- **kind:** new-code (additive instrumentation)
- **depends_on:** T1
- **recommended_model:** sonnet 5 — additive logs into a 1301-line concurrency-sensitive
  state machine; must place calls without perturbing `queue` invariants. Reliable floor,
  not haiku (risk of misplacement/over-logging on the RT-adjacent path).
- **recommended_effort:** medium — one clear choke point plus a few sites; judgment is
  which fields make a dropout legible.
- **verify:** `swift test --filter NativeCaptureCoordinatorTests`; add a test using
  `Telemetry._installTestSink` asserting a start→capturing sequence emits the expected
  `captureWS transition` lines.

### T3 — Per-app capture instrumentation
- **files:** `AudiouterCore/Sources/AudiouterCore/PerAppCaptureCoordinator.swift` (State
  transitions ~line **79**; nominal-sample-rate listener → rebuild at line **955-972**,
  upgrading the existing `AudioDiag.log` at line **959**; pending-coalesce ~line **371**;
  gate check at line **745**); tests in `PerAppCaptureCoordinatorTests.swift`.
- **what:** Emit `capturePA` events per per-app slot: state transitions, the
  output-device sample-rate change that triggers a full tap+aggregate rebuild (the exact
  class of event behind the synced-local dropout — see Risk R3), pending coalescing, and the
  gate result. Per-slot serial queue / listener callback (non-RT). Do not instrument the
  per-buffer path.
- **kind:** new-code (additive instrumentation)
- **depends_on:** T1
- **recommended_model:** sonnet 5 — same class as T2; multi-slot lifecycle in a 1001-line
  file, additive but must respect per-slot queue confinement.
- **recommended_effort:** medium — mirrors T2; the rate-rebuild event is the high-value one.
- **verify:** `swift test --filter PerAppCaptureCoordinatorTests`; sink-based test asserting
  a simulated rate change emits a `capturePA rate_rebuild` line with old/new rate.

### T4 — AirPlay bind/rebind/session-reset + device-selection instrumentation
- **files:** `AudiouterCore/Sources/AudiouterCore/NativeBackend.swift` (`setOutputSet` at
  line **1096** — added/removed/`desiredOn` diff; converge outcomes; recapture→session reset
  `resetAirPlaySessionForRoutedApp` ~line **1464**; `rebindRecoveryGen` generation bump +
  attempt number + backoff + success/give-up, lines **450-456, 1475-1533**;
  `handleSystemDidWake()` re-converge ~line **235**); tests in `NativeBackendTests.swift`.
- **what:** Emit `airplay` events for device-selection changes and the full rebind-recovery
  decision trail: generation token bumps (single-flight bookkeeping), per-attempt records
  with `trigger`/`outcome`, give-up at the attempt ceiling, and wake re-converge. This is
  the decision-densest area and the exact spot a recent adversarial review found a race, so
  the causal fields (device, gen, attempt, trigger, outcome) must be accurate. All on
  `stateQueue` (non-RT); purely additive — must NOT add awaits or synchronous writes inside
  critical sections or reorder `stateQueue` work.
- **kind:** new-code (additive instrumentation)
- **depends_on:** T1
- **recommended_model:** sonnet 5 — largest file (3501 lines) and subtlest semantics
  (generation/single-flight/backoff), but the change is purely additive logging with no
  behavior change, so high-effort sonnet, not opus.
- **recommended_effort:** high — must capture the rebind causal chain correctly without
  disturbing the racy `stateQueue` ordering.
- **verify:** `swift test --filter NativeBackendTests`; sink-based test asserting a forced
  session reset emits `airplay rebind` lines with monotonic `gen` and incrementing `attempt`.

### T5 — Permission/TCC divergence instrumentation (the motivating bug)
- **files:** `AudiouterCore/Sources/AudiouterCore/SetupModel.swift` (reported-vs-actual
  reconciliation at lines **380** and **546**, where `audioProbe.currentStatusSilently()`
  is compared to stored `audioStatus`); `AudiouterCore/Sources/AudiouterCore/AudioCapturePermissionProbe.swift`
  (probe outcome in `probe()` ~line **122** and `currentStatusSilently()` ~line **215**);
  `AudiouterCore/Sources/AudiouterApp/AppDelegate.swift` (onboarding gate at line **399**);
  tests in `SetupModelTests.swift`.
- **what:** Emit `permission` events capturing the exact "UI says granted while the
  authoritative gate says not" discrepancy: log both the reported status and the silent
  `currentStatusSilently()` result at reconciliation, flag `diverged:true` when they differ;
  log the probe's final verdict; log the AppDelegate gate decision. Together with the
  coordinators' own `isGranted()` gate logs (T2/T3) this lets an agent see
  "setup=granted, capture-gate=not-granted" in one file — the evidence that was missing.
  All non-RT (async setup / main-thread UI).
- **kind:** new-code (additive instrumentation) + backend (permission logic)
- **depends_on:** T1
- **recommended_model:** sonnet 5 — additive across 3 files, but the value is the judgment
  about WHICH values to capture to make the divergence self-evident (the whole point of the
  effort).
- **recommended_effort:** medium — small edits, but semantically the most important; get the
  divergence fields right.
- **verify:** `swift test --filter SetupModelTests`; sink-based test asserting a probe/stored
  mismatch emits a `permission reported_vs_actual` line with `diverged:true`. Manual (owed,
  Developer-ID build): reproduce the setup flow and confirm the divergence line appears.

### T6 — Telemetry core tests
- **files:** NEW `AudiouterCore/Tests/AudiouterCoreTests/TelemetryTests.swift` (subclass
  `IsolatedTestCase`, use `scratchDir`).
- **what:** Assert: valid JSON per line + required fields (ts/sid/cat/evt); size-bound +
  rotation keeps newest and never exceeds the cap; `HeadlessRuntime`-neutralization writes
  no file at the production path under XCTest; directory injection isolates writes;
  concurrent `log` from multiple threads never crashes/interleaves a partial line;
  disk-error path fails safe. Must not touch shared globals (Guard 3) — inject `scratchDir`.
- **kind:** test
- **depends_on:** T1
- **recommended_model:** sonnet 5 — deterministic tests over a concurrent async writer +
  rotation are easy to make flaky; needs care to flush and to stay `--parallel`-safe.
- **recommended_effort:** medium — the rotation/flush/neutralization assertions carry real
  correctness weight.
- **verify:** `swift test --filter TelemetryTests` green; re-run under `swift test --parallel`
  to confirm no cross-suite file race.

### T7 — Docs: AGENTS.md registry + reader note
- **files:** `AudiouterCore/AGENTS.md` (add one Map row for `Telemetry`; add one Rule
  invariant); OPTIONAL NEW `dev/notes/telemetry-how-to-read.md` (one short page: file path,
  line schema, example greps for a future debugging agent).
- **what:** Register the new `Telemetry` type in the Map and state the load-bearing
  invariants as a Rule: always-on + bounded; non-blocking, never calls back into callers;
  **never called from the IOProc/render path**; auto-neutralized under tests. Keep within the
  AGENTS.md HARD-RULE budget (≤300 words/folder, intent/constraints only, no implementation).
  Guard 2 verifies the named `Telemetry` symbol exists — so this must land in the same merge
  as T1.
- **kind:** docs
- **depends_on:** T1 (symbol must exist in the same commit for Guard 2)
- **recommended_model:** haiku 4.5 — a one-row Map add + one Rule; symbol name is known,
  format is strict but simple.
- **recommended_effort:** low — mechanical, small, but must be accurate for Guard 2.
- **verify:** `.githooks/pre-commit` Guard 2 passes (no unknown symbol warning for
  `Telemetry`); word-count within budget.

---

## D. Parallelization

**Hot files (contended):** none across the fan-out — the decomposition is by file on
purpose. Each of T2/T3/T4/T5 owns a distinct source file (and its own test file); T6 is a
new file; T7 is `AGENTS.md`. The only shared dependency is the T1 API surface.

- **Wave 1 (barrier):** **T1** alone. Everything calls its API; its shape must be fixed
  before the fan-out. Run/review this first.
- **Wave 2 (fully concurrent — no shared files):** **T2, T3, T4, T5, T6, T7** in parallel.
  - T2 ↔ NativeCaptureCoordinator.swift, T3 ↔ PerAppCaptureCoordinator.swift,
    T4 ↔ NativeBackend.swift, T5 ↔ SetupModel/AudioCapturePermissionProbe/AppDelegate,
    T6 ↔ TelemetryTests.swift (new), T7 ↔ AudiouterCore/AGENTS.md. Disjoint sets → safe to
    run at once.
- **Wave 3 (barrier):** combined build + full `swift test --parallel` on the merged tree
  (Guard 4 gate). Not a coding task — the integration check after the parallel batch
  (memory: always build+test the COMBINED tree after a parallel batch).

**Critical path:** T1 (high) → T4 (high, longest/subtlest instrumentation) → Wave-3 combined
`swift test --parallel`. All other Wave-2 tasks are shorter and finish under T4.

---

## E. recommended_execution

**`agents`.** Rationale: 7 tasks with a single real barrier (T1) then a clean 6-wide fan-out
with **zero hot-file contention**, but the work is judgment-heavy exactly where it matters —
T1's always-on concurrency, T4's subtle rebind/generation fields, and T5's divergence
semantics — and the core deliverable is *which events/fields to record*, which Alec will
want to see and redirect ("also log X", "don't log device names"). Watched agents keep those
choices visible and steerable mid-flight; the disjoint file sets mean agents run truly
concurrently without needing a workflow's enforced barriers. It is under the 8+-task,
uniform-mechanical bar that would earn `workflow`'s overhead.

- Tie-breaker applied: on a close call, prefer `agents` — visibility here is the point.
- The one argument for `workflow` is per-task effort control (T1/T4 high vs T7 low); that is
  real but modest and is handled by assigning the right agent per task, so it does not
  outweigh visibility. If Alec would rather batch the three mechanical tasks (T2, T3, T7)
  deterministically while watching T1/T4/T5, run it as **`hybrid`** — those three in a small
  workflow, T1/T4/T5/T6 as watched agents. Default remains `agents`.

Sequence: run/review **T1** as a watched agent first; on approval of its API + schema, fan
out **T2–T7** as concurrent agents; finish with the Wave-3 combined `swift test --parallel`.

---

## F. Test + docs/registry impact

- **New tests:** `TelemetryTests` (T6 — format, rotation/size-bound, HeadlessRuntime
  neutralization, directory isolation, concurrent-write safety, disk-error fail-safe).
- **Extended suites:** `NativeCaptureCoordinatorTests`, `PerAppCaptureCoordinatorTests`,
  `NativeBackendTests`, `SetupModelTests` each gain a sink-based emission assertion via
  `Telemetry._installTestSink` (T2–T5). All subclass/behave per `IsolatedTestCase`.
- **Suite health:** the always-on default MUST self-neutralize under `HeadlessRuntime.isActive`
  (T1) or the existing suite would start writing/rotating real files and racing under
  `swift test --parallel`. This is the single most important test-hygiene requirement and is
  explicitly verified by T6. Guard 4 runs the full `--parallel` suite at commit.
- **Docs/registry:** `AudiouterCore/AGENTS.md` Map gains one `Telemetry` row + one Rule (T7);
  Guard 2 verifies the symbol, so docs and code ride the same merge. Optional
  `dev/notes/telemetry-how-to-read.md` for future debugging agents. This plan lives at
  `docs/plans/PLAN-TELEMETRY-SYSTEM.md`.
- **Not touched:** `AirPlayEngine` (separate licensing-boundary package — do NOT add
  `AudiouterCore.Telemetry` there; its own `os_log` stays); `ConnectionDiagnostics`
  (OwnTone-only post-hoc classifier, superseded backend); `AudioDiag` (left as-is per Q7);
  `os.Logger` in `DACPServer` (coexists).

---

## G. Open risks / confirm during execution

- **R1 — Always-on writer is prod-critical.** A bug in T1 (blocking write, unbounded growth,
  disk-full crash, partial-line interleave) ships to every session. Acceptance: non-blocking
  hand-off to an internal serial queue, never calls back into callers, hard byte-cap +
  rotation, fail-safe on write error. Verified by T6; review T1 closely.
- **R2 — Test-suite pollution / flake.** If neutralization is imperfect the always-on default
  races the `--parallel` suite. Mitigation: `HeadlessRuntime.isActive` gate in T1 + explicit
  T6 assertion that no production-path file is created under XCTest.
- **R3 — Scope discipline: telemetry reveals, it does not fix.** The synced-local dropout
  root cause (per memory: `NativeCaptureCoordinator` lacks the nominal-sample-rate listener
  that `PerAppCaptureCoordinator` has at lines 955-972) will become VISIBLE once T3 logs the
  per-app rate-rebuild and T2 logs the absence of a whole-system one — but this plan does NOT
  add that listener or fix the dropout. Executors must not scope-creep into the routing fix.
- **R4 — Don't perturb the racy paths.** T4 edits the exact `stateQueue` rebind area a recent
  review found a race in; T2/T3 edit RT-adjacent coordinators. Instrumentation must be purely
  additive — no new awaits, no synchronous writes, no reordering inside critical sections, and
  nothing on the IOProc render path (Q4 recommended: stay off it in v1).
- **R5 — PII in a local file (Q6).** Device names / bundle IDs logged in cleartext are local
  only; confirm Alec is fine with that before enabling (recommended yes).
- **R6 — Path/retention are Alec's calls (Q1–Q3).** T1 hard-codes defaults; leave the path,
  size-bound, and always-on flag as single named constants so the answers to Q1–Q3 are a
  one-line change, not a redesign.
- **R7 — Engine-side events are out of reach by design.** If a future bug needs
  AirPlayEngine-internal evidence, that stays in the engine's own `os_log` (package/licensing
  boundary); a bridge is explicitly out of scope for this MVP.
