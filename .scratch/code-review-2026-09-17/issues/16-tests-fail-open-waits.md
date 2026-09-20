# 16 — Test suite: finish the SuiteWait migration and remove the assertions that assert machine speed

Status: ready-for-agent
Wave: 3
Pipeline model: opus mode
Source: [REVIEW.md](../REVIEW.md), findings tests #1, tests #2, tests #3, tests #4, tests #5, tests #6

14 suites hand-roll a wait loop that fails open; 59 assertions follow a fixed sleep; one `try! #require` crashes the runner; one `try? #require`; one test asserts nothing; one puts a real window on screen.

## Done when

Every hand-rolled wait is replaced by `SuiteWait`; every fixed-sleep-then-assert becomes a `SuiteWait` on the observed condition; `try!`/`try?` on `#require` become plain `try`; the no-assertion test asserts what its comment names; the window test runs headless. `AUDIOUT_TEST_MODE=serial` full suite green once (paste the `Test run with N tests` line).

## Test seam

the touched suites themselves

## Verification

```bash
AUDIOUT_TEST_NO_CACHE=1 bash scripts/run-tests.sh
```

## Findings (verbatim from the area reports)

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
