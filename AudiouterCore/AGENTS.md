# AudiouterCore

## Purpose

This Swift package is the whole app: a UI-agnostic core library
(`AudiouterCore`) plus AppKit UI targets that link against it, and the
shipping menu-bar executable. Core must never import AppKit; UI must depend
on the model, never the reverse. `OutputBackend` is the only seam between them.

## Rules

- **This Mac's own AirPlay receiver is never surfaced as a device** (Alec's
  call, 2026-08-07). macOS's AirPlay Receiver announces `_airplay._tcp` under
  the machine's own mDNS hostname, so undiscriminating discovery offers the Mac
  the app runs on as a speaker — a self-loop that mostly can't work (the live
  2026-08-06 "Couldn't connect" storm was this row) and whose legitimate intent
  ("play here") the local This-Mac row already covers. `NativeDiscovery` drops
  any resolved service whose hostname matches `systemLocalHostname()`
  (normalized: case-insensitive, trailing dot stripped) BEFORE identity
  extraction, for both service types; the filter fails OPEN when the hostname is
  unavailable (`localHostname: nil`), because a phantom self row is annoying but
  a silently missing real speaker is a support case. Drops log to stderr once
  per instance name (D6). Tests inject `localHostname:` alongside the browser
  double. If self-AirPlay ever becomes a real feature (e.g. as a receiver-side
  target for ANOTHER Mac running Audiouter), lift this at the discovery seam —
  don't re-plumb the popover.
- **`.passwordRequired` never flattens to `.unknown`.** Both places an engine
  auth rejection surfaces — `applyEngineState`'s `.passwordRequired` arm and
  `convergeDevice`'s add-throw catch — map it to
  `ConnectionFailure.Cause.authRequired`, whose copy names the receiver-side fix
  (a Mac receiver's "Current User" access-control mode is the common case).
  In-app password entry is roadmapped, not shipped; keep the copy honest about
  that until it lands.
- **Any window/panel `show*()` entry point must gate its actual on-screen
  presentation behind `HeadlessRuntime.isActive`** (`HeadlessRuntime.swift`).
  `swift test` and the harness/snapshot tools (`window-harness`,
  `window-snapshot`, `popover-harness`, `popover-snapshot`, `settings-snapshot`)
  hold a real WindowServer connection — an un-gated `makeKeyAndOrderFront`/
  `NSApp.activate`/`popover.show`/etc. in one of these code paths flashes a
  real, empty window on the developer's actual screen for the run's duration.
  `HeadlessRuntime.isActive` detects `swift test` automatically via a DUAL
  check (`HeadlessRuntime.isXCTestLoaded || HeadlessRuntime.isSwiftTestingLoaded`)
  — `isXCTestLoaded` checks whether `XCTest` is loaded into the process
  (`NSClassFromString("XCTestCase") != nil`); `isSwiftTestingLoaded` covers
  swift-testing, which exposes no Objective-C classes for `NSClassFromString`
  to see, by `dlsym`-ing its type-descriptor symbols
  (`$s7Testing4TestVMn`/`$s7Testing5IssueVMn`, the nominal type descriptors for
  `Testing.Test`/`Testing.Issue`) against `RTLD_DEFAULT` — reliable regardless
  of invocation or which test framework a given file uses, no env var needed,
  and it means window-gating survives once the last `import XCTest` is gone;
  the 5 non-app executable tools each set `AIRPLAY_HEADLESS=1` at the very top
  of their own `run()`, before touching AppKit. Only gate the actual
  presentation call — keep layout/sizing/model work (`layoutSubtreeIfNeeded`,
  `setContentSize`, frame-origin math) running unconditionally, since headless
  assertions (structural tests, offscreen PNG renders via
  `bitmapImageRepForCachingDisplay`) depend on it and never need the window
  actually on screen. The real app (`AudiouterApp`) never sets the env var and
  links neither test library, so a live launch always shows its windows
  normally.
- **`Device.isSelected` means "currently in the backend's output set"
  (streaming now) — NOT membership in the UI's Selected Devices set**
  (`GroupController.selectedDeviceIDs`). The output set is exactly the Selected
  Devices' AirPlay members (or an active group's members); the local Mac is
  filtered out, so a passthrough-only selection reaches the backend as an EMPTY
  set. Row/menu state must come from `GroupController.isSpeakerSelected(_:)`,
  never `device.isSelected`. Redirect targets stay excluded from
  `selectedDeviceIDs`/`mainOutMemberIDs` so a redirect can't move the Main Out
  master or pollute group identity — group matching keys off `mainOutMemberIDs`,
  never the live output set. The volume keys drive Main Out and nothing else:
  Main is a stored master GAIN (`Main × Group × Device`, formed once at the write
  boundary in `NativeBackend.engineVolume(forID:uiVolume:)` and never stored), so
  a key press moves one number and every device follows. Per-app redirect targets
  are exempt by design — each redirected app owns its volume.
  `applyExternalSystemVolume(_:)` is the read-back arm and writes no hardware;
  the only hardware write is `setMasterGain`'s `mirrorToSystemVolume` on the
  user-drag arm. One direction writes, the other never does — that, not a
  membership guard, is what makes the loop impossible.
- **A redirected app streams to its target device via the per-app capture path,
  NOT the whole-system output set (T7).** `GroupController.applyRouting` no
  longer unions app-route targets into `backend.setOutputSet` — that union was
  the original bug (redirecting ONE app pushed the WHOLE system mix to the
  device and muted the Mac). App-route changes now flow through
  `AppRoutingController.onRoutesDidChange` → `AppDelegate.pushAppRoutesToBackend`
  → `NativeBackend.updateAppRoutes(_:excludedBundleIDs:)` (the
  `AppRouteConfiguring` seam), which starts per-app capture and binds a dedicated
  engine stream per routed device. The whole-system capture gate still keys off
  `expectedSelected` (what `setOutputSet` was last handed), which no longer
  includes redirect targets, so passthrough no longer opens it.
- **Scope arbiter (roadmap 008): whole-system routing ALWAYS wins a contested
  device inside `NativeBackend` — the per-app domain yields loudly, and is
  RE-DRIVEN ONLY when the losing bow-out's own in-flight release resolves
  (`releaseConvergingAndRequeueIfNeeded`'s `redrivePerApp`), never the
  reverse.** A `.device` route whose target is in `expectedSelected` is
  demoted to effective-`.noRedirect` (same R5 semantics as an unreachable
  target, `isRouteTargetEligibleLocked`); every `bindTail` op re-checks the
  operational whole-system claim (`desiredOn`/`converging`/`added`) under
  `stateQueue` immediately before its engine call — AFTER `ensurePTPTakeover`,
  because a gate before that seconds-wide wait re-opens the window it closes
  — and bows out. **Live-verified gap (2026-08-05, see roadmap 008 notes):**
  re-drive fires for the settle immediately following the CLAIM that caused
  the demotion, but a LATER, separate whole-system deselect of the same
  device (`setOutputSet` dropping it from `desiredOn` well after the contest
  settled) does not re-drive the demoted per-app route — confirmed via
  telemetry, no `scope_conflict`/`unbind_redrive`/re-capture fired at that
  deselect. Read this as accepted current behavior (Alec: turning a speaker
  off shouldn't necessarily hand it back to a stale per-app assignment), not
  as "the reverse never happens" — it currently does, on this path. TWO
  TRAPS: (1) a
  `bindTail` op must NEVER WAIT on the `converging` slot — a bind queued ahead
  of a recovery that holds the slot would deadlock the FIFO (bow-out +
  re-drive is the only safe shape); (2) an `.unbind` under a whole-system
  claim is neither executed nor blanket-skipped — executing it kills the
  user's fresh stream-0 session, skipping it strands an astray engine session
  (the engine's `addOutput` is a silent no-op on a live session) or leaks a
  zombie per-app session when the converge parked. `performBindOp`'s
  four-case arm + the verify-first settle exist precisely for this; don't
  "simplify" them back to either extreme.
- **The whole-system tap's `.failed` now self-heals via a bounded retry (T16,
  E10).** `CaptureControlling` gained `onStateChange`; `NativeBackend` wires it in
  `start()` and drives a capped-exponential backoff retry
  (`handleCaptureCoordinatorStateChange` → `scheduleCaptureRetry`, mirroring the
  per-app `.processNotYetAudible` retry). Two differences from the per-app path:
  the retry only arms when `NativeCaptureError.isRetryable` (everything but
  `.osUnsupported`), and — because there is ONE `.mutedWhenTapped` whole-system
  tap — it **re-checks `captureRunning` at FIRE time** before calling `start()`,
  so a deselect during the backoff can't restart the tap and mute the Mac with
  the audio going nowhere (the bug `reconcileCaptureGate` exists to prevent).
- **Resolving a bundle ID for per-app capture or whole-system exclusion MUST
  resolve to the FULL set of Core Audio processes, not a single pid.** Multi-process
  browsers emit audio from child/helper processes whose pids differ from the main
  app, and Core Audio reports no bundle id for those children. Shortcutting to
  single-pid resolution misses the real audio source — the routed app becomes
  inaudible and its audio leaks into the system mix. Both coordinators inject
  `AudioProcessResolver` for this reason. **Its four attribution layers are an
  ANY-of union, never first-non-nil-wins:** a helper reporting a bundle id of its
  OWN (`com.spotify.client.helper`) and reparented to launchd (`ppid == 1`) —
  proven live 2026-07-26 — defeats both the own-bundle and parent-walk layers, so
  the `responsibility_get_pid_responsible_for_pid` and bundle-path layers must
  still be consulted. Collapsing them back to a single "effective bundle id"
  reopens the exception leak.
- **T2: resolving a bundle ID also emits a `Telemetry` line naming which
  attribution layer matched each resolved pid** — `AudioProcessResolver
  .resolveWithAttribution(bundleID:)` is the diagnostic companion to `resolve
  (bundleID:)` (same ANY-of matches, each tagged with its ``AttributionLayer``:
  `own`/`responsible`/`bundlePath`/`parentWalk`). `NativeCaptureCoordinator`
  logs `.captureWS`/`exclusion_resolved` (bundleID -> `[pid:layer,...]`, plus a
  `zeroBundles` field) at both its resolve choke points
  (`resolveExcludedProcessObjectIDs`/`rebuildIfExclusionObjectsChanged`);
  `PerAppCaptureCoordinator` logs `.capturePA`/`process_resolved` the same way
  in `beginStart`/`handleDeviceChange`. Exists because the 2026-07-26 catch-all
  leak could only be diagnosed by manually correlating `ps` against telemetry
  that showed exclusion INTENT (`exclusion_changed`'s bundle-id list) but never
  which concrete processes a bundle id resolved to, nor how — a bundle
  resolving to ZERO processes is exactly that leak's signature and is now
  visible in the log alone, no repro needed.
- **`AppRouteDestination` is three cases, not two: `.noRedirect` (new default,
  unset) / `.currentDevice` (explicit "play here" pick) / `.device(id:)`.**
  `.noRedirect` and `.currentDevice` are capture/engine-equivalent — both mean
  "plays locally, stays in the whole-system mix" — they differ only in popover
  UI state (unset vs. a deliberate choice). Don't pattern-match negatively on
  `.currentDevice` to mean "is redirected"; use `AppRouteDestination.isDeviceRoute`
  (true only for `.device`), the single source of truth for "actually routed
  away."
- **`.currentDevice` local playback follows the Mac's real default output device
  (Bluetooth, USB, HDMI, built-in, etc.), re-resolved on each cold start.**
  ANTI-FEEDBACK GUARD: it refuses to follow a default whose transport is AirPlay
  or virtual/aggregate — those are exactly the transports this app may be streaming
  the whole-system mix INTO, so following them loops local playback straight back
  into the capture. If no safe default exists, it falls back to built-in speakers.
  Don't hardcode built-in (wrong when Bluetooth is selected), but don't blindly
  follow any default (creates feedback loops).
- **Every real (re)connect must reseed the engine volume** from
  `connectVolumeProvider()` (an `AppSettings.connectVolume` read, clamped to
  min/max — NOT the Mac's system level, which is what this said before), or from a
  level a caller attached to that one connect with `armConnectVolume` (same
  clamp, so an automation's number is no more trusted than the setting's): the
  engine's volume field is zero-initialized and 0 maps to ≈ −30 dB (silent), so a
  connect that pushes no volume streams INAUDIBLY until the first slider touch —
  the −30 dB trap. The clamp keeps the seed audible on its own; note that Main is
  a separate stage, so a seed of 35 with Main at 0 is still silent, correctly.
  The one exception is `applyStartBuffer`'s internal teardown/re-add (a
  buffer-size change, *not* a reconnect), which preserves the in-session level
  instead. That is why the seed is gated on `bufferReAdding`, not fired
  unconditionally in the shared add path — remove the gate and a plain buffer
  change resets the user's level. The seed (`connectVolumeSeed`) is reachable from TWO independent
  add-success sites — `convergeDevice`'s post-`addOutput` write (ordinary
  user-initiated connects) and `applyEngineState`'s `.connected`/`.streaming`
  branch (out-of-band auto-recovery reconnects that never go through
  `convergeDevice`) — and the vendored dispatcher always mirrors an armed
  `addOutput` completion onto the engine's state stream too, so an ORDINARY
  connect reaches both sites, racing which one gets to `stateQueue` first. The
  seed fires ONLY on the `added` false→true edge each site observes: whichever
  flips `added` first (both under `stateQueue`) seeds, the other sees `added`
  already true and skips — one push per connect, with NO separate seeded-set to
  clear. (An earlier `volumeSeeded: Set` hand-cleared at every teardown regressed
  live — a second disconnect→reconnect kept the first reconnect's stale level when
  a clear was missed/reordered; `added` is the connection ground truth already
  removed at every teardown, so keying on it makes that drift impossible and every
  genuine reconnect reseeds.) `pushVolume` additionally serializes per output id
  (`volumeInFlight`/`volumePending`, latest-wins) so no caller can ever have two
  `engine.setVolume` calls in flight for the same output concurrently — the
  vendored C dispatcher's "one pending callback per device" `outputs_callback_add`
  contract turns a second concurrent call into a clobbered/leaked waiter for the
  first, which is what caused a live regression (leaked `startOp` continuations,
  eventual disconnect) before this guard existed.
- **Metering is THREE real sources, all on the same event channel, all
  popover-scoped (T3).** `setMeteringActive` fans the popover-visibility gate to
  the whole-system `captureCoordinator`, the `routeMixer`, AND the
  `localPlaybackEngine`, and drives the metering-only tap lifecycle below. Each
  device's `.level` is the MAX of its whole-system-tap contribution (only if it's
  a Selected Device, unmuted) and the loudest PRE-volume SOURCE level among the
  apps `.device`-routed to it (`latestAppLevel`) — a device fed by both shows the
  larger. Every meter is a SOURCE/program level (PRE any routing/output volume), so
  a low slider never empties a bar. Each listed app's `.appLevel` comes from exactly
  one source by route kind: `.device` → `routeMixer.onAppLevel` (PRE-volume source),
  `.currentDevice` → `localPlaybackEngine.onAppLevel` (PRE-volume, emitted raw),
  `.noRedirect` → `meteringCapture`, a SEPARATE `.unmuted` per-app tap that exists
  only to measure listed apps with no other capture and feeds neither the mixer
  nor the engine. PRIVACY: a user-excluded app is NEVER metered — the
  metering-only target set is `listed − routed − local − excluded`, re-reconciled
  inside `updateAppRoutes` whenever routes/excluded change, and an app that
  becomes excluded has its metering tap stopped immediately. The metering-only
  taps NEVER start/stop the primary routing coordinators' taps.
- **A whole-system capture-tap rebuild caused by a DEVICE/RATE change must reset
  the stream-0 AirPlay session (R10) — but ONLY that cause.** When the tapped
  output device changes or renegotiates its nominal sample rate (another app
  grabbing the mic; a default-output-device change), the tap is rebuilt and keeps
  delivering fresh PCM, but the whole-system RTP timeline anchor is left desynced,
  so every Selected-Devices speaker goes permanently silent until the session is
  reset. `NativeCaptureCoordinator` signals *that specific cause* via
  `onDeviceRateRebuild` (NEVER on the first `start()`, and for an
  `.exclusionChange` rebuild only when the tap that came back up is measurably on a
  different device or nominal rate than the one that went down — see the trap
  below);
  `NativeBackend.resetAirPlaySessionForWholeSystem()` responds by rebinding each
  streaming (`added`) device — claiming the same per-device `converging` slot
  `convergeDevice` uses (so the removeOutput → addOutput can't interleave with a
  concurrent converge), bumping `rebindRecoveryGen`, and enqueuing the shared
  rebind-recovery chain (with `stillOwnsRebind` ownership bow-out, backoff retry,
  and `.streamHealth` signal-only events). It is BOOKKEEPING-TRANSPARENT and a
  no-op when nothing streams whole-system. This is the stream-0 analog of the
  per-app `resetAirPlaySessionForRoutedApp`. Crucially, an EXCLUSION-set rebuild
  (the synced-local sink attach on every Mac+AirPlay connect, or an app-route
  change) leaves the device/clock — and thus the receivers' timeline — intact and
  must NOT reset: resetting there added a redundant RTP re-establish to every
  connect ("connects fast, then a long silence"). The live exclusion set is instead
  kept correct by the debounced process-object-list membership diff (W1-T7 Gap 1) +
  `refreshExcludedProcessSet` (relaunch, W1-T7 Fix 1), which recreate the tap as
  `.exclusionChange` (compare-before-rebuild, no session reset).
  **TRAP: the rebuild cause is an assumption, not evidence — never make the reset
  decision from `RebuildCause` alone.** The old tap's `teardown()` takes its
  default-device listener with it and the new tap arms its own only inside
  `createAndStart`, so a default-output-device change landing in between is delivered
  to nobody: an `.exclusionChange` rebuild can come back up on a different device's
  clock while the receivers hold the old timeline, and a cause-only trigger leaves
  them silent until some later device/rate event happens to reset them. `recreateTap`
  therefore also compares the outgoing tap's `SystemAudioTap.tappedDeviceID` and rate
  against the incoming one's and resets on a real move. A tap that reports `nil`
  (the protocol default) abstains from the identity half rather than forcing a reset.
- **The silence fallback (R11) has its OWN always-on delay, decoupled from the
  wake-restore preference.** `armSilenceWatchdog` uses the always-on
  `silenceFallbackDelay` (`defaultSilenceFallbackDelay`, ~10 s, no UI, can't be
  disabled) for a dead-group/stranded condition during normal operation, and the
  user's `wakeAudioRestoreDelay` (Settings › Audio, `nil` = "Never") ONLY while
  `awaitingWakeReconnect` (the post-wake window `handleSystemDidWake` opens). So a
  "Never" wake setting can't reopen R11's indefinite silence during normal use,
  while the post-wake grace still honors the user's preference. The fallback's
  banner-clear (`.localFallbackActive(false)`) is emitted from ONE helper,
  `clearSilenceOverride()`, on the genuine true→false edge — every path that ends
  the fallback (reconcile, `stop`, sleep, wake) routes through it so the banner
  never strands ON (invariant 4).
- The live routing set is not auto-resumed at launch (`RoutingStore` is
  write-only at launch) — a previously-selected device never auto-streams.
  Saved groups still persist and re-apply. A per-app redirect follows
  the SAME discipline at launch: `AppRoutingController.clearAllRedirectsAtLaunch()`
  reverts EVERY non-`.noRedirect` destination — `.currentDevice` picks included —
  once, called before the initial route push, so a redirect never silently
  survives a full restart regardless of how long its target was gone for.
- **A per-app `.device` route survives its target going merely UNREACHABLE
  (`isAvailable == false`) — it does NOT survive the target DISAPPEARING
  entirely.** These are different signals and only the second resets the
  route (`AppRoutingController.handleDeviceDisappeared`, fired from
  `PopoverController.update(devices:)`). While a kept route's target is
  unreachable, `NativeBackend` computes an EFFECTIVE route table — a
  `.device` route whose target can't currently carry audio reads as
  `.noRedirect` for every per-app mechanism (capture start/stop, the
  whole-system tap's exclusion set, the mixer, local playback, metering) —
  so the app rejoins whatever the system is currently outputting to instead
  of being excluded in favor of a stream that goes nowhere. The USER's real
  route table (`lastRoutes`) is untouched throughout; the redirect re-engages
  itself the instant the device is reachable again, with no route-table edit
  in either direction. Never make this decision from discovery events alone —
  reachability also changes via engine-state transitions and converge
  failures, all of which must funnel through `NativeBackend.commitKnownDevice`
  so the effective table never goes stale in the direction that hurts (an app
  excluded from the whole-system tap with nowhere for its own stream to go is
  silence with no visible cause).
- **A saved GROUP containing the local Mac must reach the backend the same
  way the Selected-Devices path already does: the Mac filtered OUT of
  `setOutputSet`, and the synced-local sink armed by whether the Mac is a
  member of whatever MAIN OUT currently targets** — `GroupController
  .isMainOutMember(_:)`, not `isSpeakerSelected(_:)` (the latter reads
  Selected Devices only and is blind to group membership; wrong in BOTH
  directions under a group target — a group containing the Mac never arms
  the sink, and the Mac can arm the sink wrongly while merely sitting
  untargeted in Selected Devices during an AirPlay-only group). Under
  `.selectedDevices` `isMainOutMember` and `isSpeakerSelected` are
  *provably* the same read (`mainOutMemberIDs` is `Array(selectedDeviceIDs)`
  in that branch) — so this only changes behavior on the group path.
- **`TCCAccessPreflight` is cached for the CALLING process's whole lifetime**,
  so a grant made after launch is invisible to any in-process read forever —
  and the `com.apple.tcc.access.changed` Darwin notification fires but does NOT
  refresh that cache. The notification (plus launch/wake/routing/popover-open)
  is therefore only the TRIGGER; the READER must be the freshly-spawned
  `tcc-probe` helper (`TCCProbeRunner`). `PermissionStateObserver` pairs them
  and is EVENT-DRIVEN BY DECISION — no `Timer`, no polling; burst safety comes
  from `TCCProbeRunner`'s single-flighting. Only `.resolved(.granted)` may ever
  reach `recordFreshGrant(source:)`; every other answer means "still unknown."
- **A refused capture strands BOTH paths, and NOTHING auto-revives them
  mid-session — by decision.** Whole-system: `reconcileCaptureGate()` sets
  `captureRunning` before dispatching a `start()` that cannot report failure, so
  every later reconcile short-circuits. Per-app: `updateAppRoutes` starts only
  the route-table DIFF, so re-pushing an unchanged table starts nothing, and the
  indefinite retry is `.processNotYetAudible`-only. The auto-resume machinery
  that used to paper over both was DELETED (2026-07-25): the app never
  auto-connects at launch and `AppRoutingController.clearAllRedirectsAtLaunch()`
  clears every redirect there, so a fresh launch after granting is the
  supported — and only — recovery path. Do not reintroduce a mid-session
  resume without revisiting that decision.
- `NativeBackend` has no `ConnectionDiagnosing` seam — `.failed` cause is
  always `.unknown`. `MockBackend` mutation stays no-op-silent and confined
  to its private serial queue.
- Known stability findings in this package carry `STABILITY(id)` inline
  markers — details and fix sketches in
  [../dev/notes/stability-audit-2026-07-18.md](../dev/notes/stability-audit-2026-07-18.md).
- `Group.iconSymbolName` is an optional bare SF Symbol name string, added
  with no schema/version bump — `nil` decodes cleanly from any
  pre-existing persisted group and means "use `Group.defaultIconSymbolName`."
  Resolution (including render-time fallback for a stale/unrecognized name)
  lives in `AudiouterSharedUI.DeviceIcon`, not here.
- **Use `swift test --filter <Suite>` for the inner-loop feedback cycle**,
  not the full suite (874 tests). Scope to the test suite(s) touched by your
  change, e.g. `swift test --filter PopoverControllerTests`.
- **The full run is `scripts/run-tests.sh`**, never a bare `swift test` — it
  wraps `swift test --parallel` and adds the two things a bare run cannot do
  on a machine with several worktrees in flight:
  - **A machine-wide concurrency CAP** (`AUDIOUTER_TEST_SLOTS`, default **2**) —
    a counting semaphore over `/tmp/audiouter-suite.lock.N`, shared across every
    worktree and clone. `--num-workers 4` caps one PROCESS; it cannot see the
    other agents each running their own capped suite. Four concurrent Guard 4
    runs put 16 xctest processes plus four independent compiles on 8 cores —
    measured 15-minute load averages of 29-73. The cap is 2, NOT 1: measured, a
    warm run uses only ~2.6 of 8 cores (411s user + 66s sys over 181s wall), so
    the suite is WAIT-bound, not CPU-bound, and two runs genuinely overlap.
    Serialising to one would idle most of the machine and needlessly queue
    agents behind each other.
  - **Adaptive serial/parallel (`AUDIOUTER_TEST_MODE=auto|parallel|serial`).**
    Measured on the same machine for the identical 1025 tests:

    | mode | wall | user CPU | sys CPU |
    |---|---|---|---|
    | `--parallel 6` | 127s | **358s** | **51.7s** |
    | `--parallel 2` | 278s | 316s | 46.6s |
    | serial | 124s | **69.7s** | **6.0s** |

    Serial does the same work for **~1/5 the CPU and ~1/8 the system time**.
    **CORRECTED 2026-07-25** — `--parallel` forks one process per test
    **METHOD**, not per class (an earlier version of this doc said "class";
    verified wrong by watching live `ps` output: different methods of the
    SAME class run as distinct concurrent processes, and total spawns for a
    filtered single-class run equals that class's method count, not 1). This
    suite has **1025 methods across 58 classes**, so each spawn re-execs and
    re-links a large AppKit/CoreAudio/AirPlayEngine binary to run ONE test.
    Real test work is ~70 CPU-seconds; parallel spends ~290 MORE on fork/exec
    + dyld — **~0.28-0.33 CPU-seconds per spawn**, the right order of
    magnitude for launching a large linked binary (dividing that overhead by
    the class count instead gives ~5 CPU-seconds per spawn, which is not
    physically plausible — more than the entire serial suite's total CPU).
    **Consequence: consolidating test classes cannot reduce spawn count** —
    1025 methods spawn ~1025 processes regardless of how many classes they
    are grouped into. See `docs/notes/test-parallel-spawn-measurement.md`
    (worktree `claude/test-class-consolidation`) for the full measurement.
    This is also why lowering `--num-workers` barely helps — it staggers the
    ~1025 spawns rather than removing them (6→2 workers was 2.2x SLOWER for
    the same load).
    On an idle machine parallel is still ~1.8x faster in wall time (~70s vs
    ~124s warm), so `auto` picks parallel when nothing else is testing and
    serial when something is — including a bare `swift test` started outside
    this script, which it detects via `pgrep`.
  - **Remote Mac (opt-in, off by default).** Configure with `git config`, NOT an
    env var or a committed file:

    ```
    git config --local audiouter.remoteHost 'user@192.168.4.41'
    git config --local audiouter.testPrefer remote   # or: local (default), cpu
    ```

    This lands in `.git/config`, which is **not tracked** — so a personal
    username and LAN address never enter the repo — and which every worktree
    shares, so one command covers all of them. It is also read by git itself
    rather than by a shell, which matters: hooks run NON-interactively and a
    non-interactive zsh does not source `~/.zshrc`, so an `export` there would
    reach some runs and not others. `AUDIOUTER_TEST_REMOTE_HOST` /
    `AUDIOUTER_TEST_PREFER` still override per-invocation.

    `testPrefer=local` (default) treats the two machines as ONE POOL: two runs
    locally, and the third and fourth agent overflow to the remote rather than
    queueing. `testPrefer=remote` sends every run there first instead, blind to
    whether it's actually free. `testPrefer=cpu` probes `vm.loadavg` on both
    machines (normalised by `hw.ncpu`, since core counts differ) and sends the
    run to whichever is less loaded right now — the setting to use if the
    remote isn't reliably idle when you'd want to use it. Any of the three:
    an asleep/offline/unmeasurable remote costs one 5s probe and then behaves
    exactly as if none were configured.

    **A remote PASS is accepted; a remote FAILURE is re-run locally before it
    can block anything.** Guard 4 refuses commits on this result, and the remote
    is on a different Swift/SDK — a toolchain difference presenting as "your code
    is broken" would send an agent hunting a bug that does not exist. The
    asymmetry is deliberate: the expensive error is a false REFUSAL, not a false
    pass on code paths that are provably identical (highest gate `macOS 15`,
    Swift 5 language mode). Cost is one extra run, and only when something
    actually failed. `rsync`s the WORKING TREE
    (so uncommitted edits go too, which `git push` cannot do) into a per-worktree
    directory under `AUDIOUTER_TEST_REMOTE_ROOT`. Cost is negligible: ~22MB/446
    files on first sync, **~3KB after editing one file**. `.build` is excluded —
    it bakes in absolute paths and is per-machine.
    Probe timeout is a deliberate 5s: the known failure mode is the host being
    ASLEEP, where it answers ping via a sleep proxy but refuses TCP, so a
    generous timeout would stall every contended run behind a host that will
    never answer. Any "cannot reach / cannot sync / connection dropped" outcome
    falls back to the local queue and is NEVER reported as a test failure —
    toolchains differ (local Swift 6.4 / macOS 27 SDK vs remote 6.3.1 / macOS 26)
    and an agent reading infrastructure trouble as a code failure will chase a
    bug that does not exist. A genuine remote FAILURE is reported, but flagged
    to confirm locally first.
    **Version parity is a smaller risk than it sounds:** the highest OS gate in
    this repo is `#available(macOS 15, *)` and the deployment target is
    `.macOS(.v14)`, so a macOS 26 host takes byte-identical code paths to a
    macOS 27 one — nothing here knows macOS 26/27 exists. The package is also
    `swift-tools-version:5.10` with no language-mode override, i.e. Swift 5
    language mode, which does not diverge between 6.3 and 6.4.
    **VERIFIED end-to-end 2026-07-25** against the real M3 (Apple M3, 8 cores,
    24GB, macOS 26.5.2, Swift 6.3.1): builds clean on 6.3.1 with **zero errors**
    (only cosmetic `ld` warnings about Homebrew dylibs built for macOS 26 vs the
    macOS 14 deployment target), full suite **1025/1025 green in 45s** (vs
    ~90-180s locally under contention), the audio gate skips its 7 correctly
    there, and overflow triggers only once both local slots are held. Sync of
    the whole tree takes ~1.6s over LAN.
  - **KNOWN GAP — the cap only covers runs that go THROUGH this script.** An
    agent that types `swift test` or `swift build` directly bypasses it
    entirely, and that is the dominant real-world source of load: while
    measuring this, two other worktrees were independently running a full serial
    suite and a `-c release` product build, driving load average to 29 and
    making an unrelated 4s filtered run take 117s. Prefer `scripts/run-tests.sh`
    for any full run. This is convention, not enforcement (the PreToolUse nudge
    hook that tried to enforce it was deliberately removed and must not be
    rebuilt).
  - **A content-addressed pass cache**: if these exact sources already passed,
    the run is skipped. Agents routinely run the suite by hand and then
    commit, firing Guard 4 on byte-identical sources seconds later.

  Escape hatches: `AUDIOUTER_TEST_MODE=parallel` (force the fast path when you
  are watching the terminal), `AUDIOUTER_TEST_SLOTS=N` (concurrency cap,
  default 2), `AUDIOUTER_TEST_NO_LOCK=1` (skip the cap entirely),
  `AUDIOUTER_TEST_NO_CACHE=1` (force a real run), `AUDIOUTER_TEST_WORKERS=N`.
  If all slots stay busy past `AUDIOUTER_TEST_LOCK_TIMEOUT` (default 1800s)
  the runner proceeds **uncapped** rather than failing — it exists to protect
  the CPU, not to gate correctness, and must never block a commit for a reason
  the committer cannot see. **That measured process-per-method cost belongs to
  the XCTest era and no longer describes most of this suite.** The migration
  to swift-testing (`docs/notes/swift-testing-conversion-cookbook.md`) is done
  for the large majority of files: those `@Suite` tests run **concurrently,
  in-process** (Swift structured-concurrency task scheduling, not one OS
  process per test), so "tests must not race on cross-process shared state" is
  no longer the operative risk for them — the risk is now an **in-process**
  race on anything `static`/global, guarded by `IsolatedSuite` (see above) and,
  for process-global C/singleton state, by nesting into
  `SerializedSharedStateSuite.swift`'s `.serialized` `SerializedSharedState`
  parent suite. A small number of files remain on the legacy `XCTestCase` base
  (current count via `git grep ': XCTestCase'` under `AudiouterCore/Tests/`) —
  for those, and only those, the old process-per-method isolation reasoning
  above still applies.
- **Coverage gate (the one enforcement that matters):** `.githooks/pre-commit`
  Guard 4 runs the full suite via `scripts/run-tests.sh` whenever a commit's staged
  files touch AudiouterCore Swift sources/tests, and blocks the commit if it
  fails. So a too-narrow filter in the loop can never ship a regression — it
  only costs one extra fix cycle at commit. Everything that reaches `main` was
  committed through this gate, so `main` stays green. Filtering in the loop is
  a convention (this doc), not machine-enforced; `--no-verify` skips the gate
  for a deliberate emergency.
- **Real-audio-hardware tests are opt-in via `AIRPLAY_AUDIO_HARDWARE_TESTS=1`.**
  `LocalPlaybackEngineTests` drives the concrete `LocalPlaybackEngine` (a real
  `AVAudioEngine`) against the Mac's actual output. **The reason is determinism,
  not CPU** — measured, these tests cost 0.9 `coreaudiod` CPU-seconds, and the
  whole suite costs ~10 across an 87s run (~11% of ONE core, ~1.4% of an 8-core
  machine). Core Audio is NOT a meaningful part of suite cost; test execution
  is. (Earlier "coreaudiod at 38-45%" figures were instantaneous `ps` %CPU
  samples — they overstate sustained load badly; don't cite them.) What the gate
  buys: these seven tests depend on real hardware and a machine-wide daemon, so
  they are timing-sensitive to whatever else the Mac is doing — the documented
  cause of three unrelated tests flaking under `--parallel` on a busy machine.
  `AudioHardwareTestGate.trait` (a `ConditionTrait`) is applied to ONE nested
  `@Suite(AudioHardwareTestGate.trait) struct RealHardware { ... }` inside
  `LocalPlaybackEngineTests` — the one choke point every hardware test lives
  inside, so a newly added hardware test inherits the gate automatically by
  being written inside `RealHardware`, with nothing to remember per test.
  swift-testing evaluates skip conditions as traits before the test body runs,
  so the old shape (a `skipUnlessEnabled()` call inside a shared helper every
  hardware test called) no longer works — `AudioHardwareTestGate
  .skipUnlessEnabled()` still exists but is legacy, kept only for any
  not-yet-converted `XCTestCase` hardware test. Everything inside
  `RealHardware` skips by default (visibly, with a reason); the handful of
  pure/static tests outside it (e.g. exercising `isFollowableTransport`)
  always run. Run the real ones deliberately when working on local playback:
  `AIRPLAY_AUDIO_HARDWARE_TESTS=1 swift test --filter LocalPlaybackEngineTests`.
  They are NOT faked — `LocalPlaybackControlling` is the protocol fakes already
  implement, so spying here would delete the only coverage of the real engine.
- **Isolate shared state via `IsolatedSuite` (new/converted suites) or
  `IsolatedTestCase` (legacy).** Two suites/tests that both write
  `UserDefaults.standard` or the same `FileManager.default.temporaryDirectory`
  path race and flake — under swift-testing's in-process concurrency this is no
  longer only a `--parallel`-process hazard, it can happen between any two
  tests running concurrently in the same process.
  `Tests/AudiouterCoreTests/IsolatedTestCase.swift` holds the shared
  `TestIsolation` mechanism plus two bases over it: **`IsolatedSuite`** — the
  swift-testing base, inherit this in any new or converted suite
  (`@Suite final class Foo: IsolatedSuite`) — and **`IsolatedTestCase`**, the
  legacy XCTest base, kept only because a few files still subclass it (verify
  the current set with `git grep IsolatedTestCase`); nothing currently forces
  its removal, so it stays deliberately until the last such file converts. Both
  bases expose the identical member set — `scratchDir` (per-test temp dir),
  `isolatedDefaults` (per-test suite), `uniqueName(_:)` (for APIs like
  `NSWindow.setFrameAutosaveName` that always write `.standard`) — instead of
  the shared globals. `.githooks/pre-commit` Guard 3 warns when a newly added
  test line reaches those globals; a line that genuinely must touch one takes a
  trailing `isolation-ok` comment.
- **`Telemetry.log(...)` is always-on** (gated only by `HeadlessRuntime.isActive`,
  never an env var), non-blocking, and must never call back into a caller. Never
  call it from the IOProc/render path — only from the (non-realtime) decision
  points around it. It auto-neutralizes under tests; don't add a per-suite
  workaround. `_resetForTesting(directory:)` (real disk I/O against an injected
  directory — rotation, size-bound, fail-safe) stays exclusive to
  `TelemetryTests`. `_installTestSink(_:)` is lighter-weight (no filesystem) and
  is also the intended seam for each instrumented subsystem's OWN suite to
  assert its emissions (e.g. `PerAppCaptureCoordinatorTests`' `capturePA`/
  `rate_rebuild` assertion) — install it, drive the real code path, read back
  what was captured, then call it again with `nil` (also a synchronous flush
  barrier) before the test returns. `_installTestSink` is process-global state,
  and swift-testing runs tests **concurrently inside one process** (unlike
  XCTest's one-process-per-method model), so a `defer { ... nil }` alone no
  longer keeps one test's sink from bleeding into a concurrently-running one —
  every suite that touches this seam (`TelemetryTests`,
  `NativeCaptureCoordinatorTests`, `PerAppCaptureCoordinatorTests`,
  `NativeBackendTests`, `SetupModelTests`; confirmed via
  `git grep _installTestSink`) nests into the shared `SerializedSharedState`
  parent suite (`Tests/AudiouterCoreTests/SerializedSharedStateSuite.swift`,
  `.serialized`) for true mutual exclusion instead.

## Map

| Type | Role |
|---|---|
| `Device` | Value-type snapshot of one output; backend is the only writer. |
| `ConnectionState` / `ConnectionFailure` | Per-device connection lifecycle + failure cause. |
| `ConnectionDiagnosing` | "Why didn't it connect" seam; `OwnToneBackend`-only. |
| `GroupController` | Routing brain: Selected Devices, Main Out, groups. |
| `AppRoutingController` | Per-app routing state/destinations; `onRoutesDidChange` is the table-changed signal T7 wires to the backend. |
| `AppRouteConfiguring` | Optional backend capability (T6/T7): `updateAppRoutes` streams a routed app to its device. `NativeBackend` only. |
| `AppRouteStore` / `RoutingStore` / `GroupStore` | Versioned-JSON persistence. |
| `DeviceIconStore` | Persists per-device icon overrides (bare SF Symbol name strings only) for `AudiouterSharedUI.DeviceIconController`. |
| `BackendEvent` | Backend→UI push channel: add/remove/update/level/app-level/volume-changed/routedApps. |
| `OutputBackend` | The protocol seam between app and audio routing. |
| `MockBackend` | Fully-working offline backend for tests/demos. |
| `OwnToneBackend` | HTTP-polling backend against OwnTone; superseded. |
| `NativeBackend` | Shipping backend; drives `AirPlayEngine`, owns capture gate, owns aggregate device lifecycle. |
| `AggregateOutputDevice` | Lifecycle owner (adopt-or-create/off-switch/orphan sweep) for the PUBLIC, Sound-settings-visible "Audiouter" aggregate (UID `com.audiouter.Audiouter.aggregate`); thin CoreAudio shell wired by `NativeBackend`. Becomes Mac default when whole-system routing arms; restore-prior-default-then-destroy on quit; echo-guarded. New `BackendEvent` case `routingBlockedNeedsDefault(Bool)` signals when the app can't route because its aggregate isn't the Mac's default output. |
| `NativeDiscovery` | Bonjour discovery (AP2 + AP1). |
| `NativeCaptureCoordinator` | Whole-system Core Audio capture; excludes individually-routed + user-excluded apps. |
| `PerAppCaptureCoordinator` | Per-process Core Audio capture taps, one per individually-routed app. |
| `AudioProcessResolver` / `AudioProcessEnumerating` | Bundle ID → ALL its Core Audio process objects (main + helper/child processes) via four ANY-of attribution layers: own bundle id, responsible pid, bundle-path containment, parent-pid walk; the AppKit lookups (pid→bundle, bundle→`.app` path) are injected. `resolveWithAttribution(bundleID:)` (T2) is the diagnostic twin of `resolve(bundleID:)`, tagging each resolved process with its matching `AttributionLayer` for `Telemetry`. |
| `AppRouteMixer` | Combines per-app captures into per-destination mixed streams; applies per-app volume. |
| `SystemOutputVolume` | Reads/writes the Mac's output volume/mute. |
| `makeBackend(_:)` | The one factory that knows concrete backend types. |
| `SetupModel` | Brain of the first-run permission-priming flow (AppKit-free): per-permission `PermissionStatus`, PTP helper `PTPHelperStatus`, runs the injected probes, persists `AppSettings.hasCompletedSetup`, gates auto-present via `shouldPresentOnLaunch(settings:backendKind:)` (native only). UI = `AudiouterOnboardingUI`. |
| `SystemAudioCaptureTCC` | Silent three-valued system-audio TCC read across both buckets, plus the one-way fresh-verdict latch (`recordFreshGrant(source:)` / `effectiveStatus()`) every capture gate reads through. |
| `TCCProbeRunner` | Async, single-flighted launcher for the bundled `tcc-probe` helper — the only reader immune to this process's permanently-cached TCC read. |
| `PermissionStateObserver` | Event-driven (zero-timer) detector for the grant ARRIVING mid-session: Darwin/launch/wake/routing/popover triggers → `TCCProbeRunner` → latch → `onBecameGranted` once. |
| `AudioCapturePermissionProbing` / `CoreAudioTonePermissionProbe` | Seam + impl that BOTH triggers and verifies the system-audio grant — a denied tap returns `noErr`+zeros, so it plays a muted in-process tone, taps our OWN process, and reads RMS. **Gated on live TCC verify** (`dev/notes/onboarding-setup-brief.md`). |
| `LocalNetworkPriming` / `LocalNetworkPrimer` | Seam + impl: a brief `NWBrowser` for `_airplay._tcp` that fires the Local Network prompt (no verify API exists — TN3179). |
| `RemoteControlPriming` / `RemoteControlPrimer` | Seam + impl: `AXIsProcessTrustedWithOptions` fires the Accessibility prompt. Primed AHEAD of the feature that needs it (speaker-side transport controls simulating Mac media keys — not yet merged; the branch name once cited here, `claude/speaker-input-responsiveness-b8123f`, does NOT hold this work — its tip is an old already-merged checkpoint with zero unique commits, see `docs/plans/phase-3-findings/branch-inventory.md`); same `.requested`-only honesty rule as Local Network even though `AXIsProcessTrusted()` is a real status API, because macOS doesn't reliably push a live grant back to an already-running process. |
| `PTPHelperManaging` / `SMAppServicePTPHelper` | Seam + impl (T6) over `SMAppService.daemon(plistName:)` for the privileged PTP helper daemon (`AirPlayEngine/docs/ptp-helper-design.md`); `register()` is idempotent and prompt-free, `.status` maps to `PTPHelperStatus`. Real `.enabled` is Developer-ID-signing-gated — unit-tested only via the injected fake. |
| `SystemSettingsPane` | `x-apple.systempreferences:` deep links the onboarding flow opens on denial. |
| `TapRebuildDecision` | Pure compare-before-rebuild guard (`NativeCaptureCoordinator.swift`) evaluated once per subscriber inside `DefaultOutputDeviceMonitor`'s fan-out (the single process-wide default-device/nominal-rate listener pair both `CoreAudioProcessTap` and `CoreAudioSystemTap` subscribe to, replacing each tap's own raw HAL listener block): fires a rebuild only when the device/rate a tap is actually pinned to genuinely changed, never on an unrelated HAL notification — the structural fix for the multi-tap rebuild storm (every live tap shares one physical device, so one tap's own rebuild could otherwise re-trigger every other tap's listener). A failed live read counts as "changed" (never suppresses a fire). |
| `AudioDiag` | Env-gated (`AIRPLAY_AUDIO_DIAG`) diagnostic logging + live-handle counters (`handleCreated`/`handleDestroyed`/`dumpLiveHandles`) for coreaudiod-side objects (process tap / aggregate device / IOProc) — a no-op when disabled, so it costs nothing on the hot audio path in production. Wired into `PerAppCaptureCoordinator`'s `CoreAudioProcessTap` as the reference integration. |
| `Telemetry` | Always-on structured JSON-lines decision log; never the render path. |
