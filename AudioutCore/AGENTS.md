# AudioutCore

## Purpose

This Swift package is the whole app: a UI-agnostic core library
(`AudioutCore`) plus AppKit UI targets that link against it, and the
shipping menu-bar executable. Core must never import AppKit; UI must depend
on the model, never the reverse. `OutputBackend` is the only seam between them.

## Rules

- `NativeDiscovery` drops any resolved AirPlay service whose hostname matches this Mac's own (`systemLocalHostname()`) before identity extraction — otherwise the Mac's own AirPlay Receiver appears as a phantom speaker to itself. Fails OPEN (keeps the row) when the hostname is unavailable, since a missing real speaker is worse than a phantom one.
- An engine auth rejection must always map to `ConnectionFailure.Cause.authRequired`, never `.unknown` — both call sites (`applyEngineState`, `convergeDevice`'s add-throw) do this so the error copy names the actual fix (receiver's access-control mode).
- Any window/panel `show*()` must gate its actual presentation call behind `HeadlessRuntime.isActive` — tests and snapshot tools hold a real WindowServer connection, so an un-gated `makeKeyAndOrderFront`/`activate`/`popover.show` flashes a real window on the developer's screen (or wedges an unattended machine). Only gate the presentation call, not layout/sizing work headless assertions depend on. No test may cause a real `orderFront`/`popUp`/`runModal`/`NSApp.activate` to execute — presenters sit behind `HeadlessRuntime.isActive` or expose a `test_*` seam returning the built object unpresented; drawing into an ordered-OUT window's backing store is fine.
- `Device.isSelected` means "in the backend's live output set," not UI membership — always read `GroupController.isSpeakerSelected(_:)` for row/menu state, never `device.isSelected` directly. Redirect targets are excluded from `selectedDeviceIDs`/`mainOutMemberIDs` so a redirect can't hijack Main Out or group identity.
- A redirected app streams via the per-app capture path (`AppRoutingController` → `NativeBackend.updateAppRoutes`), never through `setOutputSet` — the whole-system tap excludes redirect targets via `expectedSelected`.
- Whole-system routing always wins a contested device in `NativeBackend`; the per-app route demotes to effective-`.noRedirect` and is re-driven only by its own bow-out's release, never proactively by a later whole-system change (deliberate). TRAP: a `bindTail` op must never wait on the `converging` slot (deadlocks the FIFO — bow-out+re-drive is the only safe shape). TRAP: an `.unbind` under a whole-system claim must go through `performBindOp`'s four-case arm, not be simplified to always-run or always-skip — either extreme kills a live session or leaks a zombie one.
- The whole-system tap's `.failed` retries via capped-exponential backoff (`scheduleCaptureRetry`), and re-checks `captureRunning` at fire time — a deselect during backoff must not restart the tap and mute the Mac with nowhere for the audio to go.
- Resolving a bundle ID for capture/exclusion must resolve ALL its Core Audio processes via `AudioProcessResolver`'s four attribution layers as an ANY-of union, never first-match-wins — a helper process can defeat any single layer (e.g. reporting its own bundle id while reparented to launchd). Collapsing to one "effective bundle id" reopens an exception leak. `resolveWithAttribution` logs which layer matched, for diagnosing a bundle resolving to zero processes.
- `AppRouteDestination` has three cases, not two — `.noRedirect` and `.currentDevice` are engine-equivalent (both play locally) and differ only in UI state. Use `.isDeviceRoute` to test "actually routed away," never a negative match on `.currentDevice`.
- `.currentDevice` playback follows the Mac's real default output, but refuses to follow an AirPlay/virtual/aggregate default (that's exactly what whole-system capture may be streaming into — following it loops back). Falls back to built-in speakers if no safe default exists.
- Every real (re)connect must reseed engine volume from `connectVolumeProvider()` — the engine's volume field is zero-initialized (≈−30dB, inaudible). The seed fires only on the `added` false→true edge (not unconditionally), so `applyStartBuffer`'s buffer-resize teardown/re-add preserves the user's live level instead of resetting it. `pushVolume` serializes per output id — two concurrent `engine.setVolume` calls for one device corrupts the vendored dispatcher's single in-flight callback.
- A device's `.level` is the max of its whole-system-tap level and the loudest pre-volume app routed to it; every meter reads pre-volume/pre-routing so a low slider never empties a bar. A user-excluded app is never metered (metering-only taps are separate from routing taps and never start/stop them).
- A device/rate-change tap rebuild must reset the whole-system AirPlay session (`onDeviceRateRebuild`) or every speaker goes permanently silent; an exclusion-only rebuild must NOT reset (adds a redundant re-establish on every connect). TRAP: the rebuild cause alone isn't reliable evidence — `recreateTap` also compares the outgoing/incoming tap's actual device id and rate and resets on a real device move even when the cause was `.exclusionChange`.
- The silence fallback uses its own always-on ~10s delay for normal operation, decoupled from the user's `wakeAudioRestoreDelay` (which only applies during the post-wake window) — a "Never" wake setting can't disable it during normal playback.
- The live routing set never auto-resumes at launch (`RoutingStore` is write-only there); saved groups still re-apply. `AppRoutingController.clearAllRedirectsAtLaunch()` reverts every per-app redirect the same way, once, before the initial route push.
- A per-app `.device` route survives its target going merely unreachable, but resets only when the target disappears entirely (`handleDeviceDisappeared`). While unreachable, `NativeBackend` computes an effective route table treating it as `.noRedirect` for every mechanism — the user's real route table is untouched and re-engages automatically when the device returns.
- A saved group containing the local Mac must arm the synced-local sink via `GroupController.isMainOutMember(_:)`, never `isSpeakerSelected(_:)` — the latter is blind to group membership and is wrong in both directions under a group target.
- `SyncCore.swift` and `DeviceEQ.swift`/`EQProcessor.swift` carry no GPL header on purpose (Bluetooth sink reuse) — never add one or move GPL-derived code in.
- A trim, latency, or per-device EQ change must never rebuild a sink — it's a linear-term move (read-position seek / property swap via `BTDeviceSink.setEQ`, `applyTrimDelta`, `setOffsetMs`/`setTrimMs`, `SyncedLocalSink.applyUserOffsetDelta`), never a session teardown, or the release gate re-arms and the speaker goes silent for the full delay. Never call `clearSessionState(Locked)` on a seek — it's not a new session. Real rebuilds (`config_change`/`rate_change`/`composition_change`/`wizard_feed`) are the only exception.
- A flat EQ must stay byte-identical passthrough — never route it through `EQProcessor` (requantizing isn't bit-exact); `DeviceEQStore` drops flat entries on save by design.
- An EQ rebind is a whole-system engine op riding the per-device `converging` slot (`EQStreamAllocator` ids start at `0x8000_0000`, never colliding with `AppRouteMixer`'s 1-based range). `reconcileEQPlan` owns all `added` edges via `removeFromAddedLocked`; `pushEQPlanLocked` never rebuilds a live stage — an edited stage is `retarget`ed in place to avoid an audible tick/crackle.
- A device claimed by per-app routing is excluded from the EQ domain with its own `eqBypassReason` (`.perAppRouting`, distinct from `.streamBudget`) — its audio never reaches the whole-system EQ stage.
- `DefaultOutputDeviceMonitor` is the sole owner/watcher of default-output-device changes — everything else observes it, never watches CoreAudio directly.
- `TapRebuildLifecycle` is deliberately NOT merged into `NativeBackend` (see `docs/notes/architecture-review-audio-routing-2026-07-26.md`) — don't fold it in.
- Never touch IOBluetooth outside `BTDeviceEnumerator`'s `CBManager.authorization` gate — an ungranted call SIGABRTs the process on macOS 27, no prompt.
- Bluetooth/Cast ids never reach the AirPlay engine — excluded via `isBluetooth`/`isCast` guards, never `supportsAirPlay2` (AP1 receivers share that flag but ARE engine-driven).
- A BT row's `.connected` means its own delay gate opened (`hasStartedRendering`), not a live engine session; a lost pairing fails fast as `.notPaired` and must never be auto-purged (re-pairing resurrects the same id).
- A Bluetooth sink held at gain 0 (the first-mix alignment intercept) must always have a live release path — never add a mute that can strand a speaker silently. All gain writes go through one composed product (`NativeBackend.btSinkGain`, `Main × Group × Device`) so user volume and an alignment hold can never fight over the knob.
- `TCCAccessPreflight` is cached for the process's whole lifetime and the Darwin change notification does NOT refresh it — the freshly-spawned `tcc-probe` helper is the only reader immune to the stale cache; only `.resolved(.granted)` may latch a fresh grant.
- A refused capture strands both whole-system and per-app paths with nothing auto-reviving them mid-session (deliberate — auto-resume was removed). A fresh launch after granting is the only recovery path; don't reintroduce mid-session resume without revisiting that decision.
- A native `.failed` cause is mapped from real engine evidence (`.authRequired`/`.timedOut`/`.droppedMidStream`/`.vanished`/`.timingUnavailable`); anything else stays `.unknown` rather than guessing — a plausible-but-wrong cause is worse than a vague one.
- UI targets carry `STABILITY(id)` inline markers — see [../dev/notes/stability-audit-2026-07-18.md](../dev/notes/stability-audit-2026-07-18.md) before touching a marked region.
- `Group.iconSymbolName` is optional; `nil` means "use the default" and must decode cleanly from any pre-existing persisted group. Resolution/fallback lives in `AudioutSharedUI.DeviceIcon`, not here.
- In UI targets, always write `NSApp?.`, never bare `NSApp.` — `NSApp` is an implicitly-unwrapped optional and no test starts a real `NSApplication`, so a bare `NSApp.` traps with a force-unwrap crash in any test process that hasn't incidentally initialized one.
- Always use `scripts/run-tests.sh`/`scripts/build.sh`, never the bare swift commands — they apply a machine-wide concurrency cap (`AUDIOUT_TEST_SLOTS`, default 2, shared across worktrees) and a content-addressed pass cache. Scope inner-loop runs with `--filter <Suite>`.
- `AUDIOUT_TEST_MODE=auto|parallel|serial` picks parallel when the machine is idle, serial when contended (auto-detected via `pgrep`) — parallel forks one process per test method, fast idle but CPU-heavy under load.
- Remote Mac (opt-in): configure via `git config --local audiout.remoteHost`/`audiout.testPrefer` (not env vars — hooks run non-interactively and won't see shell exports). Governs builds too (`scripts/lib/remote.sh`). A remote PASS is accepted; a remote FAILURE is re-run locally before it blocks anything (toolchain skew can look like a code bug).
- `make-app.sh` moves only the compile remotely — codesigning, dylib bundling, and the final `.app` are always local (keychain unlock for non-interactive codesign isn't set up; bundled Homebrew dylibs are machine-specific). `AUDIOUT_BUILD_LOCAL=1` forces local.
- Guard 4 runs the full suite at commit time and blocks on failure — filtering in the inner loop is safe because this gate catches anything a narrow filter missed.
- Real-hardware playback tests are opt-in via `AIRPLAY_AUDIO_HARDWARE_TESTS=1` — they exercise the actual `AVAudioEngine` against the Mac's real output and are timing-sensitive on a busy machine. Every hardware test must live inside `LocalPlaybackEngineTests.RealHardware` (the one gated `@Suite`) to inherit the skip automatically.
- Inherit `IsolatedSuite` (new/converted) or `IsolatedTestCase` (legacy) in any test touching `UserDefaults.standard` or shared temp dirs — two tests writing the same global race under swift-testing's in-process concurrency, not just under `--parallel`.
- Never call `UserDefaults(suiteName:)` in a test (Guard 3 flags it) — each name leaves a real `~/Library/Preferences/<name>.plist` that no test-side cleanup can delete (`cfprefsd` rewrites it after removal). Use the isolation bases' memory-backed stores instead.
- `Telemetry.log` is always-on (gated only by `HeadlessRuntime.isActive`) and must never call back into a caller or run on the audio render thread. Use `_installTestSink(_:)` to assert a subsystem's own emissions; suites doing so must nest into `SerializedSharedStateSuite` since the sink is process-global state under concurrent tests.

## Map

| Type | Role |
|---|---|
| `Device` | Value-type snapshot of one output; backend is the only writer. |
| `ConnectionState` / `ConnectionFailure` | Per-device connection lifecycle + failure cause. |
| `ConnectionDiagnosing` | "Why didn't it connect" seam; `OwnToneBackend`-only. |
| `GroupController` | Routing brain: Selected Devices, Main Out, groups. |
| `AppRoutingController` | Per-app routing state/destinations; `onRoutesDidChange` is the table-changed signal the backend wires to. |
| `AppRouteConfiguring` | Optional backend capability: `updateAppRoutes` streams a routed app to its device; `NativeBackend` only. |
| `AppRouteStore` / `RoutingStore` / `GroupStore` | Versioned-JSON persistence. |
| `DeviceIconStore` | Persists per-device icon overrides (bare SF Symbol name strings only) for `AudioutSharedUI.DeviceIconController`. |
| `BackendEvent` | Backend→UI push channel: add/remove/update/level/app-level/volume-changed/routedApps. |
| `OutputBackend` | The protocol seam between app and audio routing. |
| `MockBackend` | Fully-working offline backend for tests/demos. |
| `OwnToneBackend` | HTTP-polling backend against OwnTone; superseded. |
| `NativeBackend` | Shipping backend; drives `AirPlayEngine`, owns capture gate, owns aggregate device lifecycle. |
| `AggregateOutputDevice` | Lifecycle owner for the public "Audiout" aggregate device; becomes Mac default when routing arms. |
| `NativeDiscovery` | Bonjour discovery (AP2 + AP1). |
| `CastSender` | Hand-rolled Google Cast v2 sender: browse, control channel, live WAV server; driven by `CastOutputManager`. |
| `CastOutputManager` | Per-Cast-device session recipe (connect→launch→LOAD→PLAY); composed level; feeds each receiver from `CastFeedRing`. |
| `CastDeviceEnumerator` | `_googlecast._tcp` browse → `.cast` rows through the same `known`/`order`/`emit` flow as Bluetooth. |
| `PCMDelayLine` | Cadence-preserving S16LE delay line for multi-output sync. |
| `CastFakeReceiver` | In-memory mock Cast receiver for testing (macOS 15+ only). |
| `cast-spike` | Standalone CLI tool proving end-to-end Cast audio streaming. |
| `BTDeviceEnumerator` | Bluetooth outputs: merges Core Audio BT transport with the TCC-gated IOBluetooth paired list; unpaired rows filtered. |
| `BTSyncedSink` | N-instance BT sink manager: per-device delay lines, reference-timeline sync, release-gate catch-up. |
| `BTSyncTrim` / `BTTrimStore` | Per-device BT trim clamp/persistence (±500 ms); `NativeBackend` re-pushes into the sink on every arm. |
| `AlignmentTickInjector` | Align-by-ear tick generator mixed pre-fan-out; keep-alive tone prevents BT amp power-gating. |
| `BTAlignmentPosterior` | Bayesian posterior estimator for the alignment wizard's per-ms latency offset. |
| `BTAlignmentWizardSession` | Drives one alignment-wizard run for one device; owns trim commit/restore and tick lifecycle. |
| `NativeCaptureCoordinator` | Whole-system Core Audio capture; excludes individually-routed + user-excluded apps. |
| `PerAppCaptureCoordinator` | Per-process Core Audio capture taps, one per individually-routed app. |
| `AudioProcessResolver` / `AudioProcessEnumerating` | Bundle ID → all its Core Audio processes via four ANY-of attribution layers, each tagged for `Telemetry`. |
| `AppRouteMixer` | Combines per-app captures into per-destination mixed streams; applies per-app volume. |
| `SystemOutputVolume` | Reads/writes the Mac's output volume/mute. |
| `makeBackend(_:)` | The one factory that knows concrete backend types. |
| `SetupModel` | Brain of first-run permission-priming flow: per-permission status, PTP helper status, native-only auto-present gate. |
| `SystemAudioCaptureTCC` | Silent three-valued system-audio TCC read across both buckets, plus the one-way fresh-verdict latch every capture gate reads through. |
| `TCCProbeRunner` | Async, single-flighted launcher for the bundled `tcc-probe` helper — the only reader immune to this process's permanently-cached TCC read. |
| `PermissionStateObserver` | Event-driven (zero-timer) detector for the grant arriving mid-session: Darwin/launch/wake/routing/popover triggers. |
| `AudioCapturePermissionProbing` / `CoreAudioTonePermissionProbe` | Seam + impl triggering and verifying the system-audio grant via a muted tone + RMS read. |
| `LocalNetworkPriming` / `LocalNetworkPrimer` | Seam + impl proving the Local Network grant via self-publish/browse since there's no status API. |
| `RemoteControlPriming` / `RemoteControlPrimer` | Seam + impl: `AXIsProcessTrustedWithOptions` fires the Accessibility prompt, primed ahead of the feature needing it. |
| `PTPHelperManaging` / `SMAppServicePTPHelper` | Seam + impl over `SMAppService.daemon` for the privileged PTP helper daemon; `.enabled` is signing-gated. |
| `SystemSettingsPane` | `x-apple.systempreferences:` deep links the onboarding flow opens on denial. |
| `TapRebuildDecision` | Pure compare-before-rebuild guard: fires a tap rebuild only when its pinned device/rate actually changed. |
| `AudioDiag` | Env-gated (`AIRPLAY_AUDIO_DIAG`) diagnostic logging + live-handle counters for coreaudiod-side objects; no-op when disabled. |
| `Telemetry` | Always-on structured JSON-lines decision log; never the render path. |
| `Analytics` | Opt-in anonymous usage-analytics facade; sink installed by the app target. |
