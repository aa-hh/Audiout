# Phase 3 Polish — Crash & Hang Surface Audit (A3)

Audit of the concurrency, lifecycle, and crash/hang surface ahead of Audiout's
paid public release. Read-only pass over `AudioutCore/` and `AirPlayEngine/`;
every claim below was re-verified against current source (file:line), not docs or
memory. No live audio/AirPlay session was started and the app was not launched —
items needing a running/signed build are tagged `[confirm-in-G1]` /
`[confirm-in-G2]`.

## Method

- Swept `git grep "STABILITY("`: **28 inline `STABILITY(id)` markers in shipping
  Swift source** (excluding tests), by id: C6×6, C7×2, C8×3, D4×11, D5×2, D6×4.
  Also present but not code guards: 2 `MARK: - STABILITY(C6)` lines in test files,
  and 3 doc-reference lines in AGENTS.md files (+ the audit note itself). For each
  of the 28 I read the surrounding code and compared it to the hazard the
  `dev/notes/stability-audit-2026-07-18.md` ledger describes.
- Read the prior audit ledger (Sections 1/2/3) and reconciled each deferred item.
- Read `dev/notes/objc-exception-shim-handoff.md` and traced whether the shim it
  describes is actually wired into the code it was built to protect.
- `git grep` TODO/FIXME/HACK/XXX/workaround/known-issue across `Sources/`
  (app + engine Swift + shims; vendored upstream C skimmed only where our shims
  call it).
- `git grep` for `fatalError`/`precondition`/`try!`/`as!`/`assertionFailure` in
  UI-reachable app source.
- Fresh-eyes reasoning (no live runs) over lifecycle edges: quit-during-connect,
  sleep/wake, default-output change mid-stream, buffer-size change mid-stream,
  device removal during connect, two-instance launch, force-quit, macOS version
  drift vs the deployment floor.
- Tests were **not** run for these findings (all are static/code-read; the two
  known load-flaky tests are irrelevant to them). Shim non-adoption was proven by
  `git grep` for call sites, not by a test.

## STABILITY marker verdicts

All 28 markers are **still-correctly-guarded**: the code at each site still
performs (and still needs) the guard the ledger describes; none has drifted away
from its hazard, none has been silently fixed leaving a stale marker, and none
guards a hazard that is now gone. Line numbers in the ledger predate the markers
and have moved, but every marker travelled with its code. These are
"fix-when-you-touch-this" markers, so "still-correctly-guarded" means the hazard
is still live-by-design, not that it has been resolved.

| id | file:line | hazard in plain words | verdict |
|---|---|---|---|
| D4 | AppRoutingController.swift:40 | Saves per-app routes to disk synchronously on the UI thread during a gesture — a slow disk can stutter the click. | still-correctly-guarded |
| D6 | CaptureCoordinator.swift:311 | A background task reads the capture-process handle off its own queue, racing a queue-confined write (OwnTone path). | still-correctly-guarded |
| D6 | CaptureProcess.swift:120 | A log line-buffer is appended (read handler) and flushed (termination handler) from two different threads with no shared lock — at most a dropped trailing log line. | still-correctly-guarded |
| D5 | ConnectionDiagnostics.swift:276 | Bonjour browse resumes its awaiter on `.failed` but **not** `.cancelled`, so a cancelled browse can hang the diagnose task forever (OwnTone path only). | still-correctly-guarded |
| D6 | DefaultOutputObserver.swift:11 | The change-callback is a plain settable property with no synchronization — a torn read if set from another thread. | still-correctly-guarded |
| D6 | DefaultOutputObserver.swift:16 | The current-device-name property claims any-thread readability that only holds if every write goes through the queue (not type-enforced). | still-correctly-guarded |
| D4 | GroupController.swift:142 | Saves routing state to disk synchronously on the UI thread. | still-correctly-guarded |
| C8 | GroupController.swift:155 | Looks up one device by re-entering the backend's state-queue `.sync`, and is called per-row inside repaint loops. | still-correctly-guarded |
| C8 | NativeBackend.swift:618 | The `devices` getter blocks the main thread on the state queue (fine today, a freeze the day any slow work lands on that queue). | still-correctly-guarded |
| C8 | NativeBackend.swift:996 | `setOutputSet` blocks the main thread on the state queue on every routing change. | still-correctly-guarded |
| C7 | NativeBackend.swift:2361 | Any ordinary Bonjour re-advert clears the per-device failure gate with no backoff. | still-correctly-guarded |
| C7 | NativeBackend.swift:2398 | …and unconditionally re-kicks the connect loop, so a flapping receiver drives an unbounded reconnect storm. | still-correctly-guarded |
| C6 | NativeCaptureCoordinator.swift:99 | Coalescing flag so a rebuild trigger arriving mid-rebuild isn't dropped (documents the SHIPPED fix). | still-correctly-guarded |
| C6 | NativeCaptureCoordinator.swift:413 | Sets that flag when a device/exclusion change lands while already rebuilding. | still-correctly-guarded |
| C6 | NativeCaptureCoordinator.swift:460 | Replays one coalesced rebuild once capture resumes. | still-correctly-guarded |
| D5 | OwnToneBackend.swift:570 | Zombie-recovery re-selects the set captured at call time without re-reading current intent — can re-select a device the user just deselected (OwnTone path). | still-correctly-guarded |
| C6 | PerAppCaptureCoordinator.swift:113 | Per-slot coalescing flag (per-app port of the same fix). | still-correctly-guarded |
| C6 | PerAppCaptureCoordinator.swift:361 | Marks a device-change notification pending if it lands mid-rebuild. | still-correctly-guarded |
| C6 | PerAppCaptureCoordinator.swift:410 | Replays one coalesced rebuild once the slot resumes capturing. | still-correctly-guarded |
| D4 | GroupRowView.swift:273 | Slider drag-flag clears only if the last change callback coincides with mouse-up; an Esc/cancelled drag leaves it stuck AND leaves the group drag-ratio cache stale. | still-correctly-guarded |
| D4 | GroupRowView.swift:341 | Each row installs its own app-wide mouse monitor, churned on every rebuild. | still-correctly-guarded |
| D4 | MainOutRowView.swift:360 | Same stuck-drag-flag heuristic as the other rows. | still-correctly-guarded |
| D4 | PopoverController.swift:429 | A full rebuild can run mid-slider-drag and replace the row the user has the mouse down on. | still-correctly-guarded |
| D4 | GeneralSettingsViewController.swift:74 | Launch-at-login toggle round-trips launchd XPC synchronously on the main thread from the button handler. | still-correctly-guarded |
| D4 | AppRowView.swift:562 | Stuck-drag-flag heuristic (row ignores model updates until a coincident mouse-up). | still-correctly-guarded |
| D4 | AppRowView.swift:675 | Per-row app-wide mouse-monitor churn on rebuild. | still-correctly-guarded |
| D4 | DeviceRowView.swift:718 | Stuck-drag-flag heuristic. | still-correctly-guarded |
| D4 | DeviceRowView.swift:984 | Per-row app-wide mouse-monitor churn on rebuild. | still-correctly-guarded |

## Deferred items status

From `dev/notes/stability-audit-2026-07-18.md`:

- **Section 1 (marked, fix-when-touched):** C6a, C7, C8, D4, D5, D6 — all still
  open, all markers intact and correctly placed (see the table above). C6 itself
  is recorded as RESOLVED in Section 3; its surviving markers deliberately
  document the shipped coalescing fix, which matches the code.
- **Section 2, B7** — RESOLVED (per-app volume handler avoids the per-tick
  rebuild). Verified: the note is accurate; no marker, none needed.
- **Section 3 (claimed resolved by that merge):** C6, C5, B1, B2, C4, A2, D1, D2,
  D3, B8, C1, B4, B5, C2, C3, B6a, B6b, B9, and **A1 (partial)**. Spot-checks
  confirm the code matches for the ones I traced (C6 coalescing, C1 bounded quit,
  B6b sleep/wake seam). **A1 is the important one: the merge shipped the ObjC
  exception *shim infrastructure* but the note itself calls adoption "still
  pending" — and it never landed. See Critical #1.** Several Section-3 items
  (B6a/B6b/B9/C3) still carry "live proof pending" caveats → G1/G2.

## Confirm status with the owner (external tracker — not investigated)

Per the owner's decision, these ledger IDs are tracked in an external scheduling
system we are not chasing. Listed verbatim for status confirmation. NOTE: the
audit note's own Section 3 marks several of these as already RESOLVED (E1/Phase 3
work) — worth reconciling the external tracker against that:

- **B3** — (Section 2 backlog; no resolved entry — appears still open)
- **B4** — Section 3 claims RESOLVED (E1: `EngineThread.enqueue` no longer drops work)
- **B5** — Section 3 claims RESOLVED (E1: completion-slot reuse closed three ways)
- **B6** — Section 3 claims RESOLVED as B6a + B6b (Phase 3: per-tap pts offset; sleep/wake) — both with "live proof pending"
- **B9** — Section 3 claims RESOLVED (Phase 3: discovery survives NWBrowser `.failed`) — "live mDNSResponder-kill proof pending"
- **C1** — Section 3 claims RESOLVED (bounded quit) — with a named residual (stop() still runs stopAll/flush/localPlayback.stop on the caller thread)
- **C2** — Section 3 claims RESOLVED (E1: engine survives stop→start)
- **C3** — Section 3 claims RESOLVED (E1: deadlined thread join) — "wedged-thread rapid stop→start still needs a gated live test"

## New findings ordered by severity

### CRITICAL

**C1. The crash-fixing ObjC exception shim was built, tested, and merged — but is
never actually called, so the crash class it exists to stop can still abort the
process.**
- Plain-language: On 2026-07-18 the app crashed four times in four minutes when
  playing an app to the Mac's own speakers ("Current Device" routing) while the
  output device changed underneath it. A safety net was built to catch exactly
  that crash. That safety net is installed in the codebase but nothing is wired
  through it — the risky audio calls still run bare. A user plugging in
  headphones / AirPods / HDMI, or switching output devices, while a
  Current-Device app is playing can still hard-crash the whole app.
- Evidence:
  - Shim exists and is unit-tested: `AudioutCore/Sources/AudioutCore/ObjCExceptionCatching.swift:26` (`catchingObjCException`), target wired in `AudioutCore/Package.swift:77`.
  - **Zero production call sites** — `git grep catchingObjCException` returns only its own definition, its tests, and a Package.swift comment.
  - The exact sites the handoff (`dev/notes/objc-exception-shim-handoff.md` §4) says to wrap are still bare AVFoundation calls guarded only by an `isRunning`/`engineRunning` re-check — which the handoff §1 explicitly says "narrows the window but can't close it (classic TOCTOU)":
    - `LocalPlaybackEngine.swift:389` `player.play()` (guarded by `engine.isRunning` at :378)
    - `LocalPlaybackEngine.swift:459` `node.player.scheduleBuffer(...)` (RT thread; `engineRunning` snapshot at :426 released before the call)
    - `LocalPlaybackEngine.swift:285` `node.player.play()` in config-change recovery (guarded by `running` at :280)
    - `LocalPlaybackEngine.swift:268` / `:367` `engine.connect(...)`
  - The companion piece the handoff §5 also required (an `AVAudioEngineConfigurationChange` observer) **was** implemented correctly (`LocalPlaybackEngine.swift:208`, hops to `graphQueue` at :211) — so only the shim adoption is missing.
- Suggested fix direction: wrap each of the four call sites individually in `try catchingObjCException { … }` and treat a caught `ObjCExceptionError` exactly like the existing `LocalPlaybackError.engineNotRunning` soft-fail (roll back the node, stay alive). One-line-per-site change; the infrastructure is already here.
- Confidence: **High** that the shim is unadopted and the sites are bare (grep-proven). **Medium-high** that the residual crash is still reachable — the window is narrow (a config change must fire between the guard and the call), which is consistent with the original "intermittent, 4-in-4-minutes" incident. `[confirm-in-G1]` to reproduce live by toggling the default output device during Current-Device playback.

### MAJOR

**M1. The app tells macOS it runs on 13.0 but is compiled for 14.0 — so it can be
installed and launched on macOS 13, where it may crash on a missing system
symbol; and on 14.0–14.1 it installs but can't play audio.**
- Plain-language: The bundle advertises a minimum of macOS 13.0, but the code is
  actually built against macOS 14.0. A macOS 13 user is allowed to install and
  open it, and the moment the app touches a 14.0-only system feature it can crash
  outright. Separately, the core audio-capture feature needs macOS 14.2, so
  13.0–14.1 users get an app that opens, finds speakers, and produces no sound.
- Evidence:
  - `scripts/make-app.sh:21` `MIN_MACOS="13.0"` → written to Info.plist `LSMinimumSystemVersion` (`make-app.sh:159`) and passed as `--minimum-deployment-target` (`:120`).
  - `AudioutCore/Package.swift:18` `platforms: [.macOS(.v14)]` and `AirPlayEngine/Package.swift:99` `.macOS(.v14)` — the actual compile floor is 14.0, above the advertised 13.0.
  - True functional floor is **14.2**: the process-tap APIs are 14.2+ (`NativeCaptureCoordinator.swift:166` `#available(macOS 14.2, *)`); below that the code returns `UnavailableSystemTap` which throws `osUnsupported` and lands capture in `.failed` (`NativeCaptureCoordinator.swift:712`). Fails soft (no crash) but the product does nothing useful.
- Suggested fix direction: set `LSMinimumSystemVersion` (and `MIN_MACOS`) to **14.2** to match both the compile target and the true functional floor — LaunchServices then blocks install on OSes where it would crash or be useless.
- Confidence: **High** on the version mismatch (declared values are unambiguous). **Medium** that a macOS-13 launch actually crashes (depends on whether any 14.0-but-not-14.2 symbol is referenced outside an `#available` guard — the compiler permits such references at a .v14 floor; I did not enumerate every symbol). `[confirm-in-G1]` on real 13.x / 14.1 hardware/VM.

**M2. A double-clicked shipped `.app` runs the fake demo backend, not the real
AirPlay one. (Adjacent to this audit's mandate — not a crash/hang — flagged for
the release-config audit.)**
- Plain-language: Which backend the app uses is chosen from an environment
  variable that only the developer sets before launching. A customer who
  double-clicks the app has no such variable, so it falls back to the **mock**
  backend — imaginary demo speakers, no real audio.
- Evidence: `AppDelegate.swift:61` calls `makeBackend(resolvePID:)` with no kind → `BackendKind.resolved()` returns `.mock` when `AIRPLAY_BACKEND` is unset (`OwnToneBackend.swift:805`). No `LSEnvironment`/`AIRPLAY_BACKEND` in `scripts/make-app.sh` or the Info.plist. The live-run runbook confirms native requires `launchctl setenv AIRPLAY_BACKEND native` before `open` (`dev/notes/p2b-nativebackend-runbook.md:112-116`).
- Suggested fix direction: make `.native` the default the shipped app resolves to (change the release default, or inject `AIRPLAY_BACKEND=native` via Info.plist `LSEnvironment`, or a build-configuration switch) — keeping `mock`/`owntone` as dev overrides.
- Confidence: **High** on the code path. This belongs to the release/packaging audit; recorded here because it surfaced while tracing the backend for the D5/OwnTone reachability question.

### MINOR

**m1. Launching a second copy gives two menu-bar icons and a dead second
instance.**
- Plain-language: There's no "already running" guard. A second launch puts a
  second icon in the menu bar; its audio engine can't grab the exclusive network
  ports the first instance holds, so it's inert and confusing.
- Evidence: no single-instance check anywhere in `AudioutApp` (grep for
  running-app/second-instance handling is empty in `AppDelegate.swift`); memory
  and `dev/notes/native-live-test-single-instance` note that PTP ports 319/320
  are exclusive → second engine fails to bind + duplicate icons. LaunchServices
  usually re-activates an existing properly-registered `.app` rather than
  launching a second, so this mainly bites when two copies exist at different
  paths.
- Suggested fix direction: on launch, if another instance with the same bundle id
  is already running, activate it and terminate self.
- Confidence: Medium. `[confirm-in-G1]`.

**m2. A force-quit skips clean teardown — possible orphaned Core Audio aggregate
device / process tap until the system reclaims it.**
- Plain-language: If the app is force-killed while capturing, its private audio
  plumbing (a hidden aggregate device + process tap) doesn't get torn down in
  code. macOS normally reclaims process-owned audio objects when the process
  dies, but this is worth confirming so a force-quit + relaunch doesn't leave
  stale devices behind.
- Evidence: teardown runs only via `NativeBackend.stop()` / `CoreAudioSystemTap.teardown()`; a SIGKILL runs neither. `applicationShouldTerminate` handles the graceful path well (bounded `stopAndWait`, `AppDelegate.swift:592-618`) but that never runs on force-quit.
- Suggested fix direction: confirm coreaudiod reclaims process-scoped aggregates on death; if not, reclaim orphans by name on next `start()`.
- Confidence: Low-medium (macOS likely cleans these up). `[confirm-in-G1]`.

### NIT

**n1. The one real *hang* among the STABILITY markers (D5, un-resumed Bonjour
continuation) is on the legacy OwnTone path, which the shipped native app never
selects.** Keep the marker; deprioritize the fix unless OwnTone is ever shipped.
Evidence: `ConnectionDiagnostics.swift:276-291`; native `makeBackend` never
constructs the diagnostics/OwnTone path (`OwnToneBackend.swift:844-856` is the
`.ownTone` case only). Confidence: High.

**n2. TODO/FIXME sweep — no latent app-code bugs.** All app-side hits are stale
doc references to removed stubs (`AppDelegate.swift:460`,
`SettingsWindowController.swift:6`) or "not-a-workaround" clarifications
(`SystemOutputVolume.swift:99`), harmless. The dense TODO cluster is in vendored
upstream C (`sender/airplay.c`, `pair_ap/*`, `evrtsp/rtsp.c`) and in the
deliberately-stubbed engine shims (`shims/*` `TODO(T-SHIM-1)`: "keep as no-op") —
by design, out of scope per the vendored-C rule. The one app-adjacent unimplemented
surface is `AirPlayEngine.swift:1012-1025` (`TODO(later task)`: a Core Audio local
output unit) — an inert API stub, not UI-reachable. Confidence: High.

**n3. Force-unwrap/crash-primitive sweep is clean.** No `try!`, `as!`,
`precondition`, or `assertionFailure` in app source. Every `fatalError` is the
standard `init?(coder:)` AppKit boilerplate (33 sites) — unreachable in this
all-programmatic app (no NIB/storyboard instantiation). Confidence: High.

## Top 5 by user impact

1. **[Critical] The built-and-tested crash guard for Current-Device playback is
   never wired in** — switching output devices mid-playback can still hard-crash
   the app. Fix is four one-line wraps; the infrastructure already exists.
   (`LocalPlaybackEngine.swift:389/459/285/268`)
2. **[Major] Version floor mismatch** — the app claims macOS 13.0 but is compiled
   for 14.0 and truly needs 14.2; raise `LSMinimumSystemVersion` to 14.2 or ship a
   crash-on-13 / silent-no-audio-on-14.1 app. (`make-app.sh:21` vs
   `Package.swift:18`)
3. **[Major] Shipped app defaults to the mock backend** — a double-clicked release
   plays no real audio because `AIRPLAY_BACKEND` is unset; make native the shipped
   default. (Release-config audit territory.) (`AppDelegate.swift:61`,
   `OwnToneBackend.swift:805`)
4. **[Minor] No single-instance guard** — a second launch strands a dead second
   menu-bar icon. (`AppDelegate` — absent)
5. **[Minor/latent] The C7 flapping-receiver reconnect storm and the D4 stuck-drag
   flag** are the two live STABILITY hazards most likely for a real user to
   provoke (a receiver that keeps dropping; ending a volume drag with Esc) — both
   still correctly marked, neither yet fixed.
   (`NativeBackend.swift:2361/2398`, the D4 row-view sites)
