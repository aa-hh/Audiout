# UI — onboarding, main window, settings, app target — review

## Verdict

This area is unusually well reasoned for a cold reader: nearly every non-obvious line carries a *why* comment naming the live bug or owner decision behind it, error paths are reported rather than swallowed (`saveOrReport`, `StoreRecovery.onWriteFailure`, `presentStoreDataAlertOnce`), and the two things the brief flagged as likely weak spots turn out to be the strongest parts — the licence gate handles offline correctly (an unreachable server saves the key and opens the gate, all three network calls carry a 10 s timeout) and the onboarding flow has real ceilings for a frozen prompt and an abandoned System Settings trip. Sparkle and PostHog are cleanly confined: `import Sparkle` / `import PostHog` appear on exactly two lines in the whole package, both in `AudioutApp/AppDelegate.swift`, and `Package.swift` links them only to the `AudioutApp` target. Windows and screens are built once and retained, not recreated per open. What a cold reviewer cannot do is *read* it: `AppDelegate.swift` is 4,205 lines with 67 stored properties, 77 methods and a single 818-line `applicationDidFinishLaunching`, and eight controllers hide 124–405-line `loadView()` monoliths. The single highest-impact change is splitting `AppDelegate` — the companion-server half alone is ~930 self-contained lines that would be testable the moment it left this untestable target.

## Findings

### 1. [BUG] Three sites write to stderr with the exact API this codebase documents as crash-on-broken-pipe
- Where: `AudioutCore/Sources/AudioutSettingsUI/GeneralSettingsViewController.swift:820`, `AudioutCore/Sources/AudioutApp/MediaKeyController.swift:71`, `AudioutCore/Sources/AudioutApp/AppDelegate.swift:4116`
- Evidence: `AppDelegate.swift:19-25` states the hazard and exists to avoid it —
  ```
  /// `FileHandle.write(_:)` raises an uncatchable `NSException` (not a Swift
  /// error) when the underlying fd is closed or broken — e.g. a dev launch
  /// from a terminal whose pipe has gone away. That turns routine logging into
  /// a crash. This helper never throws and never raises: a lost log line is
  /// acceptable, a crashed logger is not.
  func audioutEmergencyWriteStderr(_ message: String) {
  ```
  Yet `GeneralSettingsViewController.swift:820-821` does exactly what the comment warns against:
  ```
            FileHandle.standardError.write(
                Data("[Audiout] launch-at-login change failed: \(error)\n".utf8))
  ```
  `grep -rn audioutEmergencyWriteStderr Sources/` returns 5 hits (3 call sites); `grep -rn FileHandle.standardError Sources/` returns 16 — 3 of them in this area.
- Why it matters: flipping "Launch at login" in a build launched from a terminal whose pipe has since closed raises an uncatchable Objective-C exception and kills the app. The failure path meant to *recover* from a refused login item is itself the crash.
- Fix: move `audioutEmergencyWriteStderr` out of `AudioutApp` (it is currently internal to that target, which is why `AudioutSettingsUI` cannot reach it) into `AudioutSharedUI` or `AudioutCore`, and replace these three calls with it. The other 13 sites belong to other reviewers' areas.
- Confidence: high

### 2. [BUG] `VolumeKeyTapState.onAction` is read on the event-tap thread without the lock every sibling field uses
- Where: `AudioutCore/Sources/AudioutApp/VolumeKeyInterceptor.swift:197`, read at `:238`, written at `:60-66`
- Evidence: the class doc says every field is lock-guarded, and three of four are —
  ```swift
  private final class VolumeKeyTapState: @unchecked Sendable {
      private let lock = NSLock()
      ...
      var onAction: ((VolumeKeyAction) -> Void)?          // line 197 — no lock
      func setOwnsVolume(_ owns: Bool) { lock.withLock { ownsVolume = owns } }
      func setMainVolume(_ volume: Int) { lock.withLock { mainVolume = volume } }
  ```
  `handle(type:event:)` runs on the tap callback thread and reads both under and outside the lock:
  ```swift
  let (owns, current) = lock.withLock { (ownsVolume, mainVolume) }   // :221 guarded
  ...
  onAction?(action)                                                  // :238 unguarded
  ```
- Why it matters: `@unchecked Sendable` switches off the compiler check that would catch this. Today the closure is written once in `init` (`:60`) before any tap exists, so there is no live race — the defect is that nothing enforces that, and a `var` on a shared, cross-thread type is an invitation to reassign it later from the main actor while a key press is in the callback.
- Fix: make it `let onAction: (VolumeKeyAction) -> Void` passed to `VolumeKeyTapState.init`, matching how the class treats `_tap`.
- Confidence: high (that the field is unguarded and cross-thread); medium (that it can misfire as written today)

### 3. [SUBSTANCE] `AppDelegate.swift` is 4,205 lines with one 818-line method; ~930 of those lines are a self-contained companion server that could be tested
- Where: `AudioutCore/Sources/AudioutApp/AppDelegate.swift` — `applicationDidFinishLaunching` at `:749-1566` (818 lines); `wireCompanionServer` at `:2882-3114` (233); `makeCompanionAlignmentActions` at `:3282-3491` (210); `apply(_:)` at `:3648-3817` (170)
- Evidence: counted over the file — 67 stored properties, 77 methods. The launch method holds, in one straight run: PostHog setup, the status item and its click policy, two store-failure funnels, Sparkle, four licence calls, ~45 `popoverController.on*` assignments, six `NSWorkspace` observers, the licence gate branch, the permission observer, the Touch Bar, and the companion server.
- Why it matters: the folder's own AGENTS.md says "Behavior belongs in the library, which tests can reach" and "the test suite cannot see it" — so every line here is untested by construction. 930 of them (the `// MARK: Companion server` block at `:2703` through `:3636`) are pure protocol behaviour with no AppKit in them.
- Fix: lift the companion block into a `CompanionCoordinator` in `AudioutCore` holding the ~31 companion members, and split the launch method into the wiring groups its own comment blocks already name (`installStores()`, `wireBackend()`, `wirePopover()`, `wireSystemObservers()`, `runGateOrStart()`). Both are moves, not rewrites.
- Confidence: high

### 4. [SUBSTANCE] The pane header band, scroll/column scaffold and Equalizer block are hand-copied across three controllers
- Where: `AudioutCore/Sources/AudioutWindowUI/DeviceDetailViewController.swift:376-435`, `AudioutCore/Sources/AudioutWindowUI/MainOutDetailViewController.swift:170-215`, `AudioutCore/Sources/AudioutWindowUI/GroupEditorViewController.swift:550-608`
- Evidence: the same constraint sequence, in the same order, off the same constants. `MainOutDetailViewController.swift:189-203` and `DeviceDetailViewController.swift:397-411` are line-for-line equal:
  ```swift
  headerWell.leadingAnchor.constraint(equalTo: column.leadingAnchor),
  headerWell.trailingAnchor.constraint(equalTo: column.trailingAnchor),
  headerWell.topAnchor.constraint(equalTo: column.topAnchor),
  headerWell.bottomAnchor.constraint(equalTo: iconWell.bottomAnchor,
                                     constant: GroupsPaneLayout.headerPadding),
  iconWell.topAnchor.constraint(equalTo: column.topAnchor,
                                constant: GroupsPaneLayout.headerPadding),
  ```
  The code admits it: `MainOutDetailViewController.swift:186-188` — "the same five constraints the device pane and the group editor use"; `:206` — "(the device pane's identical break)". `test_headerSectionFrame` is a fourth verbatim copy at `DeviceDetailViewController.swift:1121`, `GroupEditorViewController.swift:1607`, `MainOutDetailViewController.swift:322`.
- Why it matters: this folder's AGENTS.md makes header parity a hard rule ("Header parity is geometric, in `GroupsPaneLayout`"). The *constants* are shared; the *construction* is not, so parity survives only as long as three edits keep landing together. The three-copy `test_headerSectionFrame` means the tests that guard parity are themselves three copies.
- Fix: one `GroupsPaneLayout.installHeader(iconWell:nameLabel:in:column:)` returning the constraint array, plus one `makeScrollingColumn()` for the `FlippedView` + `NSScrollView` + column-width scaffold all three repeat. Call it from all three `loadView()`s.
- Confidence: high

### 5. [SUBSTANCE] Eight controllers build their entire view tree in one `loadView()`, 124 to 405 lines each
- Where: `GroupEditorViewController.swift:285-689` (405) · `DeviceDetailViewController.swift:190-548` (359) · `LicenseGateViewController.swift:152-386` (235) · `GeneralSettingsViewController.swift:168-400` (233) · `MainOutDetailViewController.swift:79-255` (177) · `AboutView.swift:158-292` (135) · `GroupCreationSheetController.swift:137-271` (135) · `GroupsOverviewViewController.swift:90-213` (124)
- Evidence: measured by brace-matching from each `func` line. Each mixes control construction, styling, subview insertion and one `NSLayoutConstraint.activate([...])` of 40–120 entries.
- Why it matters: a cold reviewer cannot hold 405 lines of interleaved construction and constraints in their head, and a constraint conflict in the middle of one has no smaller unit to bisect to. Everything else in this area is sized for reading; these are the exception.
- Fix: the natural seam is already marked by the comment blocks — extract a `makeX()` per visual section returning its view, and one `constraintsForX()` per section returning its slice of the array. `AudioSettingsViewController` already does this (`makeAdvancedContentViews()`, `:666`); make the other eight match it.
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

### 7. [SUBSTANCE] `MixerWindowController` owns no window and is not the Mixer screen
- Where: `AudioutCore/Sources/AudioutWindowUI/MixerWindowController.swift:51`
- Evidence: `public final class MixerWindowController {` — a plain class, not an `NSWindowController`; `grep -n NSWindow Sources/AudioutWindowUI/MixerWindowController.swift` returns nothing. The folder's AGENTS.md opens with "It owns no window and talks to no backend" and its own map entry calls it "screen-content controller". `AppDelegate.groupsScreenContent()` (`:2336`) builds it as the **Groups** screen's content and returns `controller.contentController`; the Mixer is the popover panel, a different screen entirely.
- Why it matters: the rubric's "misleading name" case — the name promises a window controller for the Mixer and the type is neither. The AGENTS.md and the class doc both spend a line correcting it, which is the tell.
- Fix: rename to `GroupsScreenController`. 40-odd references, all inside this package plus three in `AppDelegate`.
- Confidence: high

### 8. [SUBSTANCE] The two sidebars hand-copy their cell builders across package lines
- Where: `AudioutCore/Sources/AudioutSettingsUI/SettingsSidebarViewController.swift:172-190` and `AudioutCore/Sources/AudioutWindowUI/SidebarViewController.swift:917-940`
- Evidence: `private static func newHeaderCell(identifier:)` — same name, same body, modulo comments:
  ```swift
  let cell = NSTableCellView()
  cell.identifier = identifier
  let textField = NSTextField(labelWithString: "")
  textField.translatesAutoresizingMaskIntoConstraints = false
  textField.font = Tokens.Font.captionEmphasized
  textField.textColor = Tokens.Color.label2
  textField.lineBreakMode = .byTruncatingTail
  ```
  Likewise `newIconLabelCell` (`SettingsSidebar:207-231`) is the icon+text half of `newCell` (`Sidebar:990+`), off the same `SurfaceLayout.sidebarIconSize` / `sidebarIconToLabelGap`. The `NSOutlineView` + `NSScrollView` source-list setup is a third copy (`SettingsSidebar:53-73`, `Sidebar` equivalent).
- Why it matters: the Settings sidebar's own doc comment says it is "Deliberately the Groups sidebar's own arrangement… so the two arrangement screens read as one surface" — a stated invariant kept only by two files agreeing. `SurfaceLayout` already exists in `AudioutSharedUI` as the shared home.
- Fix: move `newHeaderCell` and the icon+text cell body into `AudioutSharedUI` beside `SurfaceLayout`, leaving each sidebar its own decorations (the Groups one's active marker and disclosure).
- Confidence: high

### 9. [SUBSTANCE] `DemoPaneView.swift` is 3,344 lines holding 26 top-level types
- Where: `AudioutCore/Sources/AudioutOnboardingUI/DemoPaneView.swift`
- Evidence: `grep -c "^final class\|^class\|^enum\|^public enum"` → 26. `// MARK` sections already name the split: Timeline base (`:481`), palette (`:638`), Prompt mock (`:868`), System alert mock (`:1203`), Settings mock (`:1417`), Two-stage first-ask (`:1692`), Consent card (`:1819`), Settled mock (`:2001`), Drawn parts (`:2499`), iPhone card stage (`:3286`).
- Why it matters: the custom drawing itself is sanctioned by the folder's AGENTS.md ("an approved custom-drawn exception; draw everything, never bundle screenshots") — the doc wins on *that*. It says nothing about one file. 26 types in one file means no reviewer can find the one that draws a given card without scrolling the whole thing.
- Fix: one file per MARK section (`DemoPromptMock.swift`, `DemoSettingsMock.swift`, `DemoSettledMock.swift`, `DemoDrawnParts.swift`, …), keeping `DemoPaneView` itself plus `DemoMode`/`DemoStage`/`DemoMockView` in the current file. Pure file moves.
- Confidence: high

### 10. [SUBSTANCE] Three stored `Task`s in the onboarding controller capture `self` strongly, so `deinit` cannot run until they finish
- Where: `AudioutCore/Sources/AudioutOnboardingUI/OnboardingViewController.swift:511`, `:610`, `:1016`
- Evidence:
  ```swift
  initialStatusesTask = Task { @MainActor in
      await model.refreshStatuses()
      initialStatusesSettled = true
      refresh(animated: false)
  }
  ```
  No `[weak self]`; `initialStatusesSettled` and `refresh` are both `self`. The task is stored on `self` (`:179`), so `self → Task → self` holds until the closure returns. Every *timer* closure in the same file correctly uses `[weak self]` (`:632`, `:657`, `:1303`) — the tasks are the exception.
- Why it matters: `deinit` (`:233-238`) is what invalidates the four polling timers, and it cannot run while a task holds `self`. A `refreshStatuses()` that stalls on a slow probe therefore keeps a closed Setup window's controller and its 1.5 s polls alive. The file already documents an earlier incident of exactly this shape — `AppDelegate.swift:2143-2146`, "orphaning the first window's two live 1.5 s polling Timers … never stopped".
- Fix: `Task { @MainActor [weak self] in ... guard let self else { return } ... }` on all three, matching the timer closures next to them.
- Confidence: medium (the cycle is certain; whether a stall is reachable depends on `SetupModel.refreshStatuses`, which is outside this area)

### 11. [SUBSTANCE] A lone `[unowned self]` among ~60 `[weak self]` captures
- Where: `AudioutCore/Sources/AudioutApp/AppDelegate.swift:1317-1318`
- Evidence:
  ```swift
  groupsContent: { [unowned self] in self.groupsScreenContent() },
  settingsContent: { [unowned self] in self.makeSettingsRoot() })
  ```
  These are the only two `unowned` captures in all four packages (`grep -rn unowned`).
- Why it matters: safe today — `AppDelegate` lives for the process — but it is a crash where every neighbour is a no-op, and it carries no comment saying why it differs. A reviewer has to reconstruct the lifetime argument themselves.
- Fix: `[weak self]` with `guard let self else { return NSViewController() }`, or keep `unowned` and add the one-line lifetime note the rest of this file gives every other non-obvious choice.
- Confidence: high

## Also noted

- `AudioutCore/Sources/AudioutApp/AppDelegate.swift:1817-1834` — `moveToApplicationsAndRelaunch` trashes the existing `/Applications` copy *before* the rename; a rename failure leaves the user with no installed app, only a `.audiout-incoming` bundle and a Trash item. The log line at `:1829-1833` says so, but the user-facing alert (`presentMoveFallbackAlert`) does not.
- `AudioutCore/Sources/AudioutSettingsUI/AppearanceSettingsViewController.swift:290-346` — ~20 raw `NSColor(srgbRed:…)` literals. The root `AGENTS.md` says "do not add … a raw hex/RGB literal anywhere outside this file [`Tokens`]" with no exception; this folder's own AGENTS.md sanctions them ("Theme tiles use absolute sRGB mirrors of the palette; live tokens would lie about appearance"). The code is right and the two docs disagree — fix the root doc, not the code.
- `AudioutCore/Sources/AudioutWindowUI/DeviceDetailViewController.swift:1121`, `GroupEditorViewController.swift:1607`, `MainOutDetailViewController.swift:322` — `test_headerSectionFrame` is the same four lines three times (part of finding 4).
- `AudioutCore/Sources/AudioutApp/AppDelegate.swift:2686-2699` — `applicationShouldTerminate` returns `.terminateLater` for a second Quit and never replies to it. Documented as deliberate at `:609-612`; flagged only because a reader will stop on it.
- Sparkle / PostHog confinement verified clean: `grep -rn "import Sparkle\|import PostHog\|PostHogSDK\|SPUStandardUpdater" Sources/` outside `AudioutApp/` returns zero hits, and `Package.swift:318-319` attaches both products to the `AudioutApp` target only.

## Counts
BUG: 2 · SUBSTANCE: 9 · COSMETIC: 0 · files read: 26 of 41 read substantially (all 41 grep-scanned)
