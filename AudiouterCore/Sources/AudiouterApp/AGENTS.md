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
- **Subscribe before `start()`, and start exactly once.** All backend startup
  goes through `startBackendIfNeeded()`, which attaches
  `subscribeToBackendEvents()` before `backend.start()` (or the initial
  `deviceAdded` burst is silently missed) and guards a `backendStarted` flag so
  it can't double-start.
- **First-run setup DEFERS the backend (native only).** When
  `SetupModel.shouldPresentOnLaunch(settings:backendKind:)` is true (native
  backend + setup not yet completed), `applicationDidFinishLaunching` presents
  the onboarding window via `presentSetup()` and does NOT start the backend —
  the backend's Bonjour discovery triggers the Local Network prompt, and priming
  means the setup screen explains it first. `startBackendIfNeeded()` runs from
  the window's `onFinished` (Done or ✕). Every non-native backend and every
  later launch starts immediately. "Run Setup Again…" (Settings ▸ General) calls
  `presentSetup()` again; its `onFinished` is then a guarded no-op.
- **`AIRPLAY_SETUP` overrides the first-run gate (testing knob).**
  `SetupPresentation.resolved` reads it: `skip` never presents (so repeated dev
  launches don't nag — this is the one to set during testing), `force` always
  presents (ignores backend + the completed flag, to iterate on the flow itself),
  unset = the default gate. Sibling of `AIRPLAY_BACKEND`; forward it the same way
  (`launchctl setenv`, or run the bundle binary directly with the var set).
- **`AppDelegate` alone enforces "excluded ⇒ un-routable."** Neither
  `ExcludedAppsController` nor `AppRoutingController` prunes the other —
  `pruneRoutesForExcludedApps()` must run on launch and on every
  excluded-apps change, or a route can outlive its app's exclusion.
- **All permission strings must be set with `plutil`, not `PlistBuddy`**, in
  `scripts/make-app.sh`. `PlistBuddy` chokes on the apostrophe in the prose and
  exits 0 anyway, silently shipping a bundle with no rationale. Three keys the
  app needs (each plutil-inserted AND asserted): `NSAudioCaptureUsageDescription`
  (system-audio tap), `NSLocalNetworkUsageDescription` + `NSBonjourServices`
  (`_airplay._tcp`/`_raop._tcp` — must match `NativeDiscovery`, or discovery is
  silently blocked even with the usage string).
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
  TOGGLES `controlPanel`: it CLOSES a showing panel (a real close, so it lands
  home on the popover, like ✕/Esc) and RESTORES one tucked away on an
  app-switch — it never merely re-fronts an already-open panel. The flag
  defaults off, so the shipping window paths (`openMixer`, `openSettings`'s
  `showWindow()`) are untouched.

## Map

| Type | Role |
|---|---|
| `AppDelegate` | Lifecycle owner: activation policy, backend, `GroupController`, popover + mixer window, the shared control-panel shell (`AIRPLAY_CONTROL_PANEL=1`), excluded-apps/routing precedence, and the first-run setup gate (`presentSetup()` / `startBackendIfNeeded()`). |
| `StatusItemController` | The `NSStatusItem`; renders the volume-tracking symbol, forwards clicks. |
| (bootstrap) | `main.swift` — builds and retains `AppDelegate`, calls `NSApplicationMain`. |
| `scripts/make-app.sh` | Wraps the built binary into a signed `.app` with the three TCC/Bonjour Info.plist keys. |

## First-run onboarding (permission priming)

Public-release readiness: before the OS's "record"-framed prompts fire, a
first-run window (`AudiouterOnboardingUI`, a standalone movable
`OnboardingWindowController`) explains what the app does and why it needs
**System Audio** (the Core Audio tap), **Local Network** (Bonjour), and
**Remote Control** (Accessibility). The brain is Core's `SetupModel` (AppKit-free,
unit-tested). Each permission reflects its REAL current status, re-checked on
every window focus (`refreshStatuses`), to the degree macOS allows — the three
differ, on purpose:
- **System Audio** is verified for real by `CoreAudioTonePermissionProbe`: it plays
  a brief tone, taps its OWN process, and reads the level (non-zero ⇒ granted,
  zeros ⇒ denied). The tone IS audible (the tap's mute doesn't cover the playback
  path), so the System Audio row's copy WARNS the user a brief tone will play when
  they Allow — a known beep, not a mystery one. Keep the probe + row copy in sync.
  Gated on live TCC verify.
- **Local Network** has no status API (TN3179), so it's inferred FUNCTIONALLY: a
  brief `NWBrowser` that reaches the network ⇒ real `.granted`, else `.requested`.
- **Remote Control** DOES have a real, silent status API (`AXIsProcessTrusted()`),
  so it reports a genuine `.granted`, updated the moment the user toggles it in
  System Settings and returns. Primed AHEAD of the feature that consumes it —
  speaker-side transport controls simulating Mac media keys, not yet merged (the
  branch name once cited here, `claude/speaker-input-responsiveness-b8123f`, does
  NOT hold this work — see `docs/plans/phase-3-findings/branch-inventory.md`).

The window is a NORMAL (not floating, no Dock icon) window — an earlier version
made it `.floating` for recoverability, but that pins it above every other app,
which read as "the setup keeps popping up." Recoverability instead comes from two
places: `OnboardingWindowController` re-fronts itself on
`NSApplication.didBecomeActiveNotification` (e.g. returning from a System Settings
permission change), and `AppDelegate`'s menu-bar click re-fronts it (rather than
opening the popover) whenever `onboardingWindowController` is non-nil. First-run
completion persists in `AppSettings.hasCompletedSetup`.
