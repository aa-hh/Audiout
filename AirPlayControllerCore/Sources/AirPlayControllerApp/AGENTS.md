# AirPlayControllerApp

## Purpose

The shipping executable target (`AirPlayControllerApp`) — the thin AppKit shell that boots the app and wires the pieces together. It's a menu-bar-only accessory (`NSStatusItem`, no Dock icon): `main.swift` builds the `AppDelegate`, which selects an `OutputBackend`, creates the shared `GroupController`, hosts the Control-Center-style popover (`../AirPlayControllerPopoverUI/`), and lazily opens the full mixer window (`../AirPlayControllerWindowUI/`). All device state flows one-way from the backend's event stream into `AppDelegate`. For the package it lives in (module layout, backends, core types), see [../../AGENTS.md](../../AGENTS.md).

Keep up to date when: the entry-point/bootstrap changes, the backend-selection env vars change, the status-item behavior changes, or `scripts/make-app.sh` packaging changes.

## Notable Patterns

**Backend selection via environment (read this to run offline).** `AppDelegate.backend` is resolved once at construction by `makeBackend()` (defined in the core module — see [../../AGENTS.md](../../AGENTS.md)): explicit arg (none here) → the `AIRPLAY_BACKEND` env var → default `.mock`. The mock backend additionally reads `AIRPLAY_MOCK_SCENARIO` to pick which fake fleet/behavior it emits (e.g. `connection-demo`). Everything downstream holds the `OutputBackend` protocol, never a concrete type, so swapping backends needs no app-shell changes. To run without real speakers, launch with `AIRPLAY_BACKEND=mock` (the default) and optionally `AIRPLAY_MOCK_SCENARIO=connection-demo`.

**One-way event flow.** `subscribeToBackendEvents()` subscribes to `backend.makeEventStream()` *before* `backend.start()` (so the initial `deviceAdded` burst isn't missed). Each `BackendEvent` is folded into `devicesByID` on the main actor by `apply(_:)`, which then calls `groupController.ensureDefaultSelection()` and pushes the device snapshot into the popover, status symbol, and (if open) mixer window. `.level` meter events are ignored (Phase 1). The `eventTask` is cancelled in `applicationWillTerminate`.

**Accessory activation, belt-and-suspenders.** `applicationWillFinishLaunching` sets `.accessory` in code, *and* `make-app.sh` sets `LSUIElement=true` in the bundle — so no Dock icon ever flickers. `main.swift` retains the delegate via `objc_setAssociatedObject` (NSApplication holds its delegate weakly), then calls `NSApplicationMain`.

**Status symbol tracks volume.** `StatusItemController` uses the `speaker.wave.3.fill` SF Symbol with a `variableValue` bound to the master volume; changing the level re-renders the (template) image. Only `.button` is customized. The button's action toggles the popover via the `onButtonClicked` closure.

## Key Types

| Type | File | Role |
|------|------|------|
| `AppDelegate` | `AppDelegate.swift` | App lifecycle: activation policy, backend selection, event-stream consumer holding `devicesByID`, owns popover + mixer window. |
| `StatusItemController` | `StatusItemController.swift` | The menu-bar `NSStatusItem`; renders the volume symbol, forwards clicks via `onButtonClicked`. |
| (bootstrap) | `main.swift` | Top-level entry: builds & retains `AppDelegate`, calls `NSApplicationMain`. |

## Packaging (`scripts/make-app.sh`)

The target ships as a SwiftPM executable, not an Xcode project. Run [scripts/make-app.sh](../../../scripts/make-app.sh) `[output-dir]` (default `./build`) to produce **"AirPlay Controller.app"**. It:

1. `swift build -c release --product AirPlayControllerApp` against `AirPlayControllerCore/`.
2. Assembles `Contents/MacOS/` with the built binary.
3. Writes `Info.plist` via `PlistBuddy`: bundle id `com.alechenderson.AirPlayController`, `LSUIElement=true` (menu-bar-only), min macOS `13.0`, `NSHighResolutionCapable`.
4. Ad-hoc codesigns (`codesign --sign -`) so Gatekeeper allows local launch (no Developer ID; real signing + notarization is Phase 2).
