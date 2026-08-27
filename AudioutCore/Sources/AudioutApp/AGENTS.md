# AudioutApp

## Purpose

The shipping executable target — a thin AppKit shell that boots the app and
wires the pieces together. It owns no model and no AirPlay logic of its own;
`AppDelegate` resolves a backend and hands the shared `GroupController` to
the one surface's screens. See [../../AGENTS.md](../../AGENTS.md) for
package layout, backends, and core types.

## Rules

- **This target only COMPOSES the one surface.** `AppSurfaceController`
  (AudioutPopoverUI) owns the window, screens, and click policy; behavior
  goes there, not here, since this target is invisible to the test suite —
  `clickAction(setupIsOpen:)` returns a decision the delegate just performs.
- **Every "open X" affordance leads to a screen, never a window.** Setup and
  About are the only surviving windows; a new `showWindow()` call means the
  cutover has been undone.
- **A hidden screen does no work.** Backend events fan out unconditionally,
  but `setHostVisible(_:)` (off `onVisibleScreenChange`) gates the rebuild —
  never force-build a screen just to deliver an event.
- **`.accessory` app, no main menu beyond File ▸ Close.** No Edit/Window
  menu, so any shortcut needs explicit wiring. `installMainMenu` wires ⌘W
  (`performClose:`, target `nil`) because AppKit won't synthesize it
  otherwise; target `nil` routes it to whichever window is key.
- **Backend is chosen once from `AIRPLAY_BACKEND`** (default `.native`;
  `mock` is opt-in). Everything downstream holds `OutputBackend`, never a
  concrete type.
- **Subscribe before `start()`, start exactly once.**
  `startBackendIfNeeded()` attaches `subscribeToBackendEvents()` before
  `backend.start()` — or the initial `deviceAdded` burst is missed — and
  guards a `backendStarted` flag against double-start.
- **First-run setup defers the backend (native only).** When
  `SetupModel.shouldPresentOnLaunch(settings:backendKind:)` is true,
  onboarding is presented instead of starting the backend, since Bonjour
  discovery would trigger the Local Network prompt before setup explains it.
- **Two testing knobs override real OS behavior:** `AIRPLAY_SETUP`
  (`skip`/`force`) overrides the first-run gate; `AIRPLAY_PERMISSIONS`
  (`granted`/`denied`) simulates the permission seams without touching real
  TCC — `granted` makes the flow believe capture is on but doesn't make the
  tap deliver real samples.
- **The System-Audio probe plays an audible tone** — copy around it must
  warn the user before they grant, since the tap's mute doesn't cover the
  playback path.
- **`scripts/make-app.sh` needs a stable Developer ID signature for
  repeatable permission testing** (ad-hoc signing re-pins TCC grants to the
  binary and loses them on rebuild), and must set permission strings with
  `plutil`, not `PlistBuddy` (which chokes on an apostrophe and exits 0
  anyway, silently shipping a bundle with no usage-string rationale).
- **`AppDelegate` alone enforces "excluded ⇒ un-routable."** Neither
  `ExcludedAppsController` nor `AppRoutingController` prunes the other, so
  `pruneRoutesForExcludedApps()` must run on launch and every
  excluded-apps change.
- **Mid-session grants are detected by events, never a timer.**
  `AppDelegate`'s one `PermissionStateObserver` is kicked from launch,
  wake, every routing action, and a menu-bar click. Routing actions must go
  through `NativeBackend.onRoutingAction`, not `GroupController` call sites
  directly (`activateGroup(id:)` inside `applyRouting()` would be missed).
- **A mid-session grant is only observed, never auto-resumed.** Launch and
  wake just keep the TCC latch current; the app starts empty and the user
  re-picks a destination to get audio flowing again.
- **No window restoration; every window sets `isRestorable = false`**, and
  `applicationSupportsSecureRestorableState` returns `true` to silence the
  macOS secure-coding warning — any new window must do the same.

## Map

| Type | Role |
|---|---|
| `AppDelegate` | Lifecycle owner: activation policy, backend, `GroupController`, the surface + its two screen providers, excluded-apps/routing precedence, first-run setup gate. |
| `StatusItemController` | The `NSStatusItem`; renders the volume-tracking symbol, forwards clicks. |
| (bootstrap) | `main.swift` — builds and retains `AppDelegate`, calls `NSApplicationMain`. |
| `scripts/make-app.sh` | Wraps the built binary into a signed `.app` with the three TCC/Bonjour Info.plist keys. |
