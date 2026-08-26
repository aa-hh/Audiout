# T7 — App shell & system integration (audit fixes)

**Branch:** `claude/fix-shell` — create as a worktree from the current branch head and push immediately:
```bash
cd "/Users/alechenderson/Projects/AirPlay Controller/.claude/worktrees/xenodochial-ardinghelli-fa348b"
git worktree add ../fix-shell -b claude/fix-shell
cd ../fix-shell && git push -u origin claude/fix-shell
```
The source worktree is clean (verified) — nothing uncommitted to carry over. Read `AGENTS.md` (root), `AudioutCore/Sources/AudioutApp/AGENTS.md`, `AudioutCore/Sources/AudioutSharedUI/AGENTS.md`, and `AudioutCore/Sources/AudioutSettingsUI/AGENTS.md` before editing. Guard 7 requires `scripts/self-review.sh` before any Swift commit; enable hooks with `git config core.hooksPath .githooks` if not already set.

**Binding build/test rule (repo-wide, no exceptions):** ALL compiles and test runs go through the wrapper scripts, which route work to the remote test mule: `bash scripts/build.sh` and `bash scripts/run-tests.sh --filter <Suite>` (full suite only for the final check). Invoking SwiftPM's build or test commands directly is FORBIDDEN (a pre-command guard blocks them) — it opts out of the mule, the machine-wide concurrency cap, and the sources cache, and pins work to the machine running many parallel agents. `AUDIOUT_BUILD_LOCAL=1` only if the mule is unreachable, and report that you used it. `make-app.sh` also routes its compile to the mule — same rule applies to the bundle checks below. Traps: never pipe `run-tests.sh` through `| tail` (it eats the exit code — capture output to a file or read the terminal scrollback instead); never kill or abandon an in-flight remote test run (orphaned legs pin the build lock).

**Owned files (this track may edit):**
- `AudioutCore/Sources/AudioutApp/AppDelegate.swift` — EXCEPT `installMainMenu` (T5 adds an Edit menu there) and EXCEPT any `onLicenseChanged` wiring line T4 may add in `makeSettingsRoot`
- `AudioutCore/Sources/AudioutApp/StatusItemController.swift`, `TouchBarFullBar.swift`, `VolumeKeyInterceptor.swift`
- `AudioutCore/Sources/AudioutCore/VolumeKeyInterception.swift` (no edits actually required; listed for completeness)
- `AudioutCore/Sources/AudioutSharedUI/StatusItemIcon.swift`, `MenuBarStatus.swift`, `ControlPanelWindowController.swift`, new file `VolumeHUDPanel.swift`
- `scripts/make-app.sh`
- Tests: `AudioutCore/Tests/AudioutCoreTests/MenuBarStatusTests.swift`, `StatusItemIconTests.swift`, new `VolumeHUDPanelTests.swift`

**Narrow exceptions into other tracks' files (smallest possible hunk, flagged for the merger):**
- `AudioutCore/Sources/AudioutPopoverUI/PopoverController.swift` — ONE function, `statusMasterVolume` (line 1185). Nothing else in that file.
- `AudioutCore/Sources/AudioutCore/AppSettings.swift` — ONE new bool property + its Keys entry (append, don't reorder).
- `AudioutCore/Sources/AudioutSettingsUI/GeneralSettingsViewController.swift` — ONE appended row + one switch property + one action method (T4 owns this file; append-only, minimal diff).

**Do not touch:** `Tokens.swift`, anything in `NativeBackend`/`AirPlayEngine`, any popover UI beyond the one function above, `AboutView.swift` (its TODO placeholder copy is T4's finding), `installMainMenu`, `main.swift`.

---

## Goal

Fix the shell-audit findings for Audiout's menu-bar app before the first public build: give the app a second door (Finder reopen), make the closed-panel glance stop lying (mute drain, failure state, honest VoiceOver text), give volume/mute keys visible feedback (a small HUD, since the system one is deliberately swallowed), stop the Touch Bar takeover from being permanent and un-optable, harden the status item and panel positioning, re-arm the volume tap on wake, gate the per-event stderr log, trim launch-path work, and close four release-hygiene gaps in `make-app.sh` (copyright string, https enforcement, unbumped-build-number refusal). These are P1/P2 items from the shell audit plus the shell-owned slices of the hardening and performance audits.

## Verified facts

All checked against the working tree at the branch point (baseline commands were run green before any change — see Verification).

- `applicationShouldHandleReopen` is implemented nowhere; `autosaveName` is set nowhere; nothing in the repo references `AppTranslocation` (grepped all of `AudioutCore` + `scripts`).
- `StatusItemController` doc comment (`StatusItemController.swift:32-43`) promises a routing dot, a mute drain, and spoken "muted"/"routing" state; none exist. `StatusRoutingIndicator` exists nowhere in the repo.
- `StatusItemIcon.make(isStreaming:masterVolume:)` (`StatusItemIcon.swift:26-34`) hardcodes `accessibilityDescription: "AirPlay volume"` and has no mute or failure input.
- `MenuBarStatus` (`MenuBarStatus.swift:28-44`) has exactly `isStreaming(devices:liveRoutedAppNames:)` and `symbolName(isStreaming:)`; two states only.
- `PopoverController.statusMasterVolume` (`PopoverController.swift:1185-1188`) returns `Double(controller.mainOutMasterVolume) / 100.0` with no mute term; consumed at `AppDelegate.swift:1678`. `GroupController` exposes `isMainOutMuted` (used at `AppDelegate.swift:264` and elsewhere).
- `Device` has `isSelected: Bool` (`Device.swift:126`) and `connectionState` with `case failed(ConnectionFailure)` (`ConnectionState.swift:27`).
- SF Symbols `speaker.badge.exclamationmark` (plain and with `variableValue:`) and `speaker.slash.fill` all resolve to non-nil `NSImage` on this Mac (probed with a `swift -e` one-liner, macOS 27).
- `repaintFromCurrentState` (`AppDelegate.swift:1666-1689`) is the one place the status glyph is fed; it already has `devices`, `routedAppNamesByDeviceID`, and `groupController`.
- The volume-key outcome path is `volumeKeyInterceptor.onAction` (`AppDelegate.swift:255-269`): applies the action, then calls `repaintFromCurrentState()`. `VolumeKeyAction` is `case setMainVolume(Int)` / `case toggleMainMute` (`VolumeKeyInterception.swift:178-183`). `groupController.mainOutMasterVolume` is an `Int` 0–100 (`AppDelegate.swift:298`).
- `.level` events are emitted only while the popover is open (metering gate, `AppDelegate.swift:531-537`), so `TouchBarFullBar.noteAudioLevel` is NOT a valid "audio is routing" signal — `MenuBarStatus.isStreaming` (device `.connected` or a live per-app route) is the launch-independent signal.
- `TouchBarFullBar.setOwnsVolume` (`TouchBarFullBar.swift:60-62`) presents/dismisses purely on ownership; `noteAudioLevel` (`:106-117`) invalidates + recreates a `Timer` on every level tick (~25 Hz per device). `touchBarFullBar` is `lazy` (`AppDelegate.swift:291`); it is forced into existence by `releaseTouchBar()` (`:322-324`), `noteAudioLevel` (`:1545`), and `setOwnsVolume` (`:1647`) — on every Mac, Touch Bar or not. `TouchBarHardware.isPresent` (`AudioutCore/Sources/AudioutCore/TouchBarHardware.swift:18`) is the hardware gate.
- No Touch Bar setting exists anywhere (`AppSettings`, `AudioutSettingsUI` — grepped). `AppSettings`' default-true pattern is `guard defaults.object(forKey:) != nil else { return default }` (`AppSettings.swift:180`, `:228`). `GeneralSettingsViewController.loadView` builds rows via `SettingsForm.row(title:subtitle:control:)` and passes them to `SettingsForm.paneView(rows:)` (`GeneralSettingsViewController.swift:91-184`); `TouchBarHardware` is public in `AudioutCore`, which `AudioutSettingsUI` already imports.
- Wake/reactivate observers exist at `AppDelegate.swift:883-891` (`didBecomeActiveNotification`) and `:892-904` (`didWakeNotification`); neither touches `volumeKeyInterceptor`. The interceptor re-arms only from `installIfNeeded` (`VolumeKeyInterceptor.swift:84-90`) and the in-callback disabled-event path (`:193-196`). `state.reenableIfDisabled()` exists (`:184-187`).
- `makeStatusMenu` (`AppDelegate.swift:1192-1205`) has Settings, Groups, separator, Quit only. `AboutWindowController` is public with `init(info:openURL:)` defaulting both args (`AboutView.swift:311-327`). Sparkle "Check for Updates" is invoked as `updaterController.checkForUpdates(nil)` (`AppDelegate.swift:1298`).
- The Sparkle updater is created at `AppDelegate.swift:366-370`, 38 lines before the status item (`:408`); `applyLicenseState()` (`:1452-1459`) writes `updaterController?.updater.httpHeaders` and is called at `:385` and from the validator answer at `:382-384`.
- `deviceIconController` (`AppDelegate.swift:213`) and `excludedApps` (`:219`) are stored `let`s (synchronous disk loads before `NSApplicationMain`); their first real accesses are `:507` and `:672`(closure body)/`:692` (`pruneRoutesForExcludedApps()`), all inside `applicationDidFinishLaunching` after the status item exists — safe to make `lazy var`.
- Every event in `apply(_:)` except `.level`/`.appLevel` calls `log("event: \(describe(event))")` unconditionally (`AppDelegate.swift:1524-1658`, 15 sites incl. the `deviceRemoved` literal at `:1529`); `log(_:)` is a blocking `write(2)` (`:1732-1734`, `:21-35`). `AIRPLAY_DEBUG_LEVELS` precedent at `:235`, `:1536`.
- `ControlPanelWindowController.show(anchorRect:)` clamps against `panel.screen ?? NSScreen.main` (`ControlPanelWindowController.swift:542`) even though the anchor may be on another display; `NSApp?.activate(ignoringOtherApps: true)` appears at `:522` and `:576` (deprecated since macOS 14; floor is 14.2).
- `make-app.sh`: `set -euo pipefail` at `:17`; `BUILD_NUMBER="${BUILD_NUMBER:-1}"` at `:40`; Info.plist section starts `:599`; the plutil-insert-then-assert pattern is at `:642-644`; `AUDIOUT_LICENSE_URL` block `:697-706` (also derives `SPARKLE_FEED_URL` from it at `:701-703`); Sparkle both-or-neither block `:727-737`. No `NSHumanReadableCopyright` anywhere; no https check anywhere.
- `ReduceTransparencyFallbackView.install(in:fill:)` (`ReduceTransparencyFallbackView.swift:52`) is the sanctioned Reduce Transparency cover; `HeadlessRuntime.isActive` (`HeadlessRuntime.swift:43+`) is automatically true under the test runner and gates every `orderFront`/`activate` (pattern at `ControlPanelWindowController.swift:575-578`). Reduce Motion is read via `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` with a `test_reduceMotionOverride` seam (SharedUI AGENTS.md rule; example `BusRailOverlayView.swift:403-404`).
- Tests: `MenuBarStatusTests.swift` (10 tests, `IsolatedSuite` base from `IsolatedTestCase.swift:211`) and `StatusItemIconTests.swift` (2 tests) exist and pass. `AudioutApp` is invisible to the test target (its AGENTS.md) — decisions must live in `AudioutCore`/`AudioutSharedUI`.
- Nothing in this track's finding list is already fixed — every item above was re-verified absent/broken as described. Shell P3-7 (Sparkle window focus in an LSUIElement app) needs a live build with a real feed and is DEFERRED — do not attempt it.

## Steps

Steps 1–19 are one sequential track (they share `AppDelegate.swift`). Step 20 is independent (`make-app.sh` only).

### Cluster A — truthful menu-bar glyph (P1-2, P2-7, P2-8, hardening #5)

1. **`MenuBarStatus.swift`** — add a three-state decision.
   - Add `public enum State: Equatable { case idle, streaming, failure }` (nested in `MenuBarStatus`).
   - Add `public static func state(devices: [Device], liveRoutedAppNames: [String: [String]]) -> State`: returns `.failure` if any device has `isSelected == true` AND `connectionState` is `.failed(_)` (unselected failed devices do NOT count — deselecting a broken speaker clears the badge); else `.streaming` when the existing `isStreaming(devices:liveRoutedAppNames:)` is true; else `.idle`. Keep `isStreaming` public and unchanged — `state` calls it.
   - Replace `symbolName(isStreaming:)` with `public static func symbolName(for state: State) -> String`: `.idle` → `"speaker.wave.3"`, `.streaming` → `"speaker.wave.3.fill"`, `.failure` → `"speaker.badge.exclamationmark"` (verified resolvable on macOS 27).
   - Add `public static func accessibilityDescription(state: State, masterVolumePercent: Int, isMuted: Bool) -> String` returning exactly:
     - `.failure` (any mute/volume): `"Audiout — speaker connection failed"`
     - muted, `.streaming`: `"Audiout — muted, streaming"`
     - muted, `.idle`: `"Audiout — muted"`
     - unmuted, `.streaming`: `"Audiout — 80%, streaming"` (percent = `masterVolumePercent`)
     - unmuted, `.idle`: `"Audiout — 80%"`
   - Update the type doc comment to describe the three states (failure = a selected speaker is `.failed` — the glance rule that a broken speaker must not look like a paused one).
2. **`StatusItemIcon.swift`** — change the signature to `public static func make(state: MenuBarStatus.State, masterVolume: Double, isMuted: Bool) -> NSImage?`: symbol from `MenuBarStatus.symbolName(for: state)`, `variableValue: masterVolume` unchanged (the drain arrives via the caller's value, step 5), `accessibilityDescription: MenuBarStatus.accessibilityDescription(state: state, masterVolumePercent: Int((masterVolume * 100).rounded()), isMuted: isMuted)`. Always `isTemplate = true` — the template invariant and its doc comment stay word-for-word.
3. **Tests** — extend `MenuBarStatusTests.swift`: `state` priority (failure beats streaming; selected+failed → `.failure`; failed-but-unselected → not `.failure`; connected → `.streaming`; nothing → `.idle`), migrate the two `symbolName` tests to `symbolName(for:)` and add the `.failure` case, and assert the five `accessibilityDescription` strings above verbatim. Extend `StatusItemIconTests.swift`: migrate the two template tests to the new signature and add `failureIcon_isTemplate` (`make(state: .failure, masterVolume: 0.5, isMuted: false)` — non-nil + template; non-nil is what proves the badge symbol exists on the runner). Follow the existing suites' style; `MenuBarStatusTests` stays on `IsolatedSuite`.
4. **`StatusItemController.swift`**:
   - Replace the stored `isStreaming: Bool` with `state: MenuBarStatus.State = .idle` and add `isMuted: Bool = false`. Replace `updateStreamingState(devices:liveRoutedAppNames:)` with `func update(devices: [Device], liveRoutedAppNames: [String: [String]], isMainOutMuted: Bool)` which computes `MenuBarStatus.state(...)`, stores state + mute, and re-renders only when either changed (same guard discipline as `updateMasterVolume`). `renderButtonImage()` calls the new `StatusItemIcon.make(state:masterVolume:isMuted:)`.
   - In `init`, set `statusItem.autosaveName = "AudioutStatusItem"` immediately after `statusItem(withLength:)` (P2-1). Do not add `.removalAllowed`.
   - Failure path (P2-3): restructure so `init` calls a `private func configureButton() -> Bool` that returns false when `statusItem.button` is nil and otherwise does `renderButtonImage()` + `wireButtonAction()`. On false: log via the target-shared `audioutEmergencyWriteStderr` (`"[Audiout] status item has no button — retrying once next run-loop turn\n"`), and `DispatchQueue.main.async` retry exactly once; if the retry also fails, log `"[Audiout] status item still has no button — the app has no menu-bar entry\n"`. No further retries.
   - Doc comment (P2-8): delete the routing-dot bullet (the `StatusRoutingIndicator` behavior was never built) and rewrite the glance-rules paragraph to describe what now ships: mute drains the arc (via `statusMasterVolume`), a failure state renders `speaker.badge.exclamationmark`, and the accessibility description speaks level/mute/streaming/failure.
   - Update the `MenuBarStatus` line in `AudioutCore/Sources/AudioutSharedUI/AGENTS.md`'s Map to say idle/streaming/failure (docs land with code).
5. **`PopoverController.swift:1185-1188`** (narrow exception, ONE function): `statusMasterVolume` returns `0` when `controller.isMainOutMuted`, else the existing value. Update its doc comment ("master-mute drains the arc so the closed-panel glance never lies"). Nothing else in this file.
6. **`AppDelegate.swift` `repaintFromCurrentState` (`:1666-1689`)**: replace the `updateStreamingState` call at `:1683` with `statusItemController.update(devices: devices, liveRoutedAppNames: routedAppNamesByDeviceID, isMainOutMuted: groupController.isMainOutMuted)`.

### Cluster B — volume HUD (P1-3)

7. **New file `AudioutCore/Sources/AudioutSharedUI/VolumeHUDPanel.swift`** — a transient, non-interactive volume readout shown when Audiout consumes a hardware volume/mute key (the system HUD is deliberately swallowed in that state; this replaces it). Exact spec:
   - `public final class VolumeHUDPanel: NSPanel`, `@MainActor`. Style mask `[.borderless, .nonactivatingPanel]`, `level = .statusBar`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]`, `ignoresMouseEvents = true`, `isRestorable = false` (AGENTS rule), `hidesOnDeactivate = false`, `isReleasedWhenClosed = false`, `backgroundColor = .clear`, `isOpaque = false`, `hasShadow = true`.
   - Content: fixed 200×44 pt pill. An `NSVisualEffectView` (`material = .hudWindow`, `state = .active`, `wantsLayer = true`, `layer?.cornerRadius = 12`, `layer?.masksToBounds = true`), with `ReduceTransparencyFallbackView.install(in:)` called immediately after creating it, BEFORE content subviews (its documented contract). Content: a horizontal `NSStackView` (centered, 8 pt spacing, 16 pt leading/trailing insets) holding an `NSImageView` (template SF Symbol) and an `NSTextField` label (`labelWithString:`, `.systemFont(ofSize: 15, weight: .medium)`, `textColor = .labelColor`).
   - Pure content decision (the testable seam, mirroring the `MenuBarStatus`/`StatusItemIcon` split): `public struct Content: Equatable { public let symbolName: String; public let variableValue: Double; public let text: String }` with `public static func content(volumePercent: Int, isMuted: Bool) -> Content`: muted → `("speaker.slash.fill", 0, "Muted")`; else → `("speaker.wave.3.fill", Double(volumePercent)/100, "\(volumePercent)%")`.
   - `public func show(volumePercent: Int, isMuted: Bool, on screen: NSScreen?)`: applies the content (image via `NSImage(systemSymbolName:variableValue:accessibilityDescription:)`, `isTemplate = true`; label text), positions at the TOP-RIGHT of `screen ?? NSScreen.main` — `x = visibleFrame.maxX - width - 16`, `y = visibleFrame.maxY - height - 16` (matches the macOS 26+ system HUD region and sits near the menu-bar glyph the user is already glancing at; see Open decisions) — cancels any pending dismiss, orders front at full alpha with NO appearance animation (the system HUD appears instantly), and (re)arms a 1.5 s dismiss timer. Every subsequent `show` while visible updates content in place and re-arms the timer.
   - Dismissal: after 1.5 s of no calls, fade `alphaValue` to 0 over 0.25 s via `NSAnimationContext` then `orderOut(nil)` and reset alpha; under Reduce Motion (`NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`, with a `public var test_reduceMotionOverride: Bool?` seam per the SharedUI rule) skip the fade and `orderOut` immediately.
   - Headless: gate `orderFront` behind `HeadlessRuntime.isActive` exactly like `ControlPanelWindowController.show` (`ControlPanelWindowController.swift:575-578`) — content/position/timer logic still runs so tests stay strong. Test seams: `public var test_text: String`, `public var test_symbolName: String?` (read back from the views), `public var test_isShown: Bool`.
8. **Tests** — new `AudioutCore/Tests/AudioutCoreTests/VolumeHUDPanelTests.swift` (`@testable import AudioutSharedUI`): `Content.content` for muted and for 55% (exact symbol/text/variableValue); after `show(volumePercent: 80, isMuted: false, on: nil)` the seams read `"80%"` / `"speaker.wave.3.fill"`; after a muted show they read `"Muted"` / `"speaker.slash.fill"`; `isRestorable == false` and `ignoresMouseEvents == true`.
9. **`AppDelegate.swift`** — wire it. Add `private lazy var volumeHUD = VolumeHUDPanel()`. In the `volumeKeyInterceptor.onAction` closure (`:255-269`), after `repaintFromCurrentState()`, add: resolve the anchor screen (`statusAnchorRect()` → `NSScreen.screens.first { $0.frame.intersects(anchor) }`, else nil) and call `volumeHUD.show(volumePercent: groupController.mainOutMasterVolume, isMuted: groupController.isMainOutMuted, on: screen)`. This is the ONLY call site — do not add HUD calls to the Touch Bar closures or anywhere else.

### Cluster C — Touch Bar scope + opt-out + timer fix (P1-4, perf P1-16)

10. **`AppSettings.swift`** (narrow exception, append-only): add `Keys.touchBarControls = "general.touchBarControls"` and `public var touchBarControlsEnabled: Bool` — default TRUE via the file's own unset-vs-stored pattern (`guard defaults.object(forKey:) != nil else { return true }`, cf. `AppSettings.swift:180`). Doc comment: Settings › General "Use Audiout's Touch Bar controls"; only meaningful on Touch Bar hardware.
11. **`TouchBarFullBar.swift`**:
    - Presentation now needs three facts, not one: keep `setOwnsVolume(_:)`, add `func setStreaming(_:)` and `func setEnabled(_:)` (stored `ownsVolume=false`, `isStreaming=false`, `isEnabled=true`), each calling a `private func reconcilePresentation()` = present when all three are true, else dismiss. Update the type doc: the bar shows only while Audiout owns the volume AND audio is actually leaving the Mac AND the user hasn't turned it off — not for the whole time the aggregate is selected.
    - Fix `noteAudioLevel` (`:106-117`) per the perf audit: store `private var lastAudibleAt: CFTimeInterval = 0`; on an audible tick (`rms > 0.002`) set `lastAudibleAt = CACurrentMediaTime()` and `setPlaying(true)`; keep ONE repeating 1 s `Timer` (tolerance 0.2) that exists only while `isPlaying` — created when `isPlaying` flips true, and in its tick, if `CACurrentMediaTime() - lastAudibleAt >= 2.0`, call `setPlaying(false)` and invalidate/nil the timer. No per-tick invalidate/reschedule.
12. **`AppDelegate.swift`** — gate + feed:
    - Add `private let hasTouchBar = TouchBarHardware.isPresent`. Guard EVERY `touchBarFullBar` access behind it so the lazy is never forced on a non-Touch-Bar Mac (perf P1-16 tail): `releaseTouchBar()` body (`:322-324`), `noteAudioLevel` at `:1545`, `setOwnsVolume` at `:1647`, plus the new pushes below.
    - In `repaintFromCurrentState`, when `hasTouchBar`, push `touchBarFullBar.setStreaming(MenuBarStatus.isStreaming(devices: devices, liveRoutedAppNames: routedAppNamesByDeviceID))` (the launch-independent "audio actively routing" signal — `.level` events are popover-gated and unusable for this, see Verified facts).
    - In `applicationDidFinishLaunching`, when `hasTouchBar`: push `touchBarFullBar.setEnabled(settings.touchBarControlsEnabled)`, and observe `UserDefaults.didChangeNotification` (main queue, `MainActor.assumeIsolated` idiom as at `:890`) to re-push it — idempotent and cheap, and it makes the Settings toggle take effect immediately without new cross-target wiring.
13. **`GeneralSettingsViewController.swift`** (narrow exception, append-only): only when `TouchBarHardware.isPresent`, append one row after `reconnectHint` in the `rows:` array: an `NSSwitch` (`touchBarSwitch` property, state from `settings.touchBarControlsEnabled`, accessibility label `"Use Audiout's Touch Bar controls"`) in `SettingsForm.row(title:subtitle:control:)` with title `"Use Audiout's Touch Bar controls"` and subtitle `"While Audiout is playing to speakers, show Touch Bar volume controls that work."`, plus one `@objc` action writing `settings.touchBarControlsEnabled`. Nothing else in this file changes; do not re-order existing rows.

### Cluster D — shell robustness + hygiene (P1-1, P2-2/3/5/6, P3-4/5, hardening 25, perf P2-20/P3-7)

14. **`AppDelegate.swift`** — reopen (P1-1). Add:
    ```swift
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
    ```
    Body: if `onboardingWindowController` is non-nil, `onboardingWindowController?.present()` (setup owns the interaction, same rule as the menu-bar click at `:413-416`); else `showSurface(.mixer)`. Return `false` in both branches. Doc comment: the standard recovery gesture when the menu-bar icon is hidden (notch/full bar) — double-clicking the app in Finder/Spotlight now opens the Mixer.
15. **`VolumeKeyInterceptor.swift` + wake re-arm (P2-6)**: add `private var ownsVolume = false` set in `setOwnsVolume`, and `func reassertIfOwned()` = `guard ownsVolume else { return }; installIfNeeded()` (`installIfNeeded` already handles both "re-arm a disabled tap" and "tap missing"; a repeat Accessibility miss is already one-shot-guarded by `didSurfaceAccessibilityGap`). In `AppDelegate`, call `self.volumeKeyInterceptor.reassertIfOwned()` inside BOTH the `didBecomeActiveNotification` observer (`:883-891`) and the `didWakeNotification` observer (`:892-904`).
16. **`AppDelegate.swift`** — gate the per-event log (hardening 25 / perf P2-5). Add `private let debugEvents = ProcessInfo.processInfo.environment["AUDIOUT_DEBUG_EVENTS"] == "1"` next to `debugLevels` (`:235`) and `private func logEvent(_ event: BackendEvent) { guard debugEvents else { return }; log("event: \(describe(event))") }`. Replace all 15 per-event log calls in `apply(_:)` (`:1524-1658`, including the `deviceRemoved` literal at `:1529`) with `logEvent(event)` — this also stops `describe()` building strings nobody reads. Leave every other `log(...)` call (launch/terminate/PTP/volume-keys lines) and the `debugLevels` gate untouched; `audioutEmergencyWriteStderr` stays exactly as is for the crash path.
17. **`AppDelegate.swift`** — launch path (perf P2-20, P3-7): change `deviceIconController` (`:213`) and `excludedApps` (`:219`) from `let` to `lazy var` (doc note: synchronous Application Support reads, deferred past first pixel; first touches verified to be inside `applicationDidFinishLaunching`). Move the Sparkle-updater creation + `LicenseCheckIn` + `LicenseValidator` + `applyLicenseState()` block (`:362-385`) as ONE unit to immediately after `installMainMenu()` (`:447`), so the status item exists before the updater starts; the block's internal order is unchanged (the updater must exist before `applyLicenseState()` writes its headers).
18. **`AppDelegate.swift`** — status menu (P3-4). Add `private lazy var aboutWindowController = AboutWindowController()`. In `makeStatusMenu` (`:1192-1205`), between Groups and the existing separator+Quit, add: a separator; `"About Audiout"` (no ellipsis — About never takes one) targeting a new `@objc private func menuOpenAbout()` that calls `aboutWindowController.show()`; and, only when `updaterController != nil`, `"Check for Updates…"` targeting a new `@objc private func menuCheckForUpdates()` that calls `updaterController?.checkForUpdates(nil)` (same call shape as `:1298`). Final order: Settings, Groups, — , About Audiout, [Check for Updates…], — , Quit Audiout.
19. **Translocation notice (P2-5 — the smaller honest option, decided)** + **panel clamp (P2-2)** + **activate migration (P3-5)**:
    - At the end of `applicationDidFinishLaunching`, if `Bundle.main.bundleURL.path.contains("/AppTranslocation/")` (Gatekeeper's randomized read-only mount — a check that never fires for dev builds), show a one-button `NSAlert` (after `NSApp.activate()`): messageText `"Audiout is running from a temporary location"`, informativeText `"macOS is running Audiout from a temporary read-only location. Move Audiout to your Applications folder and open it from there — otherwise \u{201C}Launch at login\u{201D} and speaker sync can\u{2019}t keep working."`, button `"OK"`. No move-the-bundle implementation, no persistence flag (a translocated launch is transient by nature).
    - `ControlPanelWindowController.swift:542`: change the clamp screen to `NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? panel.screen ?? NSScreen.main` (the anchor's own display), with a one-line comment on the multi-display bug. `:522` and `:576`: replace `NSApp?.activate(ignoringOtherApps: true)` with `NSApp?.activate()` (deployment floor is 14.2). Only these two call sites — `AboutView.swift`'s is T4's file.

### Cluster E — `make-app.sh` release hygiene (P2-4, P3-6, hardening 26). Independent of all Swift steps.

20. Three edits, all preserving the script's paste-proof one-liner style:
    - **Fail-fast guards, placed in the Config section right after `BUILD_NUMBER="${BUILD_NUMBER:-1}"` (`:40`)** so a bad invocation dies before any compile. First, capture explicitness BEFORE the default is applied — insert `BUILD_NUMBER_WAS_SET="${BUILD_NUMBER+set}"` on the line ABOVE `:40`. Then:
      - https (hardening 26): if `SPARKLE_FEED_URL` is set and doesn't start `https://` → error naming the risk (the feed carries `Authorization: Bearer <license key>`) and `exit 1`; same for `AUDIOUT_LICENSE_URL`. (The derived feed at `:701-703` inherits a validated base, so checking the explicit env values is sufficient.)
      - build number (P3-6): if `SPARKLE_FEED_URL` or `SPARKLE_ED_PUBLIC_KEY` is set and `BUILD_NUMBER_WAS_SET` is empty → error: a Sparkle release built on the default `CFBundleVersion=1` is an update the updater will never offer; `exit 1`. Same both-or-neither spirit as `:727-737` (which stays where it is, untouched).
    - **Copyright (P2-4)**: add a `HUMAN_COPYRIGHT` variable in the Config section with the literal value `"© 2026 Alec Henderson. Licensed under GPL-2.0-or-later."` (see Open decisions); in the Info.plist section, adjacent to the other plutil inserts (after `:642`), add `plutil -insert NSHumanReadableCopyright -string "$HUMAN_COPYRIGHT" "$PLIST"` plus the same extract-or-die assert used at `:643-644` (plutil not PlistBuddy — the value contains punctuation; that trap is documented at `:636-641`).

## Out of scope — do not touch

- `AboutView.swift` TODO copy / example.com link (shell P1-5 / hardening P0) — T4 owns Settings.
- Opt-in failure notifications (`UNUserNotification`) — hardening #5's second half; only the menu-bar failure state ships here.
- Shell P3-7 (Sparkle update-window focus) — DEFERRED, needs a live build with a real feed. Do not "fix" it speculatively.
- Shell P3-1 (quit warning), P3-2 (single-instance guard), P3-3 (Accessibility→Setup weight) — deliberate as-is; not in this order.
- No `AppDelegate` decomposition/`BackendHookInstaller` extraction, no `os.Logger` migration, no locale-aware percent formatting, no per-OS-version HUD placement, no HUD for Touch Bar taps or slider drags, no changes to `installMainMenu`, `main.swift`, `Tokens.swift`, `NativeBackend`, popover UI beyond `statusMasterVolume`, no reordering of existing Settings rows, no cleanup or refactors of untouched code, no backwards-compat shims, no error handling for impossible cases.
- Never overwrite `build/Audiout.app` with the default bundle id, and never LAUNCH the verification bundle (a launched throwaway id leaves TCC residue).

## Verification

Pre-change baseline, observed in the scoping session (both via the mandatory wrappers):
- `bash scripts/run-tests.sh --filter "MenuBarStatusTests|StatusItemIconTests"` → 12 tests, 2 suites, all passed.
- `bash scripts/build.sh` → succeeded (exit 0).

Done means ALL of the following ran in the executor's session and passed, output pasted (never through `| tail`):
1. `bash scripts/run-tests.sh --filter "MenuBarStatusTests|StatusItemIconTests|VolumeHUDPanelTests"` → all pass (expect ≥ 24 tests, 3 suites — exact count depends on tests added in steps 3/8).
2. `bash scripts/run-tests.sh` → full suite passes (the suite is flaky under machine load — one retry of a clearly load-related failure is acceptable, say so if used).
3. `bash scripts/build.sh` → succeeds.
4. `make-app.sh` negative checks (each must exit non-zero, fast, BEFORE compiling anything):
   - `SPARKLE_FEED_URL=http://x.example SPARKLE_ED_PUBLIC_KEY=k bash scripts/make-app.sh` → https refusal.
   - `AUDIOUT_LICENSE_URL=http://x.example bash scripts/make-app.sh` → https refusal.
   - `SPARKLE_FEED_URL=https://x.example SPARKLE_ED_PUBLIC_KEY=k bash scripts/make-app.sh` → BUILD_NUMBER refusal.
5. Copyright present in a real bundle: `APP_NAME="Audiout T7 Verify" BUNDLE_ID="com.audiout.Audiout.t7verify" bash scripts/make-app.sh` then `plutil -extract NSHumanReadableCopyright raw -o - "build/Audiout T7 Verify.app/Contents/Info.plist"` → prints the copyright string. Do NOT open/launch that bundle; delete `"build/Audiout T7 Verify.app"` afterwards.

Acceptance checklist (all covered by the steps; re-read before reporting done):
- [ ] Reopen (Finder double-click) opens the Mixer; re-fronts Setup when Setup is open.
- [ ] Muted Main Out drains the menu-bar arc; a selected `.failed` device shows the badge symbol; VoiceOver text matches the five exact strings.
- [ ] StatusItemController doc no longer describes unbuilt behavior.
- [ ] Volume/mute key while owning volume shows the HUD; repeat presses re-arm it; fade suppressed under Reduce Motion.
- [ ] Touch Bar presents only when owns-volume AND streaming AND setting on; setting row appears only on Touch Bar hardware; no `Timer` churn per level tick; `touchBarFullBar` never instantiated on a non-Touch-Bar Mac.
- [ ] `autosaveName` set; button-nil path logs + retries once; panel clamps to the anchor's screen; `activate()` migrated at exactly two sites.
- [ ] Tap re-arms from wake and app-activate; per-event stderr log silent unless `AUDIOUT_DEBUG_EVENTS=1`; icon/excluded stores load lazily; updater starts after the status item; status menu has About + conditional Check for Updates; translocated launch shows the one-button notice.
- [ ] make-app.sh: copyright inserted+asserted; https and BUILD_NUMBER guards fail fast.

Commit on `claude/fix-shell`, push to `origin/claude/fix-shell`. Do NOT merge into `main` — merging needs Alec's explicit go-ahead.

## Open decisions (defaults chosen; flag both in the final report)

1. **Copyright holder name** — order ships `"© 2026 Alec Henderson. Licensed under GPL-2.0-or-later."`. Alec may prefer a different legal name/entity; the string is a one-line literal (`HUMAN_COPYRIGHT`) so it is trivial to change.
2. **HUD look/placement** — decided: 200×44 top-right pill under the menu bar on the status item's screen (matches the macOS 26+ system HUD region and the user's glance point), symbol + percent text, 1.5 s hold + 0.25 s fade. If Alec prefers the classic bottom-center bezel, only the positioning lines in `VolumeHUDPanel.show` change.

## Execution plan

- **Track 1 — Swift (steps 1–19).** Model: opus. Effort: medium (every decision is made above; the work is careful multi-file application, not design). Files: all owned Swift files + the three narrow-exception files + the two test files + one new file each in SharedUI and Tests. SERIAL within itself (single executor, steps in order — clusters A→B→C→D keep the build green between clusters).
- **Track 2 — make-app.sh (step 20 + Verification items 4–5).** Model: sonnet. Effort: low. Files: `scripts/make-app.sh` only — fully disjoint from Track 1. PARALLEL with Track 1.
- Branch has no uncommitted work to depend on (source worktree verified clean); both tracks fork from the same commit. Verification items 1–3 run once on the combined result after merge; Track 2's items 4–5 also run on the combined result.

## Executor rules (copy verbatim into the handoff prompt)

> - Follow the steps in order. Do not add, merge, reorder, or skip steps.
> - If reality contradicts a Verified fact or a step is impossible as written, STOP and report the discrepancy. Do not improvise a workaround.
> - Before reporting progress, audit each claim against a tool result from this session. Only report work you can point to evidence for. If tests fail, say so with the output.
> - "Done" means the Verification commands were run in this session and passed. Paste their output.
> - Touch nothing in the Out-of-scope list.
> - Deliver what was asked, at the scope intended. If the spec seems mistaken or a better approach exists, say so in a sentence and continue as specified rather than quietly narrowing, widening, or transforming it.
