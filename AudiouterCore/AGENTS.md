# AudiouterCore

## Purpose

This Swift package is the whole app: a UI-agnostic core library
(`AudiouterCore`) plus AppKit UI targets that link against it, and the
shipping menu-bar executable. Core must never import AppKit; UI must depend
on the model, never the reverse. `OutputBackend` is the only seam between them.

## Rules

- **Any window/panel `show*()` entry point must gate its actual on-screen
  presentation behind `HeadlessRuntime.isActive`** (`HeadlessRuntime.swift`).
  `swift test` and the harness/snapshot tools (`window-harness`,
  `window-snapshot`, `popover-harness`, `popover-snapshot`, `settings-snapshot`)
  hold a real WindowServer connection — an un-gated `makeKeyAndOrderFront`/
  `NSApp.activate`/`popover.show`/etc. in one of these code paths flashes a
  real, empty window on the developer's actual screen for the run's duration.
  `HeadlessRuntime.isActive` detects `swift test` automatically (checks whether
  `XCTest` is loaded into the process — reliable regardless of invocation, no
  env var needed); the 5 non-app executable tools each set
  `AIRPLAY_HEADLESS=1` at the very top of their own `run()`, before touching
  AppKit. Only gate the actual presentation call — keep layout/sizing/model
  work (`layoutSubtreeIfNeeded`, `setContentSize`, frame-origin math) running
  unconditionally, since headless assertions (structural tests, offscreen PNG
  renders via `bitmapImageRepForCachingDisplay`) depend on it and never need
  the window actually on screen. The real app (`AudiouterApp`) never sets the
  env var and isn't an XCTest process, so a live launch always shows its
  windows normally.
- **`Device.isSelected` means "currently in the backend's output set"
  (streaming now) — NOT membership in the UI's Selected Devices set**
  (`GroupController.selectedDeviceIDs`). The output set is exactly the Selected
  Devices' AirPlay members (or an active group's members); the local Mac is
  filtered out, so a passthrough-only selection reaches the backend as an EMPTY
  set. Row/menu state must come from `GroupController.isSpeakerSelected(_:)`,
  never `device.isSelected`. Redirect targets stay excluded from
  `selectedDeviceIDs`/`mainOutMemberIDs` so a redirect can't move the Main Out
  master or pollute group identity — group matching keys off `mainOutMemberIDs`,
  never the live output set. The volume-key mirror (`mirrorMemberIDs`) follows
  the same rule: it drives Main Out only, never a per-app redirect target — a
  redirect no longer opens its session through the whole-system output set (see
  below), so there's nothing left for the volume keys to unstick there, and each
  redirected app already has its own independent volume control.
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
- **Resolving a bundle ID for per-app capture or whole-system exclusion MUST
  resolve to the FULL set of Core Audio processes, not a single pid.** Multi-process
  browsers emit audio from child/helper processes whose pids differ from the main
  app, and Core Audio reports no bundle id for those children. Shortcutting to
  single-pid resolution misses the real audio source — the routed app becomes
  inaudible and its audio leaks into the system mix. Both coordinators inject
  `AudioProcessResolver` for this reason.
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
- **Every real (re)connect must reseed the engine volume from the Mac's current
  system level** (0% when unreadable): the engine's volume field is
  zero-initialized and 0 maps to ≈ −30 dB (silent), so a connect that pushes no
  volume streams INAUDIBLY until the first slider touch — the −30 dB trap. The one
  exception is `applyStartBuffer`'s internal teardown/re-add (a buffer-size change,
  *not* a reconnect), which preserves the in-session level instead. That is why the
  seed is gated on `bufferReAdding`, not fired unconditionally in the shared add
  path — remove the gate and a plain buffer change resets the user's level to the
  system volume. The seed (`connectVolumeSeed`) is reachable from TWO independent
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
  `onDeviceRateRebuild` (fired only from `recreateTap(cause: .deviceOrRateChange)`,
  NEVER on the first `start()` and NEVER for a benign `.exclusionChange` rebuild);
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
  Saved groups still persist and re-apply.
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
- **The full pre-commit run is `swift test --parallel --num-workers 4`**
  (capped to 4 concurrent test processes to keep CPU/fan load reasonable on
  an 8-core machine; ~70s warm vs ~124s for a bare serial `swift test`, only
  marginally slower than an uncapped `--parallel`). It parallelizes at the
  test-CLASS level: each suite runs in its own process, so tests must not
  race on cross-process shared state.
- **Coverage gate (the one enforcement that matters):** `.githooks/pre-commit`
  Guard 4 runs the full `swift test --parallel --num-workers 4` whenever a commit's staged
  files touch AudiouterCore Swift sources/tests, and blocks the commit if it
  fails. So a too-narrow filter in the loop can never ship a regression — it
  only costs one extra fix cycle at commit. Everything that reaches `main` was
  committed through this gate, so `main` stays green. Filtering in the loop is
  a convention (this doc), not machine-enforced; `--no-verify` skips the gate
  for a deliberate emergency.
- **Isolate shared state via `IsolatedTestCase`.** Because `--parallel` gives
  each suite its own process, two suites that both write `UserDefaults.standard`
  or the same `FileManager.default.temporaryDirectory` path race and flake.
  Subclass `IsolatedTestCase` (`Tests/AudiouterCoreTests/IsolatedTestCase.swift`)
  and use `scratchDir` (per-test temp dir), `isolatedDefaults` (per-test suite),
  or `uniqueName(_:)` (for APIs like `NSWindow.setFrameAutosaveName` that always
  write `.standard`) instead of the shared globals. `.githooks/pre-commit`
  Guard 3 warns when a newly added test line reaches those globals; a line that
  genuinely must touch one takes a trailing `isolation-ok` comment.
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
  barrier) before the test returns so it never bleeds into the next test method
  in the same process.

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
| `NativeBackend` | Shipping backend; drives `AirPlayEngine`, owns capture gate. |
| `NativeDiscovery` | Bonjour discovery (AP2 + AP1). |
| `NativeCaptureCoordinator` | Whole-system Core Audio capture; excludes individually-routed + user-excluded apps. |
| `PerAppCaptureCoordinator` | Per-process Core Audio capture taps, one per individually-routed app. |
| `AudioProcessResolver` / `AudioProcessEnumerating` | Bundle ID → ALL its Core Audio process objects (main + nil-bundle-id children, via parent-pid walk); AppKit pid→bundle lookup is injected. |
| `AppRouteMixer` | Combines per-app captures into per-destination mixed streams; applies per-app volume. |
| `SystemOutputVolume` | Reads/writes the Mac's output volume/mute. |
| `makeBackend(_:)` | The one factory that knows concrete backend types. |
| `SetupModel` | Brain of the first-run permission-priming flow (AppKit-free): per-permission `PermissionStatus`, PTP helper `PTPHelperStatus`, runs the injected probes, persists `AppSettings.hasCompletedSetup`, gates auto-present via `shouldPresentOnLaunch(settings:backendKind:)` (native only). UI = `AudiouterOnboardingUI`. |
| `AudioCapturePermissionProbing` / `CoreAudioTonePermissionProbe` | Seam + impl that BOTH triggers and verifies the system-audio grant — a denied tap returns `noErr`+zeros, so it plays a muted in-process tone, taps our OWN process, and reads RMS. **Gated on live TCC verify** (`dev/notes/onboarding-setup-brief.md`). |
| `LocalNetworkPriming` / `LocalNetworkPrimer` | Seam + impl: a brief `NWBrowser` for `_airplay._tcp` that fires the Local Network prompt (no verify API exists — TN3179). |
| `RemoteControlPriming` / `RemoteControlPrimer` | Seam + impl: `AXIsProcessTrustedWithOptions` fires the Accessibility prompt. Primed AHEAD of the feature that needs it (speaker-side transport controls simulating Mac media keys — not yet merged; the branch name once cited here, `claude/speaker-input-responsiveness-b8123f`, does NOT hold this work — its tip is an old already-merged checkpoint with zero unique commits, see `docs/plans/phase-3-findings/branch-inventory.md`); same `.requested`-only honesty rule as Local Network even though `AXIsProcessTrusted()` is a real status API, because macOS doesn't reliably push a live grant back to an already-running process. |
| `PTPHelperManaging` / `SMAppServicePTPHelper` | Seam + impl (T6) over `SMAppService.daemon(plistName:)` for the privileged PTP helper daemon (`AirPlayEngine/docs/ptp-helper-design.md`); `register()` is idempotent and prompt-free, `.status` maps to `PTPHelperStatus`. Real `.enabled` is Developer-ID-signing-gated — unit-tested only via the injected fake. |
| `SystemSettingsPane` | `x-apple.systempreferences:` deep links the onboarding flow opens on denial. |
| `Telemetry` | Always-on structured JSON-lines decision log; never the render path. |
