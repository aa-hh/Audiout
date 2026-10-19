# Test suite — review

## Verdict (3–5 sentences)

This suite is in far better shape than its size suggests: 4,136 tests across 237 files, zero
commented-out tests, zero TODO/FIXME, zero literal self-comparisons, one `withKnownIssue`, and 66% of
tests carry a preceding comment naming what they pin. It also already contains the right answer to
its own worst problem — `SuiteWait` (`AudioutCore/Tests/AudioutCoreTests/SuiteWait.swift`), a single
fail-closed polling helper with an unusually good written rationale — and 180 call sites have moved
to it. The gap is that the migration stopped half-way and nobody swept the residue: 14 suites still
carry their own hand-rolled wait loop that fails OPEN, 59 assertions still follow a fixed
`Task.sleep`/`Thread.sleep` and so assert how fast the machine is, and 23 files each define their own
copy of `tempDirectory()` because `IsolatedSuite` offers an isolated `UserDefaults` but no isolated
directory. The single highest-impact change is to finish the `SuiteWait` migration and add an
`isolatedDirectory` to `IsolatedSuite`, then delete the 14 private wait loops and 23 private
`tempDirectory()` copies that exist only because those two seams were incomplete.

## Findings

### 1. [BUG] `try! #require` crashes the whole test process instead of failing one test

- Where: `AudioutCore/Tests/AudioutCoreTests/HaloRingGapTests.swift:23`,
  `AudioutCore/Tests/AudioutCoreTests/AppRowViewTests.swift:815`,
  `AudioutCore/Tests/AudioutCoreTests/AppRowViewTests.swift:825`
- Evidence:
  ```
  HaloRingGapTests.swift:23:        let path = try! #require(ring.test_ringPath)
  AppRowViewTests.swift:815:        let label = try! #require(row.test_accessibilityLabel)
  AppRowViewTests.swift:825:        let label = try! #require(row.test_accessibilityLabel)
  ```
  Repo-wide: `try #require` — 616 sites. `try! #require` — 3 sites.
- Why it matters: `#require` throws so the runner can fail exactly one test and keep going. `try!`
  turns that into a trap on a nil optional, killing the runner process and taking the other ~4,100
  tests with it — the report then shows a crash, not the one view that stopped exposing its test
  hook.
- Fix: mark the three test functions `throws` and drop the `!`, matching the 616 neighbours.
- Confidence: high

### 2. [BUG] 14 suites still hand-roll a wait loop that fails OPEN, the exact defect `SuiteWait` was written to remove

- Where: `AudioutCore/Tests/AudioutCoreTests/DriftCorrectionApplierTests.swift:146`,
  `OnboardingUITests.swift:330`, `SetupModelTests.swift:518`, `CaptureCoordinatorTests.swift:123`,
  `GroupControllerTests.swift:159`, `PermissionStateObserverTests.swift:115`,
  `CastFakeReceiverLoopTests.swift:49` and `:58`, `CastOutputManagerTests.swift:54`,
  `DACPServerTests.swift:94`, `PassiveDriftSamplerTests.swift:232`,
  `CompanionServerTests.swift:63`, `CompanionEndToEndTests.swift:243`,
  `AirPlayEngine/Tests/AirPlayEngineTests/PTPHelperLifecycleTests.swift`
- Evidence:
  ```swift
  // DriftCorrectionApplierTests.swift:146
  private func waitFor(_ condition: @escaping () -> Bool) async throws {
      for _ in 0..<200 where !condition() {
          try await Task.sleep(nanoseconds: 20_000_000)
      }
  }
  // OnboardingUITests.swift:330
  private func waitUntil(_ satisfied: () -> Bool) async {
      for _ in 0..<600 {                                   // ≤3 s, then give up
          if satisfied() { return }
          try? await Task.sleep(nanoseconds: 5_000_000)
      }
  }
  ```
  Neither records anything on expiry. `SuiteWait.swift:33-42` is explicit about why that is a
  correctness bug, not a flake: "52 of the ~55 waits simply `return`ed when the deadline passed,
  recording nothing… a wait that gives up silently can let a test pass vacuously."
- Why it matters: on a loaded machine (this repo runs up to 4 suites at once plus agents and an
  editor) a starved wait either reports as a failure of the NEXT assertion, or — where nothing after
  it asserts on the awaited state — passes green while the code is broken.
- Fix: make each one a thin forwarder to `SuiteWait.until` / `SuiteWait.untilOnRunLoop` passing
  `sourceLocation` through, exactly as `NativeBackendBTSelectionTests.swift:425` and 20 other suites
  already do. Call sites need no edit.
- Confidence: high

### 3. [BUG] 59 assertions read state that arrives asynchronously after a fixed sleep, so they assert machine speed

- Where: `AudioutCore/Tests/AudioutCoreTests/GroupControllerTests.swift` (14 sites, e.g. `:101`,
  `:111`, `:134`, `:152`), `NativeBackendTests.swift` (9), `AirPlayHandoffWatcherTests.swift` (7,
  e.g. `:125`), `CastFakeReceiverLoopTests.swift` (7, e.g. `:404`),
  `AirPlayEngine/Tests/AirPlayEngineTests/MultiStreamWriteRoutingTests.swift` (3),
  `WriteCadenceTests.swift` (3), plus 16 singles
- Evidence:
  ```swift
  // GroupControllerTests.swift:100
  _ = controller.setDeviceSelected("office", true)
  try await Task.sleep(nanoseconds: 200_000_000)
  #expect(controller.isSpeakerSelected("office"), "the set was composed")
  // AirPlayHandoffWatcherTests.swift:125
  try? await Task.sleep(nanoseconds: 10_000_000) // 10ms for callback
  #expect(fireCount == 1)
  // CastFakeReceiverLoopTests.swift:404
  Thread.sleep(forTimeInterval: 1.3)
  let first = try #require(lead())
  ```
  `200_000_000` appears 29 times in `GroupControllerTests.swift` alone.
- Why it matters: root `AGENTS.md` and `SuiteWait.swift:14-21` both say a deadline is a hang-stop,
  never a performance assertion. A 10 ms window for a cross-actor callback is a coin flip on a busy
  Mac, and a 1.3 s `Thread.sleep` blocks its thread for 1.3 s on every green run. (I separated these
  from the 112 sites where the sleep precedes a NEGATIVE check — "give the wrong thing its chance" —
  which `SuiteWait.swift:78-92` explicitly blesses.)
- Fix: replace each with `await SuiteWait.until("<the state>") { ... }`. The happy path then returns
  on the first satisfied poll, so the suite gets faster as well as steadier.
- Confidence: high

### 4. [BUG] A test puts a real 400 px window on the developer's screen for half a second

- Where: `AudioutCore/Tests/AudioutCoreTests/SurfaceToolbarTests.swift:1024`
- Evidence:
  ```swift
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SurfaceLayout.width, height: 400), ...)
  controller.attach(to: window)
  window.layoutIfNeeded()
  window.orderFront(nil)
  RunLoop.main.run(until: Date().addingTimeInterval(0.2))
  ```
- Why it matters: `AudioutCore/AGENTS.md` states "Tests must stay invisible: nothing a test does may
  reach the screen." This window is at screen origin and stays up for 0.5 s of run-loop pumping on
  every full-suite run.
- Fix: park the window off-screen the way the neighbouring `RailConnectPulseTests.swift:58` already
  does (`NSRect(x: -10_000, y: -10_000, …)`, with its comment "a test must never put anything on the
  developer's actual screen") and `orderFrontRegardless()` / `orderOut(nil)` in a `defer`.
- Confidence: high

### 5. [BUG] `try?` on `#require` turns a failed precondition into a nonsense comparison

- Where: `AudioutCore/Tests/AudioutCoreTests/GroupIdentityGlowViewTests.swift:60`,
  `PassiveDriftSamplerTests.swift:82` and `:83`, `OnboardingPermissionColorTests.swift:338`,
  `ControlPanelBackingViewTests.swift:127`, `AggregateOutputDeviceTests.swift` (1)
- Evidence:
  ```swift
  // GroupIdentityGlowViewTests.swift:60
  let want = try? #require(expected)
  #expect(abs(increased.redComponent - (want?.redComponent ?? -1)) <= 0.004)
  ```
- Why it matters: `#require` exists to stop the test with a readable message. Swallowing its throw
  keeps the test running and then compares against a sentinel, so one missing colour produces three
  further failures reading `abs(0.8 - -1) <= 0.004` instead of "expected was nil".
- Fix: mark the test `throws` and use plain `try #require` — the convention at 616 other sites.
- Confidence: high

### 6. [BUG] A test named for what it protects asserts nothing at all

- Where: `AudioutCore/Tests/AudioutCoreTests/LocalPlaybackEngineTests.swift:285`
- Evidence:
  ```swift
  @Test func meteringHookDoesNotDisturbNormalPlayback() throws {
      ...
      let recorder = LevelRecorder()
      engine.setMeteringActive(true)
      engine.onAppLevel = { recorder.record($0, $1) }
      engine.receive(buffer: constantBuffer(amplitude: 0.3), for: bundleID)
      ...
      engine.receive(buffer: constantBuffer(amplitude: 0.3), for: bundleID)
  }                                       // no #expect anywhere in the body
  ```
  `recorder` is installed and never read.
- Why it matters: root `AGENTS.md` rule 4 — "a test that cannot fail is deleted, not patched". This
  one can only fail by crashing, yet its name promises that metering does not disturb playback. It
  reads as coverage of the metering seam and covers nothing. (The other 11 assertion-free tests are
  deliberate crash-smoke tests that say so in a comment; this is the only one that does not.)
- Fix: assert what the name claims — that `recorder`'s levels arrive while metering is on and stop
  when it is off, and that the post-`removeApp` re-add still forwards.
- Confidence: high

### 7. [SUBSTANCE] 23 private copies of `tempDirectory()`, because `IsolatedSuite` has no isolated directory

- Where: `AudioutCore/Tests/AudioutCoreTests/GroupControllerTests.swift:81`,
  `PopoverControllerTests.swift:77` and `:3976`, `BTRowsUITests.swift:644` and `:965`,
  `MixerWindowControllerTests.swift:98`, `AppRouteStoreTests.swift:9`,
  `AppRoutingControllerTests.swift:9`, `DeviceDetailViewTests.swift:30`, `PopoverIconTests.swift:73`,
  `PopoverBTAlignmentUITests.swift:17`, `PopoverEqualizerEntryTests.swift:20`,
  `PopoverDeviceVisibilityTests.swift:20`, `PopoverDeviceListOverflowTests.swift:20`,
  `PopoverCastSyncOffsetTests.swift:35`, `PopoverLocalSyncTrimTests.swift:33`,
  `MembershipRailTests.swift:21`, `GroupRenameFieldTests.swift:33`,
  `GroupsHeaderParityTests.swift:29`, `GroupsOverviewViewControllerTests.swift:19`,
  `CompanionSnapshotBuilderTests.swift:81`, `SyncDrawerMountedKeyTests.swift:118`,
  `RailConnectPulseControllerTests.swift:19`
- Evidence:
  ```swift
  // MixerWindowControllerTests.swift:98 — and 22 near-identical twins
  private func tempDirectory() -> URL {
      let dir = FileManager.default.temporaryDirectory
          .appendingPathComponent("MixerWindowControllerTests-\(UUID().uuidString)", isDirectory: true)
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      return dir
  }
  ```
  `IsolatedSuite.swift:78` offers `isolatedDefaults` and nothing equivalent for a directory, even
  though `IsolatedSuite.swift:32` says Guard 3 warns on "a bare `temporaryDirectory`" and points
  readers back to that file. 21 of the 29 files that use a bare temp directory never delete it.
- Why it matters: the pre-commit guard sends readers to a file that has no answer for them, so every
  suite invents one and a full run leaves 21 files' worth of UUID directories behind in the system
  temp.
- Fix: add `isolatedDirectory` to `TestIsolation`/`IsolatedSuite`, created on first use and removed
  in the same `deinit` that already removes `isolatedDefaults`, then delete the 23 copies.
- Confidence: high

### 8. [SUBSTANCE] 10 copies of the same colour-comparison assertion, drifted apart and reporting at the wrong line

- Where: `assertSameHue` — `RouteArmedSignalTests.swift:31`,
  `DeviceRowConnectionStateTests.swift:99`, `ControlPanelBackingViewTests.swift:53`,
  `DeviceRowConnectBrightenTests.swift:39`, `FeedColumnTests.swift:323`, `AppRowViewTests.swift:486`.
  `assertSameRGBA` — `PopoverPanelHeaderTests.swift:156`, `DeviceIconWellViewTests.swift:110`,
  `PopoverControllerTests.swift:3876`, `NoteBannerColorTests.swift:16`.
- Evidence: the four `assertSameRGBA` copies are byte-identical. The six `assertSameHue` copies have
  drifted: four use `< 0.01`, `DeviceRowConnectBrightenTests.swift:45` uses `<= 0.01`, and
  `ControlPanelBackingViewTests.swift:59` uses `<= 0.02` and still carries dead XCTest parameters:
  ```swift
  private func assertSameHue(_ a: NSColor?, _ b: NSColor?, _ message: String,
                             file: StaticString = #filePath, line: UInt = #line) {
      ...
      #expect(abs(a.redComponent - b.redComponent) <= 0.02, "\(message) (red)")
  ```
  `file`/`line` are never used, and no `sourceLocation` is forwarded — so every failure in that suite
  and in all four `assertSameRGBA` suites reports at the helper line, not at the failing test.
- Why it matters: a cold reviewer chasing a colour failure lands on a shared helper instead of the
  assertion, and the three different tolerances mean the same drift passes in one suite and fails in
  another.
- Fix: put one `assertSameRGBA(_:_:_:sourceLocation:)` in a shared file next to `SuiteWait.swift`
  with one tolerance, make hue the alpha-ignoring overload, delete the 10 copies.
- Confidence: high

### 9. [SUBSTANCE] `SuiteWait`'s "KNOWN GAP" paragraph is stale and points readers at work that is already done

- Where: `AudioutCore/Tests/AudioutCoreTests/SuiteWait.swift:93-105`
- Evidence: the doc says "of 88 `pollUntil(timeout:)` sites in `NativeBackendTests` alone, 87 carry a
  real positive condition… Those still fail OPEN". Today `NativeBackendTests.swift:1469` defines
  `pollUntil` as a thin forwarder to `SuiteWait.until`, all 489 of its call sites pass no timeout,
  and the only explicit-timeout `pollUntil` left in the repo is
  `PermissionStateObserverTests.swift:201` (`timeout: 0.5`, positive condition).
- Why it matters: this is the most-read helper in the test tree and its own documentation sends the
  next reader to audit 88 sites that no longer exist, while the 5 real survivors
  (`NativeCaptureCoordinatorTests.swift:2248`, `AlignmentTickInjectorTests.swift:684`,
  `NativeBackendCastTests.swift:353`, `NativeBackendBTAlignmentInterceptTests.swift:1839` and
  `:1873`) go unnamed.
- Fix: replace the paragraph with the five surviving file:line references, or delete it and convert
  those five.
- Confidence: high

### 10. [SUBSTANCE] `NativeBackendTests.swift` is 11,104 lines and cannot be reviewed cold

- Where: `AudioutCore/Tests/AudioutCoreTests/NativeBackendTests.swift`
- Evidence: 11,104 lines, 252 tests, 44 `// MARK` sections, two suites; the first `@Suite` does not
  open until line 1,567 — everything before it is spies and fixtures. The next largest file in the
  repo is 4,062 lines.
- Why it matters: `--filter NativeBackendTests` is the inner loop for the whole native backend, and a
  reviewer cannot hold 44 topic sections in their head to tell whether a new test belongs here or
  duplicates one 6,000 lines away.
- Fix: the split convention already exists — `NativeBackendBTSelectionTests`,
  `NativeBackendCastTests`, `NativeBackendBTDevicesTests`, `NativeBackendSyncedLocalSelectionTests`
  are all siblings carved off this file. Continue it along the existing MARK boundaries, and move the
  1,566 lines of spies into a shared fixture file.
- Confidence: high

### 11. [SUBSTANCE] Two permanently-empty test stubs behind an `#else` that can never compile on this platform

- Where: `AudioutCore/Tests/AudioutCoreTests/LocalOutputLatencyTests.swift:58-63`
- Evidence:
  ```swift
  #else
  @Test(.disabled("AudioToolbox unavailable on this platform"))
  func measureReturnsPlausibleNonZeroLatency() throws {}

  @Test(.disabled("AudioToolbox unavailable on this platform"))
  func defaultOutputDeviceIDMatchesMeasuredDevice() throws {}
  #endif
  ```
- Why it matters: this is a macOS-only AppKit package; `canImport(AudioToolbox)` is always true, so
  the `#else` branch is dead. Two empty bodies that can never run read as disabled coverage a
  reviewer might try to re-enable.
- Fix: delete the `#else` branch and the `#if canImport(AudioToolbox)` guards with it. The real skip
  is already handled by `LocalOutputLatencyGate.hasDefaultOutputDevice` at line 11.
- Confidence: high

### 12. [SUBSTANCE] A test passes green on any machine where its precondition cannot be reached

- Where: `AudioutCore/Tests/AudioutCoreTests/GroupControllerTests.swift:872-886`
- Evidence:
  ```swift
  guard controller.selectedDeviceIDs.isEmpty else {
      withKnownIssue("could not reach an empty selection on this fleet") {
          Issue.record("could not reach an empty selection on this fleet")
      }
      return
  }
  ```
- Why it matters: `withKnownIssue { Issue.record(...) }` is a five-line way of writing "do nothing" —
  the recorded issue is immediately absorbed. If the auto-swap behaviour ever reseeds `{local}`
  permanently, this test goes silently green forever while `saveCurrentSetupAsGroup`'s empty-selection
  guard is unprotected. The comment above it already flags the design for human confirmation.
- Fix: seed the controller with a fixture fleet that can reach an empty selection deterministically,
  so the guard becomes unreachable and can be deleted.
- Confidence: medium

### 13. [SUBSTANCE] `try!` on filesystem setup crashes the runner when the temp directory is unwritable

- Where: `AudioutCore/Tests/AudioutCoreTests/AboutSectionTests.swift:31-33`
- Evidence:
  ```swift
  try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  let data = try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
  try! data.write(to: dir.appendingPathComponent("Info.plist"))
  ```
- Why it matters: a full disk — which this repo's own `AGENTS.md` records happening ("Fifteen
  worktrees' SwiftPM caches once filled the disk to zero bytes free mid-build") — turns this into a
  process trap rather than one red test with a readable message. Every neighbouring suite writes
  `try? FileManager.default.createDirectory(...)`.
- Fix: mark the helper `throws` and use plain `try`, or `try?` to match the neighbours.
- Confidence: high

### 14. [COSMETIC] Four files carry test suites with no `@Suite` attribute

- Where: `AudioutCore/Tests/AudioutCoreTests/GroupEditorClickTargetTests.swift:12`,
  `AirPlayEngine/Tests/AirPlayEngineTests/PTPHelperIPCTests.swift`,
  `PTPHelperLifecycleTests.swift`, `PTPYieldBackTests.swift`
- Evidence: `struct GroupEditorClickTargetTests {` with `@MainActor` above it and no `@Suite`, against
  200+ files that all carry one.
- Why it matters: swift-testing discovers them anyway, so nothing breaks — but a reviewer grepping
  `@Suite` to enumerate the suites misses four of them.
- Fix: add `@Suite`.
- Confidence: high

## Also noted

- `AudioutCore/Tests/AudioutCoreTests/CastOutputManagerTests.swift:133` and
  `CompanionServerTests.swift:671` discard the Bool a wait returns (`_ = waitUntil(timeout: 3) {...}`),
  so expiry is indistinguishable from success.
- `AudioutCore/Tests/AudioutCoreTests/NativeBackendTests.swift:8485` — `_ = await
  waitForVolumePush(...)` discards the result; line 2397 in the same file checks it.
- `AudioutCore/Tests/AudioutCoreTests/PopoverExcludedAppsTests.swift:17` names its helper
  `tempRouting()` where 23 other files call the same idea `tempDirectory()`.
- `AudioutCore/Tests/AudioutCoreTests/GroupControllerTests.swift:158` — comment "mirrors
  `PopoverControllerTests.waitForConnectionState`" documents a hand-copy instead of sharing it;
  `PopoverControllerTests.swift:573` is the twin.
- `AudioutCore/Tests/AudioutCoreTests/CaptureCoordinatorTests.swift:125` hardcodes `timeout:
  TimeInterval = 30` rather than referencing `SuiteWait.timeout`, so a change to the one deadline
  misses it; `CompanionServerTests.swift:63` does it correctly.
- Lowest defect-naming comment coverage, for a future sweep:
  `RailConnectPulseTests.swift` 2/26, `AirPlayHandoffWatcherTests.swift` 2/22,
  `MenuBarStatusTests.swift` 5/22, `MockBackendTests.swift` 5/20, `RouteArmedSignalTests.swift` 11/41.
- `AudioutCore/Tests/AudioutCoreTests/PopoverControllerTests.swift` is 4,062 lines with 170 tests and
  two suites — the same split case as finding 10, one order of magnitude smaller.

## Counts

BUG: 6 · SUBSTANCE: 7 · COSMETIC: 1 · files read: 24 / files in area: 237 (all 237 swept by grep
across 16 patterns; 4,136 `@Test` bodies parsed programmatically for assertion presence and for
fixed sleeps preceding an assertion)
