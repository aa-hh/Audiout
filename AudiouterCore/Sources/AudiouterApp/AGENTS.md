# AudiouterApp

## Purpose

The shipping executable target — a thin AppKit shell that boots the app and
wires the pieces together. It owns no model and no AirPlay logic of its own;
`AppDelegate` resolves a backend, builds the shared `GroupController`, and
hands it to the popover and mixer window so they never diverge. For the
package layout, backends, and core types, see
[../../AGENTS.md](../../AGENTS.md).

## Rules

- **No main menu.** The app is `.accessory` with no `NSMenu` ever assigned —
  no Edit/Window menu to host standard keyboard commands. Any shortcut this
  app needs must be wired explicitly; any action with no keyboard path needs
  a visible on-screen affordance.
- **Backend is chosen once, from the environment.** `makeBackend()` reads
  `AIRPLAY_BACKEND` (default `.mock`); the mock also reads
  `AIRPLAY_MOCK_SCENARIO`. Everything downstream holds `OutputBackend`, never
  a concrete type — run offline with `AIRPLAY_BACKEND=mock`.
- **Subscribe before `start()`.** `subscribeToBackendEvents()` must attach
  before `backend.start()` runs, or the initial `deviceAdded` burst is
  silently missed.
- **`AppDelegate` alone enforces "excluded ⇒ un-routable."** Neither
  `ExcludedAppsController` nor `AppRoutingController` prunes the other —
  `pruneRoutesForExcludedApps()` must run on launch and on every
  excluded-apps change, or a route can outlive its app's exclusion.
- **The audio-capture usage string must be set with `plutil`, not
  `PlistBuddy`**, in `scripts/make-app.sh`. `PlistBuddy` chokes on the
  apostrophe in the prose and exits 0 anyway, silently shipping a bundle with
  no permission rationale.
- **One shared control-panel shell, behind `AIRPLAY_CONTROL_PANEL=1`.** When
  the flag is set, config surfaces open in the single `controlPanel`
  (`ControlPanelWindowController`, `AudiouterSharedUI`) instead of standalone
  windows: `presentInControlPanel(content:title:surface:)` creates the shell
  and wires its land-home `onClose` (→ `showPopoverHome`) EXACTLY once, then
  swaps content (`setContent`) on later opens — never a second panel.
  `openGroupsPanel` builds/reuses the `MixerWindowController` with plain WINDOW
  chrome and hands the shell its `contentController`; `openSettings` builds/
  reuses `SettingsWindowController` the same way and hands the shell its
  `settingsContentViewController` (`AudiouterSettingsUI`). `activePanelSurface`
  records what's showing — opening the other surface REPLACES the current
  content in the same shell via `setContent`, never a second panel. A
  status-item click during a live session (`controlPanelSessionActive`)
  re-summons `controlPanel` in place regardless of surface; a real close lands
  home on the popover. The flag defaults off, so the shipping window paths
  (`openMixer`, `openSettings`'s `showWindow()`) are untouched.

## Map

| Type | Role |
|---|---|
| `AppDelegate` | Lifecycle owner: activation policy, backend, `GroupController`, popover + mixer window, the shared control-panel shell (`AIRPLAY_CONTROL_PANEL=1`), excluded-apps/routing precedence. |
| `StatusItemController` | The `NSStatusItem`; renders the volume-tracking symbol, forwards clicks. |
| (bootstrap) | `main.swift` — builds and retains `AppDelegate`, calls `NSApplicationMain`. |
| `scripts/make-app.sh` | Wraps the built binary into a signed `.app` with the TCC usage string. |
