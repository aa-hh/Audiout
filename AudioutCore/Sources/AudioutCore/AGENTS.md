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
- The "Taking audio back" strip follows the helper's clock, not a macOS AirPlay session.
- A failure the user felt goes through `Telemetry.fail(category, event, local:, shared:)`; only `shared` leaves the Mac, so device ids and error text go in `local`.
- Long-form traps, dated decisions and the changelog: [AGENTS-HISTORY.md](AGENTS-HISTORY.md). Grep it before debugging anything here.

## Map

- `Device` → domain models, with `ConnectionState`, `ConnectionFailure`, `BackendEvent`.
- `OutputBackend` → the backend seam; `NativeBackend` and `MockBackend` implement it.
- `CaptureCoordinator` → whole-system capture, with `NativeCaptureCoordinator` and `AudioProcessResolver`.
- `PerAppCaptureCoordinator` → per-app capture and mix: `AppRouteMixer`, `LeveledAppInjector`.
- `DefaultOutputDeviceMonitor` → shared capture infrastructure, with `TapRebuildLifecycle`.
- `GroupController` → the routing brain, with `AppRoutingController` and `PhaseController`.
- `StructuralStateGate` → repaint gating: has selection or grouping moved since painting?
- `AppRouteStore` → persistence, beside `RoutingStore`, `GroupStore`, `AppSettings`, `DeviceEQStore`.
