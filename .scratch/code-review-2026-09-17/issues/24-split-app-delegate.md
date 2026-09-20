# 24 — Move the companion-server wiring out of AppDelegate so it can be tested

Status: ready-for-agent
Wave: 5
Pipeline model: fable (normal mode)
Source: [REVIEW.md](../REVIEW.md), findings shell #3, shell #6

4,205 lines, one 818-line `applicationDidFinishLaunching`, ~930 self-contained lines of companion wiring; two self-labelled temporary diagnostics ship.

## Done when

The companion wiring lives in a type under `AudioutCore` with a test; `applicationDidFinishLaunching` is under 300 lines; the two temporary diagnostics are removed or gated behind the existing internal-machine marker. Full suite green.

## Test seam

new `CompanionWiringTests` plus the full suite

## Verification

```bash
AUDIOUT_FULL_SUITE=1 bash scripts/run-tests.sh
```

## Findings (verbatim from the area reports)

### 3. [SUBSTANCE] `AppDelegate.swift` is 4,205 lines with one 818-line method; ~930 of those lines are a self-contained companion server that could be tested
- Where: `AudioutCore/Sources/AudioutApp/AppDelegate.swift` — `applicationDidFinishLaunching` at `:749-1566` (818 lines); `wireCompanionServer` at `:2882-3114` (233); `makeCompanionAlignmentActions` at `:3282-3491` (210); `apply(_:)` at `:3648-3817` (170)
- Evidence: counted over the file — 67 stored properties, 77 methods. The launch method holds, in one straight run: PostHog setup, the status item and its click policy, two store-failure funnels, Sparkle, four licence calls, ~45 `popoverController.on*` assignments, six `NSWorkspace` observers, the licence gate branch, the permission observer, the Touch Bar, and the companion server.
- Why it matters: the folder's own AGENTS.md says "Behavior belongs in the library, which tests can reach" and "the test suite cannot see it" — so every line here is untested by construction. 930 of them (the `// MARK: Companion server` block at `:2703` through `:3636`) are pure protocol behaviour with no AppKit in them.
- Fix: lift the companion block into a `CompanionCoordinator` in `AudioutCore` holding the ~31 companion members, and split the launch method into the wiring groups its own comment blocks already name (`installStores()`, `wireBackend()`, `wirePopover()`, `wireSystemObservers()`, `runGateOrStart()`). Both are moves, not rewrites.
- Confidence: high

### 6. [SUBSTANCE] Two dev-only diagnostics ship in the release binary, both self-labelled as temporary
- Where: `AudioutCore/Sources/AudioutApp/AppDelegate.swift:4091-4204` (99-line `startCastPendingProbeIfEnabled`, called from launch at `:1556`) and `:2059-2091` (`applyDevSelectOnLaunchIfSet`, called from `startBackendIfNeeded` at `:2061`)
- Evidence:
  ```
  // MARK: - Cast pending-fill live probe (TEMPORARY diagnostic, 2026-08-23)
  ...
  /// Remove with the rest of the 2026-08-23 diagnostics once the root cause
  /// is pinned.
  ```
  and at `:2069`:
  ```
  /// razor: no UI, no persistence, no Group support — delete the key when done.
  ```
  The probe drives the real UI, writes PNGs, calls `NSApp.terminate(nil)` and ends in `exit(0)` at `:4202`.
- Why it matters: 130 lines a cold reviewer must read and decide are inert, plus two env-var/defaults-key paths into `exit(0)` and into `setDeviceSelected` that exist in every shipped copy. Both are dated and both say to delete them.
- Fix: delete both, or wrap them in `#if DEBUG` so the release binary carries neither.
- Confidence: high
