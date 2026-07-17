# AirPlayControllerCore

## Purpose

This Swift package is the whole app: a UI-agnostic core library
(`AirPlayControllerCore`) plus AppKit UI targets that link against it, and the
shipping menu-bar executable. Core must never import AppKit; UI must depend
on the model, never the reverse. `OutputBackend` is the only seam between them.

## Rules

- **`Device.isSelected` means "currently in the backend's output set"
  (streaming now) — NOT membership in the UI's Selected Devices set**
  (`GroupController.selectedDeviceIDs`). The set is Selected ∪ app-route
  redirect targets, so a redirect-only device reports `isSelected == true`
  while in nobody's Selected Devices set. Row/menu state must come from
  `GroupController.isSpeakerSelected(_:)`, never `device.isSelected`. Redirect
  targets stay excluded from `selectedDeviceIDs`/`mainOutMemberIDs` so a
  redirect can't move the Main Out master or pollute group identity — group
  matching keys off `mainOutMemberIDs`, never the live output set.
- **An AirPlay session opens the moment an app is redirected, even with no
  device selected.** Per-app capture doesn't exist yet, so the capture tap
  (gated on `expectedSelected` inside the backend, not `isPassthrough` or the
  UI) is a whole-system mixdown: redirecting ONE app streams the WHOLE system
  mix to that device and mutes the Mac. Known limitation — don't narrow the
  gate to fix it; the fix is per-app capture streams.
- The live routing set is not auto-resumed at launch (`RoutingStore` is
  write-only at launch) — a previously-selected device never auto-streams.
  Saved groups still persist and re-apply.
- `NativeBackend` has no `ConnectionDiagnosing` seam — `.failed` cause is
  always `.unknown`. `MockBackend` mutation stays no-op-silent and confined
  to its private serial queue.

## Map

| Type | Role |
|---|---|
| `Device` | Value-type snapshot of one output; backend is the only writer. |
| `ConnectionState` / `ConnectionFailure` | Per-device connection lifecycle + failure cause. |
| `ConnectionDiagnosing` | "Why didn't it connect" seam; `OwnToneBackend`-only. |
| `GroupController` | Routing brain: Selected Devices, Main Out, groups, redirect union. |
| `AppRoutingController` | Per-app routing state/destinations. |
| `AppRouteStore` / `RoutingStore` / `GroupStore` | Versioned-JSON persistence. |
| `BackendEvent` | Backend→UI push channel: add/remove/update/level/volume-changed. |
| `OutputBackend` | The protocol seam between app and audio routing. |
| `MockBackend` | Fully-working offline backend for tests/demos. |
| `OwnToneBackend` | HTTP-polling backend against OwnTone; superseded. |
| `NativeBackend` | Shipping backend; drives `AirPlayEngine`, owns capture gate. |
| `NativeDiscovery` | Bonjour discovery (AP2 + AP1). |
| `NativeCaptureCoordinator` | In-process Core Audio capture pipeline. |
| `SystemOutputVolume` | Reads/writes the Mac's output volume/mute. |
| `makeBackend(_:)` | The one factory that knows concrete backend types. |
