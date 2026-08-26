# T8 — Animation / render / level-path performance

**Branch:** `claude/fix-perf-anim` (fork from the current commit of `claude/macos-app-production-audit-5fcbf3`; working tree is clean — nothing uncommitted to carry).
**Repo root (path has a space — always quote):** `/Users/alechenderson/Projects/AirPlay Controller/.claude/worktrees/xenodochial-ardinghelli-fa348b`

**Owned files (edit ONLY these):**
- `AudioutCore/Sources/AudioutSharedUI/FoldAnimator.swift`
- `AudioutCore/Sources/AudioutSharedUI/BusRailOverlayView.swift`
- `AudioutCore/Sources/AudioutSharedUI/EQResponseCurveView.swift`
- `AudioutCore/Sources/AudioutSharedUI/EQEditorView.swift`
- `AudioutCore/Sources/AudioutCore/NativeBackend.swift` — ONLY line 2024 (the `onLevel` closure) and the block 8632–8856 (`MARK: MeteringControlling … MARK: Emit`). Nothing else in this 9,000-line file.
- Tests: new `AudioutCore/Tests/AudioutCoreTests/FoldAnimatorTests.swift`; additions to `RailConnectPulseTests.swift`, `EQResponseCurveTests.swift`, `NativeBackendTests.swift`.

**Shared-file collision notes (for the runner):**
- `NativeBackend.swift` is shared with T1, which owns the rest of the file (failure causes; the BT accessors at 7632-7634 and 9608-9612). T8's edits stay inside the two regions above.
- `NativeBackendTests.swift` may also receive additions from T1 — test-file overlap merges, does not serialize.
- Do NOT touch `PopoverController.swift` / `PopoverPanelViewController.swift` (T3a) or `LevelMeterView.swift` (T9). `NativeCaptureCoordinator.swift` needs NO edit for this track (verified below) — leave it alone.

**Build/test rule (BINDING):** every compile is `bash scripts/build.sh`; every test run is `bash scripts/run-tests.sh --filter <Suite>` (full suite only for the final check). A bare `swift build` / `swift test` is FORBIDDEN — the wrappers own the remote test mule, the machine-wide concurrency cap and the sources cache. `AUDIOUT_BUILD_LOCAL=1` only if the mule is unreachable, and say so. Never pipe `run-tests.sh` through `| tail` (it eats the exit code — capture to a file and read it). Never kill or abandon an in-flight remote test run (orphaned remote legs pin the build lock).

---

## Goal

Six audit findings (perf P1-8/P3-18, P2-9, P2-10, P2-15, P2-18/P2-25; design P3-6), one theme: this menu-bar app runs 24/7 in venues next to live audio, so steady-state UI work must be frame-paced and the real-time audio thread must never allocate or block. Concretely: FoldAnimator's 120 Hz zero-tolerance `Timer` becomes a vsync-aligned display link and gains the Reduce Motion gate every caller currently re-implements; the rail overlay stops re-stroking on layout passes that moved nothing; the EQ scope stops re-laying-out static ruler text on every drag frame; per-app meter events go through the same 40 ms coalescer device meters already use; and the tap's IOProc thread stops doing a heap-allocating `stateQueue.async` per audio buffer. None of the findings is already fixed — every anchor below was re-verified in this worktree on 2026-08-27.

## Verified facts

(Each checked by reading the file in this worktree. Trust these; if reality disagrees, STOP.)

1. `FoldAnimator.swift:101-105` — the 120 Hz `Timer`, added to `RunLoop.main` in `.common` (a fold under a held mouse-down must keep ticking — comment at :99-100). No `tolerance` set. Class is `@MainActor public final class FoldAnimator` (:36-37), NOT an NSObject subclass. `advance(to:)` at :117-148 is the one tick; `test_settleNow()` at :95 = `advance(to: .greatestFiniteMagnitude)`; `startTimerIfNeeded` guards `timer == nil, !tweens.isEmpty` (:98); `advance` calls `stopTimer()` when `tweens` empties (:147).
2. `NSScreen.displayLink(target:selector:)` returning `CADisplayLink`, `CADisplayLink.add(to:forMode:.common)`, and `.invalidate()` all compile at the deployment floor — probe `xcrun swiftc -typecheck -target arm64-apple-macos14.0` passed in this session. Package floor is `.macOS(.v14)` (`AudioutCore/Package.swift:60`). The in-repo idiom is `LevelMeterView.swift:283-286`: `self.displayLink(target: self, selector: #selector(tick))` + `link.add(to: RunLoop.main, forMode: .default)`, with `@objc private func tick()` (:300) and the strong-target retention note at :95.
3. FoldAnimator has NO Reduce Motion handling (design P3-6). The seam idiom is `test_reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` (`PopoverPanelViewController.swift:205-211`, `DeviceRowView.swift:834-837`, `HaloRingView.swift:316`, others).
4. Every current `FoldAnimator.shared.animate` call site is already RM-gated by its caller: `CardView.swift:290` (gated upstream by `setCardCollapsed`'s `wantsAnimation = animated && !reduceMotion && !HeadlessRuntime.isActive`, `PopoverPanelViewController.swift:782`; also :845, :1018, :1083), `AudioSettingsViewController.swift:482-483`, `EQEditorView.swift:627-628`. The gates also carry `!HeadlessRuntime.isActive`, which the animator will NOT absorb — so no caller gate can be deleted, they merely become redundant on their RM half.
5. `PopoverPanelViewController.swift:772-774` — the stale comment (design P3-6): "The surface resize runs via `panelContentDidChangeHeight(animated:)`, which / already gates itself on `accessibilityDisplayShouldReduceMotion`; the card / animation is gated the same way here so both honor Reduce Motion together." That file is T3a-owned — handoff note only (§Handoffs).
6. `BusRailOverlayView.swift` — `draw(_:)` at :166-171 ignores `dirtyRect` and calls `resolvePlan()`; `resolvePlan()` at :186-216 walks rows/sections and builds a `RailPlan.Input`, then calls the pure `RailPlan.resolve(input)`. `RailPlan`, `RailPlan.Stop`, `RailPlan.Origin`, `MembershipBusView.Node` are all `Equatable` (:800, :803, :814; `MembershipBusView.swift:39`); **`RailPlan.Input` (:841-891) is NOT declared `Equatable`** — its members (Bool, CGFloat, `ClosedRange<CGFloat>?`, `[Stop]`) all are, so conformance is one word. Internal unconditional `needsDisplay = true` sites: :133 (`viewDidChangeEffectiveAppearance`) and :163 (`accentStyleDidChange`). The hot invalidator is `RailStackView.layout()` → `railOverlay?.needsDisplay = true` (`PopoverPanelViewController.swift:1516-1522`, T3a-owned — the design below needs NO change there). The class doc justifies the per-frame resolve during a collapse (:175-185) — that stays.
7. `EQResponseCurveView.swift` — `draw` (:248-255) pins `.darkAqua` then `drawScope()` (:257-282): ground fill + clip, `drawRuler` (three `NSAttributedString` layouts+draws, :288-315), `drawGrid` (:317-341), `drawTrace` (:343-381). Ruler, grid and zero line are plan-INDEPENDENT: `Plan.gridX` is always `Self.bandGridX` (:132, :137, :151). `apply` is already change-guarded with lazy `cachedPlan` + `test_planResolveCount` (:237-244, :178-191) — keep. Type doc forbids `CALayer` (:22-24; AGENTS Map entry "never `CALayer`") — so the cache must be an `NSImage`, not a layer. Both notifications route to `displayOptionsDidChange` → `needsDisplay = true` (:208-218, :229).
8. `EQEditorView.swift:741-745` — `balanceText` builds `"left \(percent) percent"` by raw interpolation (hardening P3 lists exactly `EQEditorView.swift:744`). The endorsed locale idiom is `AudioSettingsViewController.swift:376-384` (`msFormatter`: `NumberFormatter`, `.decimal`). `balanceReadoutText` (:733-737, "L 30%") is pinned by `EQEditorViewTests.swift:108-117` and is NOT in scope.
9. `NativeBackend.swift:2024` — `self.captureCoordinator?.onLevel = { [weak self] rms in self?.emitLevel(rms) }`. `emitLevel` (:8758-8767) opens with `stateQueue.async` — the per-buffer heap enqueue on the tap's IOProc delivery thread (P2-25; handler contract `NativeCaptureCoordinator.swift:479-485` says keep it cheap and lock-light; the call site :1621-1622 is fine as-is and needs no edit). The RT-safe in-repo idiom is `EQProcessor.swift:276-290`: `NSLock` (`mailbox`, :111) taken with `.try()` on the audio thread — a miss skips, never blocks; `NativeCaptureCoordinator.swift:1469` uses `snapshotLock.try()` the same way.
10. The D3 device coalescer (:8634-8645 fields, `scheduleLevelEmit` :8826-8839, `flushPendingLevel` :8844-8849) is keyed by plain `String` id and hard-codes `emit(.level(id:rms:))`. Those five members are referenced NOWHERE else in the file (grep verified). `emitAppLevel` (:8777-8794) emits `.appLevel` DIRECTLY, with the comment at :8774-8776 naming app-level coalescing as "a tracked follow-up". All three app-level sources already funnel through `emitAppLevel`: `routeMixer.onAppLevel` (:1584-1586), `meteringCapture.onBuffer` (:1591-1595), `localPlaybackEngine.onAppLevel` (:2059-2061) — none of those three call sites needs an edit.
11. `setMeteringActive` (:8656-8665) runs `stateQueue.sync { self.meteringActive = active; … }`. `meteringActive` and `latestSystemRMS` are stateQueue-confined (:1325-1332). `stop()` clears `latestSystemRMS` at :2291 (outside T8's region — do not touch).
12. Tests: `NativeBackendTests.swift:4118-4181` (`levelEmissionIsCoalescedToDisplayCadence`) drives `capture.onLevel?(value)` in a 40-step/100 ms burst and asserts ≤8 `.level` events + trailing sentinel — it tolerates the new ≤40 ms delivery latency. :4100-4104 fires one level then sleeps 50 ms before asserting arrival — with the new drain that margin shrinks to ~10 ms (step 12 bumps it). The metering-only-tap harness for `.appLevel` is :6909-6943 (`registeringPerAppCapture`, `tap.push(float32Buffer(...))`, `subscribeLevels`). `RailConnectPulseTests.swift:22-68` has ready-made `StubHook`/`StubRow`/`Scene` fixtures around a real `BusRailOverlayView` in a parked window. `EQResponseCurveTests` (17 tests) pins `Plan` purity + `test_planResolveCount`.
13. Baseline (this session, via `scripts/run-tests.sh`): combined filtered run of NativeBackendTests + EQEditorViewTests + EQResponseCurveTests + BusRailCollapseResolveTests + MembershipRailTests + PopoverControllerRowRevealTests + PopoverControllerRowRevealMotionTests + PopoverEqualizerEntryTests = 324 tests in 10 suites, **2 issues in `orphanedCaptureAfterDeRouteIsStoppedNotAccepted` under parallel load; the same test passed on a solo `--filter NativeBackendTests` re-run (216 tests in 3 suites, all green, exit 0)**. Treat that test as load-flaky: a failure there is arbitrated by a solo re-run of its suite, not by reverting your change.

## Steps

### A — FoldAnimator: display-link clock + Reduce Motion gate (P1-8, P3-18, design P3-6)

**1. Clock swap** (`FoldAnimator.swift`). Make the class an `NSObject` subclass (`@MainActor public final class FoldAnimator: NSObject` — required for the selector target; nothing else changes about its API). Replace the timer with a display link, keeping a Timer fallback for the no-screen case (the remote test mule may have no usable screen):

```swift
private var link: CADisplayLink?
private var timer: Timer?   // fallback only: no screen available

private func startClockIfNeeded() {
    guard link == nil, timer == nil, !tweens.isEmpty else { return }
    // `.common` mode: a fold started by a mouse-down that is still held (a
    // header-row click) has to keep ticking inside event tracking.
    if let screen = NSScreen.main ?? NSScreen.screens.first {
        let l = screen.displayLink(target: self, selector: #selector(clockDidTick))
        l.add(to: RunLoop.main, forMode: .common)
        link = l
    } else {
        let ticker = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance(to: CACurrentMediaTime()) }
        }
        ticker.tolerance = 1.0 / 240.0   // P3-18: allow coalescing on the fallback
        RunLoop.main.add(ticker, forMode: .common)
        timer = ticker
    }
}

@objc private func clockDidTick() { advance(to: CACurrentMediaTime()) }

private func stopClock() {
    link?.invalidate(); link = nil
    timer?.invalidate(); timer = nil
}
```

Rename the `startTimerIfNeeded`/`stopTimer` call sites (:90, :147) to the new names. Delete the old `timer` field/creation. Update the type doc's clock language (vsync-aligned display link, not timer) — keep the one-clock invariant prose intact; only the clock SOURCE changes. Note (deliberate, no code): the link is per-`NSScreen` vsync; `NSScreen.main` is good enough — a wrong-screen link is still frame-paced.

**2. Reduce Motion gate + seam** (same file). Add, following the house seam pattern (fact 3):

```swift
/// Test seam for Reduce Motion (`nil` = the live system setting).
public var test_reduceMotionOverride: Bool?
private var reduceMotion: Bool {
    test_reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
}
```

In `animate(...)`, replace `advance(to: CACurrentMediaTime())` (:89) with `advance(to: reduceMotion ? .greatestFiniteMagnitude : CACurrentMediaTime())` — under Reduce Motion every in-flight fold (including the one just added) settles to its terminal state synchronously in the caller's turn, follower ticked once, completions fired; the start-clock call then no-ops because `tweens` is empty. Document in `animate`'s doc comment: settling instantly is the same synchronous-terminal contract every caller's `animated: false` branch already has. Add a `razor:` comment noting the deliberate ceiling: no mid-flight RM-toggle observer (a fold lasts `Tokens.Motion.collapseRevealDuration`; every caller still gates too) — upgrade path is a workspace-notification observer that settles in-flight tweens.

Do NOT touch the caller gates (fact 4) — their RM halves become redundant belt-and-suspenders; their headless halves are still load-bearing. Do NOT edit `PopoverPanelViewController.swift` (see §Handoffs for its stale comment).

**3. New `FoldAnimatorTests.swift`** (model on the swift-testing style of neighboring suites, `@MainActor`). Two tests, each `defer`-restoring `FoldAnimator.shared.test_reduceMotionOverride = nil` and calling `FoldAnimator.shared.test_settleNow()` (shared singleton — never leak state):
   - Reduce Motion on (`override = true`): build `let v = NSView(); let c = v.heightAnchor.constraint(equalToConstant: 10)`, `animate(c, to: 120, follower: nil)`; assert synchronously after the call: `c.constant == 120`, completion fired, `isFolding == false`.
   - Reduce Motion off (`override = false`): same setup; assert immediately after `animate` that `c.constant < 120` and `isFolding == true` (tick 0 of an eased travel), then `test_settleNow()` → `c.constant == 120` and completion fired.

### B — BusRailOverlayView: memoise the resolved plan, skip no-op invalidations (P2-9)

**4. Memo** (`BusRailOverlayView.swift`). (a) Declare `RailPlan.Input: Equatable` (one word at :841; all members conform — fact 6). (b) Split `resolvePlan()`: extract the :187-215 gather into `private func gatherInput() -> RailPlan.Input?`; `resolvePlan()` becomes `gatherInput().map(RailPlan.resolve)`. (c) Add `private var lastDrawnInput: RailPlan.Input?`; in `draw(_:)`, gather once, record it, resolve from it (do not gather twice inside draw). (d) Intercept the property the host sets (`RailStackView.layout()` does `railOverlay?.needsDisplay = true` — fact 6; this is the design that avoids any PanelVC edit):

```swift
public override var needsDisplay: Bool {
    get { super.needsDisplay }
    set {
        // P2-9: a layout pass that moved nothing must not re-resolve + re-stroke
        // the whole wire. Equal Input ⇒ identical figure (RailPlan.resolve is
        // pure). During a collapse the input changes every frame, so the
        // documented per-frame resolve is untouched.
        if newValue, let last = lastDrawnInput, gatherInput() == last { return }
        super.needsDisplay = newValue
    }
}
```

(e) The two internal invalidations whose redraw is NOT input-driven (appearance :133, accent :163) must force through: set `lastDrawnInput = nil` immediately before their `needsDisplay = true`. Nothing else in the file sets `needsDisplay` (verified). AppKit's own rect-based dirtying (resize etc.) bypasses the property setter — that is fine, it errs toward redrawing.

**5. Tests** — add two `@Test`s to `RailConnectPulseTests.swift` reusing its `makeScene(nodes:)`/`StubRow` fixtures (fact 12):
   - Skip: build a scene, prime the memo with a real draw via `_ = overlay.dataWithPDF(inside: overlay.bounds)` (windowless-deterministic; `draw` runs and records `lastDrawnInput`), then `overlay.needsDisplay = true` → expect `overlay.needsDisplay == false`; mutate geometry-relevant state (e.g. `rows[0].node = .connecting` or `overlay.dormant = true`), set `needsDisplay = true` again → expect `true`.
   - Force: after priming, post `Tokens.accentStyleDidChangeNotification` on `NotificationCenter.default` → expect `overlay.needsDisplay == true` despite unchanged input.

### C — EQResponseCurveView: cache the static figure (P2-10)

**6.** (`EQResponseCurveView.swift`.) Cache ground + ruler + grid + zero line as one `NSImage` (`NSImage(size:flipped:drawingHandler:)` — AppKit caches the rasterization per backing scale; NOT a `CALayer`, which the type doc forbids — fact 7). The handler pins `.darkAqua` itself (it can run outside `draw`'s pinned block) and draws exactly today's `ground.fill()`, `drawRuler`, `drawGrid` content; `drawGrid`'s vertical lines read `Self.bandGridX` directly (plan-independent — fact 7). Store `private var staticFigure: NSImage?`; add `public private(set) var test_staticFigureBuildCount = 0` incremented where the image is CONSTRUCTED (mirror of `test_planResolveCount`). In `drawScope()`: rebuild iff `staticFigure?.size != bounds.size`; draw it; then re-create the ground path for the clip and run `drawTrace` only. Invalidate in `displayOptionsDidChange` (`staticFigure = nil` before `needsDisplay = true`) — that one method already receives both the accessibility and accent notifications (fact 7). Keep `cachedPlan`/`apply` untouched. Amend the type doc's "everything lives in `draw(_:)`" sentence with one line naming the cached static figure and its two invalidation triggers (size, appearance/accent notification).

**7. Test** — in `EQResponseCurveTests.swift`: two `dataWithPDF(inside:)` renders of a laid-out view → `test_staticFigureBuildCount == 1`; post `Tokens.accentStyleDidChangeNotification` → render again → count `== 2`. (If the view's bounds are zero in the harness, give it a frame first — `drawScope` guards on positive plot size.)

### D — EQEditorView: locale-aware spoken percent (hardening P3, :744 only)

**8.** (`EQEditorView.swift`.) In `balanceText` only (:741-745), format the number through a local `private static let` `NumberFormatter` (`.decimal`, `maximumFractionDigits = 0`), mirroring `AudioSettingsViewController.msFormatter` (fact 8); keep the exact words "center" / "left … percent" / "right … percent". Add a `razor:` comment: local duplicate of the locale-number idiom, pending consolidation with T3b's shared helper at wrap-up. Do NOT touch `balanceReadoutText` (:733-737 — test-pinned, not cited by the audit) or `gainText` (typographic-minus rendering is deliberate, :717-729).

### E — NativeBackend level path (P2-18/P2-25, P2-15)

**9. RT-safe RMS slot** (region 8632-8856 + line 2024). Add beside the D3 fields:

```swift
// P2-25: the tap's IOProc thread must not enqueue per buffer. It try-stores
// into this slot (EQProcessor mailbox shape — EQProcessor.swift:277: a miss
// skips, never blocks, never allocates); the stateQueue drain below reads it
// at the D3 cadence.
private let systemRMSLock = NSLock()
private var systemRMSSlot: Float = 0      // systemRMSLock
private var systemRMSDirty = false        // systemRMSLock
private var levelDrainScheduled = false   // stateQueue

private func noteSystemRMS(_ rms: Float) {   // IOProc delivery thread
    guard systemRMSLock.try() else { return }
    systemRMSSlot = rms
    systemRMSDirty = true
    systemRMSLock.unlock()
}
```

Change line 2024 to `self.captureCoordinator?.onLevel = { [weak self] rms in self?.noteSystemRMS(rms) }` (comment there updated to name `noteSystemRMS`). DELETE `emitLevel(_:)` (:8758-8767) and replace it with a stateQueue drain that does exactly what its body did, at the existing `levelEmitIntervalNanos` cadence, only while metering is on:

```swift
private func drainSystemRMS() {   // on stateQueue
    levelDrainScheduled = false
    guard meteringActive else { return }
    systemRMSLock.lock()
    let dirty = systemRMSDirty
    let rms = systemRMSSlot
    systemRMSDirty = false
    systemRMSLock.unlock()
    if dirty {
        latestSystemRMS = rms
        for id in order {
            guard let device = known[id], isMeterable(device), !device.isMuted else { continue }
            emitCombinedLevel(forDevice: id)
        }
    }
    scheduleSystemRMSDrainLocked()
}

private func scheduleSystemRMSDrainLocked() {   // on stateQueue
    guard meteringActive, !levelDrainScheduled else { return }
    levelDrainScheduled = true
    stateQueue.asyncAfter(deadline: .now() + .nanoseconds(Int(levelEmitIntervalNanos))) { [weak self] in
        self?.drainSystemRMS()
    }
}
```

In `setMeteringActive`'s existing `stateQueue.sync` block (:8660-8663), when `active`: clear the slot's dirty flag under `systemRMSLock` (a reading stored while the popover was closed must not replay on reopen) and call `scheduleSystemRMSDrainLocked()`. When inactive the chain stops itself on its next fire. RT rules this step exists for: the IOProc path performs no allocation, no unbounded lock, no dispatch enqueue — a contended `try()` drops the sample and the next ~8 ms buffer refreshes it. Document exactly that at `noteSystemRMS`.

**10. `.appLevel` through the D3 coalescer** (same region). Introduce `private enum LevelKey: Hashable { case device(String), app(String) }` and retype the three coalescer stores (:8639, :8642, :8645) to be keyed by it; `scheduleLevelEmit`/`flushPendingLevel` take a `LevelKey` and emit `.level(id:)` for `.device` / `.appLevel(bundleID:)` for `.app`. `emitCombinedLevel` (:8817) passes `.device(id)`. In `emitAppLevel` (:8780), replace the direct `self.emit(.appLevel(...))` with `self.scheduleLevelEmit(key: .app(bundleID), rms: rms, now: DispatchTime.now().uptimeNanoseconds)`; everything else in that closure (the `latestAppLevel` store, the combined re-emit loop) stays byte-identical. Update the now-satisfied "tracked follow-up" comment at :8774-8776 to say `.appLevel` rides the same D3 sampler keyed by bundle ID. The three source call sites (:1584, :1591, :2059) are untouched.

**11. App-coalescing test** — in `NativeBackendTests.swift`, a sibling of `levelEmissionIsCoalescedToDisplayCadence` (:4118) using the metering-only-tap harness (:6909-6943): metering on, tap registered for one bundle id, push ~40 `float32Buffer` frames over ~100 ms (final buffer at a distinctly higher amplitude, e.g. 0.9 vs ≤0.5), collect `.appLevel` for that id on a dedicated stream task; assert ≥1 and ≤8 events and that the last recorded rms exceeds the mid-burst readings (trailing flush delivered the loudest final buffer).

**12. Timing allowance** — the drain adds up to one 40 ms cadence of delivery latency; bump the single 50 ms sleep at `NativeBackendTests.swift:4101` to 150 ms (its assertion text is unchanged). No other test edit is expected; if `orphanedCaptureAfterDeRouteIsStoppedNotAccepted` fails in a combined run, re-run its suite solo before concluding anything (fact 13).

## Handoffs (report, do NOT edit)

Emit these verbatim in your final report for the wrap-up/T3a lane:
- `PopoverPanelViewController.swift:772-774` — replace the stale sentence with: "Reduce Motion is now gated inside `FoldAnimator.animate` itself (it settles the fold synchronously); the `wantsAnimation` gate below is kept for its `HeadlessRuntime` half and as the caller-side statement of intent."
- The `!reduceMotion` terms at `PopoverPanelViewController.swift:782/:845/:1018/:1083` are now redundant (animator settles instantly) but harmless — leave-or-remove is T3a's call.
- `NativeBackend.swift:3127` (T1 region): doc comment phrase "the next `emitLevel` callback" should read "the next `onLevel` drain" after this track lands.
- `EQEditorView` now carries a local percent `NumberFormatter` pending consolidation with T3b's shared locale helper.

## Out of scope — do not touch

- `PopoverController.swift`, `PopoverPanelViewController.swift` (T3a) — including `RailStackView`; the memo design above requires no hook change.
- `LevelMeterView.swift` (T9). `NativeCaptureCoordinator.swift` (no edit needed). `AppDelegate.swift`, `TouchBarFullBar.swift`, `GroupController.swift`, `MockBackend`, `DeviceRowView.swift`, `AppRowView.swift`, `HaloRingView.swift`.
- In `NativeBackend.swift`: anything outside line 2024 and 8632-8856 — especially :7632/:9608 (T1), `stop()` at :2291, the capture-gate machinery.
- No occlusion handling (P2-12), no row reuse (P2-14), no mouse-monitor consolidation, no `dirtyRect`-driven partial drawing beyond what is specified, no `CALayer` in `EQResponseCurveView`, no RM-toggle observer in `FoldAnimator`, no changes to `balanceReadoutText`/`gainText`, no cleanup, no new abstractions, no backwards-compat shims. Do not regenerate any snapshot goldens (`window-snapshot` goldens are unreproducible — house rule); nothing here may change a settled render: the all-expanded rail draw and the settled scope draw must stay pixel-identical.

## Verification

Baseline (pre-change, observed this session): fact 13 — all listed suites green (one known load-flake, arbitration rule stated there).

Run, in the worktree, capturing output to a file (never `| tail`):

```bash
bash scripts/build.sh
bash scripts/run-tests.sh --filter NativeBackendTests --filter EQEditorViewTests \
  --filter EQResponseCurveTests --filter BusRailCollapseResolveTests \
  --filter MembershipRailTests --filter RailConnectPulseTests \
  --filter PopoverControllerRowRevealTests --filter PopoverControllerRowRevealMotionTests \
  --filter PopoverEqualizerEntryTests --filter FoldAnimatorTests
bash scripts/run-tests.sh   # full suite, once, at the end
```

Expected: build clean; filtered run all-pass including the ~7 new tests (steps 3, 5, 7, 11); full suite all-pass (~874+ tests; a single failure in a suite this track did not touch → re-run that suite solo per fact 13 and report both outputs). Done = these commands ran in YOUR session and passed, with output pasted. Note Guard 7 requires `scripts/self-review.sh` on the staged diff before any Swift commit; Guard 1 forbids committing on `main` — commit on `claude/fix-perf-anim` and push to `origin/claude/fix-perf-anim`.

## Acceptance checklist

- [ ] `FoldAnimator` ticks from a `CADisplayLink` added in `.common` mode; Timer survives only as the no-screen fallback, with tolerance; class is `NSObject`-based; one-clock doc prose intact.
- [ ] `FoldAnimator.animate` settles synchronously under Reduce Motion via `test_reduceMotionOverride ?? live`; no caller gate was edited.
- [ ] `RailPlan.Input: Equatable`; overlay skips `needsDisplay = true` when the freshly gathered input equals the last drawn one; appearance/accent invalidations force through by clearing the memo.
- [ ] EQ scope's ground/ruler/grid/zero-line render at most once per (size, appearance/accent) as a cached `NSImage`; `draw` strokes only the trace over it; no `CALayer`.
- [ ] `balanceText` digits go through a `NumberFormatter`; `balanceReadoutText` untouched (its 3 tests still pass unmodified).
- [ ] IOProc thread performs zero allocation and zero dispatch on the level path (`try()`-store only); `.level` cadence still ≤ ~25 Hz with trailing-edge delivery (existing D3 test passes).
- [ ] `.appLevel` is coalesced per bundle id through the shared sampler; the three emit-source call sites and `NativeCaptureCoordinator` are diff-free.
- [ ] `git diff --stat` shows ONLY the five owned source files + the four test files; `NativeBackend.swift` hunks fall only at :2024 and inside :8632-8856.
- [ ] Handoff notes reproduced in the final report.

## Open decisions (already made — defaults, do not re-litigate)

1. Display-link source = `NSScreen.main ?? NSScreen.screens.first` (animator has no view; a torn-down view's link would pause mid-fold and strand other tweens). Timer fallback covers a screenless process.
2. RM-on `animate` settles ALL in-flight tweens (`advance(to: .greatestFiniteMagnitude)`) — same semantics as `test_settleNow`, and unreachable-in-practice today because callers gate.
3. Rail memo intercepts the `needsDisplay` SETTER (not `draw`) because a skipped draw on a layer-backed view must simply keep its committed contents; AppKit's rect-based dirtying bypasses it conservatively.
4. EQ static figure = `NSImage(size:flipped:drawingHandler:)` (per-scale cached), because the type forbids `CALayer` and `NSImage.lockFocus` is deprecated at the floor.
5. Level drain = self-rescheduling `stateQueue.asyncAfter` at `levelEmitIntervalNanos`, armed only while `meteringActive` — chosen over a single-flight enqueue from the audio thread, which would still dispatch from the RT thread.
6. Coalescer key = `enum LevelKey { case device(String), app(String) }` — prevents any device-id/bundle-id collision in the shared maps.

## Execution plan

| Track | Steps | Files | Model / effort | Concurrency |
|---|---|---|---|---|
| A | 1-3 | FoldAnimator.swift, FoldAnimatorTests.swift (new) | sonnet / medium | PARALLEL |
| B | 4-5 | BusRailOverlayView.swift, RailConnectPulseTests.swift | sonnet / medium | PARALLEL |
| C | 6-8 | EQResponseCurveView.swift, EQEditorView.swift, EQResponseCurveTests.swift | sonnet / low | PARALLEL |
| D | 9-12 | NativeBackend.swift (:2024 + :8632-8856), NativeBackendTests.swift | opus / medium | PARALLEL |

All four tracks touch disjoint files (test-file overlaps with other T-tracks merge). Branch forks from a clean committed tree — no uncommitted work to carry. Verification runs ONCE on the combined result after merge.

## Executor rules (verbatim)

> - Follow the steps in order. Do not add, merge, reorder, or skip steps.
> - If reality contradicts a Verified fact or a step is impossible as written, STOP and report the discrepancy. Do not improvise a workaround.
> - Before reporting progress, audit each claim against a tool result from this session. Only report work you can point to evidence for. If tests fail, say so with the output.
> - "Done" means the Verification commands were run in this session and passed. Paste their output.
> - Touch nothing in the Out-of-scope list.
> - Deliver what was asked, at the scope intended. If the spec seems mistaken or a better approach exists, say so in a sentence and continue as specified rather than quietly narrowing, widening, or transforming it.
