# AudioutCore/Sources/AudioutCore

## Purpose

The `AudioutCore` library source: discovery, output backends, capture, the
routing brain, local playback, persistence, and the setup flow. It owns
everything up to the `OutputBackend` seam and never imports AppKit.

## Rules

- `SyncCore.swift` is LICENSE-CLEAN: never add a GPL header, never move GPL-derived code in.
- A trim or measured latency change moves the sink's read position; a rebuild silences a live scrub.
- A flat EQ must stay byte-identical passthrough: never route a flat buffer through `EQProcessor`.
- An EQ rebind goes through `bindOutput` and claims the device's converging slot, never a naked rebind.
- `reconcileEQPlan` owns both added edges; an edited stage is retargeted in place, because a fresh processor crackles.
- A device the per-app domain claims leaves the EQ domain, and says so through `eqBypassReason`.
- A Bluetooth trim is a ring seek and must never clear session state: the anchor and ring survive.
- A Bluetooth EQ change bakes a new processor on `graphQueue`, never re-parameterizing a live one.
- The PTP activation wait must strictly exceed the helper's bind-retry budget, or a late success goes unseen.
- A PTP `register()` throw is first-run normal; only `.notFound` after it is a fault.
- The "Taking audio back" strip follows the helper's clock, not a macOS AirPlay session.
- A failure the user felt goes through `Telemetry.fail(category, event, local:, shared:)`; only `shared` leaves the Mac, so device ids and error text go in `local`. Ordinary `Telemetry.log` lines never leave the Mac at all (owner's ruling 2026-09-10: the every-line forward leaked bundle ids and speaker names).
- Both capture taps keep `kAudioAggregateDeviceTapAutoStartKey`: they sleep until an app plays, on purpose. A speaker session that would starve is fed silence by the sender shim (AirPlayEngine, shims/outputs.c), never by keeping a tap awake; a receiver closes a session that goes ~30 s without packets.
- The sender's own log is `engine.log` beside `telemetry.jsonl`, set once where the engine is built; when a session "connected" but went silent, read `stream_health`'s `silent_s` first, then both files.
- A drift correction writes the MEASURED LATENCY, never the trim: the drift baselines are `room + trim`, so a corrected trim would move the baseline with the speaker and the next window would read the correction back as fresh error. It records no alignment either — nobody confirmed it — and marks the stored calibration stale instead.
- A drift baseline exists only for a speaker with a MEASURED latency, and drift tracking runs only with two such speakers or one plus an anchor: `room + trim` presumes the latency the sink subtracts, and a lone speaker's moved peak is equally the microphone's. A slew step never moves the BT-only reference floor — only the committed write that ends it does, because a floor move rebuilds every sink.
- An AirPlay or Cast arrival in a `PassiveDriftSampler` window is read-only: those receivers run on the room reference clock, so a peak off baseline measures the MIC, never that speaker.
- Long-form traps, dated decisions and the changelog: [AGENTS-HISTORY.md](AGENTS-HISTORY.md). Grep it first.

## Map

- `Device` → domain models, with `ConnectionState`, `ConnectionFailure`, `BackendEvent`.
- `OutputBackend` → the backend seam; `NativeBackend` and `MockBackend` implement it.
- `CaptureCoordinator` → whole-system capture, with `NativeCaptureCoordinator` and `AudioProcessResolver`.
- `PerAppCaptureCoordinator` → per-app capture and mix: `AppRouteMixer`, `LeveledAppInjector`.
- `DefaultOutputDeviceMonitor` → shared capture infrastructure, with `TapRebuildLifecycle`.
- `GroupController` → the routing brain, with `AppRoutingController` and `PhaseController`.
- `StructuralStateGate` → repaint gating: has selection or grouping moved since painting?
- `AppRouteStore` → persistence, beside `RoutingStore`, `GroupStore`, `AppSettings`, `DeviceEQStore`.
