# AudioutApp

## Purpose

The shipping executable: a thin AppKit shell that boots the app and wires the
pieces together. It owns no model and no AirPlay logic, and the test suite
cannot see it.

## Rules

- One surface, composed here only. Behavior belongs in the library, which tests can reach.
- Every "open X" affordance leads to a screen; Setup and About are the surviving windows.
- A screen nobody is looking at does no work; never force-build one to deliver an event.
- The backend is chosen once from `AIRPLAY_BACKEND`; everything downstream holds `OutputBackend`.
- Subscribe before `start()`, and start once, or the first `deviceAdded` burst is lost.
- The licence gate precedes everything on a purchased build, and owns clicks meanwhile.
- First-run setup defers the backend on native, because discovery raises the Local Network prompt.
- `AIRPLAY_SETUP` and `AIRPLAY_PERMISSIONS` override the gate and the OS permission seams for testing.
- Permission-dependent live builds need a Developer ID signature; ad-hoc grants die on every rebuild.
- `AppDelegate` alone enforces excluded implies un-routable, on launch and on every exclusion change.
- Set permission strings with `plutil`, never `PlistBuddy`, which chokes on an apostrophe and exits 0.
- The mid-session permission grant is detected by events, never a timer, and every hook stays non-blocking.
- Resume scope after a grant is asymmetric: launch resumes per-app routes only, never whole-system.
- No window restoration: every new window sets `isRestorable = false`.
- Long-form traps, dated decisions and the changelog: [AGENTS-HISTORY.md](AGENTS-HISTORY.md). Grep it before debugging anything here.

## Map

- `AppDelegate` → lifecycle owner: backend, `GroupController`, surface, setup gate.
- `StatusItemController` → the `NSStatusItem`: volume symbol, forwards clicks.
- `main.swift` → bootstrap: builds and retains `AppDelegate`.
- `scripts/make-app.sh` → wraps the binary into a signed `.app` with Info.plist keys.
