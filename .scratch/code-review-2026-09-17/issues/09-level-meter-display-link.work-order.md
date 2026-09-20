_Revised after spec check: two line ranges corrected, HaloRingView claim narrowed, autoreleasepool claim softened, two failure/scope rulings added._

# Work order — 09: LevelMeterView stops its display link when it leaves its window

Worktree: `/Users/alechenderson/Projects/AirPlay Controller/.claude/worktrees/cr-09-level-meter-display-link` (clean, at `a14ff11f`).

### Goal
`LevelMeterView` tears down its `CADisplayLink` only when the bar has eased to rest with a zero target. A popover `rebuild()` throws rows away mid-signal, so a meter that still has a non-zero target keeps a live display link, the link keeps a strong reference back to the view, and that orphan ticks for the life of the app — the row and everything it holds stay alive. Add the `viewDidMoveToWindow` override the sibling views already have, so a meter that loses its window resets and stops ticking.

### Verified facts
All paths relative to the worktree above.

1. `LevelMeterView` has no `viewDidMoveToWindow` override — the file is 338 lines and the only `view…` overrides are `viewDidChangeEffectiveAppearance` at `AudioutCore/Sources/AudioutSharedUI/LevelMeterView.swift:163` and `updateLayer` at `:159`.
2. The link is stopped in exactly three places: `setLevel`'s Reduce-Motion branch `LevelMeterView.swift:240`, `setLevel`'s already-at-rest branch `:250`, `tick()`'s rest check `:309`, plus `deinit` `:144` — which never runs while the link retains the view.
3. The display link retains the view: documented at `LevelMeterView.swift:86-88` ("keeps a strong reference to the target (self) while the display link is active"), created at `:286-288`, stored in `private var activeLink` `:88`.
4. `reset()` at `LevelMeterView.swift:258-263` sets `target = 0`, `displayed = 0`, redraws, and calls `stopDisplayLink()`. It is exactly the behaviour the ticket asks for, so the ticket's suggested one-liner is correct for this file — no new private helper is needed.
5. Restart after re-insertion is automatic: `setLevel` calls `startDisplayLinkIfNeeded()` at `:253`, which creates a link whenever `activeLink == nil` (`:284-289`). So a meter re-added to a window starts ticking again on the host's next `setLevel(>0)`. No restart code is needed in `viewDidMoveToWindow`.
6. Sibling pattern, `MembershipBusView.swift:218-221`: `viewDidMoveToWindow` calls `super`, then `if window == nil { settleGrowth() }`; `settleGrowth()` at `:184-189` invalidates and nils the growth link. `HaloRingView.swift:374-380` also overrides `viewDidMoveToWindow` but has no `window == nil` guard (it calls `reconcileBreathing()` and `cancelReceiveBloom()` unconditionally) — only `MembershipBusView` has the shape step 3 asks for.
7. `MembershipBusView` exposes `public var test_reduceMotionOverride: Bool?` at `:229` and reads it at `:232` as `test_reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`. `HaloRingView` has the identical hook at `:458`, read at `:342`.
8. `LevelMeterView` has NO Reduce-Motion override hook: `private var reduceMotion` at `LevelMeterView.swift:266-268` reads `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` directly. Under Reduce Motion, `setLevel(0.5)` snaps and never starts a link (`:236-243`) — a test that asserts "link running" would fail on a Mac with Reduce Motion on.
9. Existing `test_` hooks on this view are `test_setDisplayedLevel` `:318`, `test_targetLevel` `:327`, `test_displayedLevel` `:330`, `test_gradientColors` `:335` — all `public`, all documented. `HaloRingView.swift:467` shows the boolean-hook naming: `test_isBreathing`.
10. `LevelMeterViewTests` today is pure-function only: 6 tests, no view instance, no window; imports are `CoreGraphics`, `Testing`, `@testable import AudioutSharedUI` at `AudioutCore/Tests/AudioutCoreTests/LevelMeterViewTests.swift:3-5`; suite declared `@Suite struct LevelMeterViewTests` at `:11` with no `@MainActor`.
11. The off-screen window pattern to reuse is `AudioutCore/Tests/AudioutCoreTests/MembershipBusTests.swift:268-269`: `NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 60, height: 40), styleMask: .borderless, backing: .buffered, defer: false)`, then `window.contentView!.addSubview(view)` (`:276`) and `view.removeFromSuperview()` (`:282`, commented "settles the tween; nothing ticks off screen"). That suite is `@MainActor @Suite` (`MembershipBusTests.swift:18-19`).
12. The weak-reference deallocation pattern already used in this test target: `AudioutCore/Tests/AudioutCoreTests/DefaultOutputDeviceMonitorTests.swift:257-270` — `weak var weakDropped:` declared outside, strong instance created inside a `do { }` scope, then `#expect(weakDropped == nil, "…")`.
13. `rebuild()` discards rows: `AudioutCore/Sources/AudioutPopoverUI/PopoverController.swift:1638-1644` — `deviceRowsByID.removeAll()` at `:1643` with the comment at `:1644` "The mounted panel views die with their rows".
14. Folder rules that bind this change: `AudioutCore/AGENTS.md:12` "Tests must stay invisible: nothing a test does may reach the screen." `AudioutCore/Sources/AudioutSharedUI/AGENTS.md:13` "`test_*` hooks must drive the same delegate path as the live control." Root `AGENTS.md:148-149` "A new test NAMES ITS DEFECT — one comment sentence stating the code change that would turn it red."
15. Baseline, run in this session with `AUDIOUT_TEST_NO_CACHE=1 bash scripts/run-tests.sh --filter LevelMeter`: `Test run with 6 tests in 1 suite passed after 0.036 seconds.`

### Steps

1. **Add the two test hooks to `LevelMeterView`** (`AudioutCore/Sources/AudioutSharedUI/LevelMeterView.swift`, in the existing `// MARK: Test-support hooks` section that starts at `:313`, after `test_gradientColors` ends at `:337`). Add a public computed property named `test_isDisplayLinkRunning` returning whether `activeLink` is non-nil, with a doc comment saying it lets tests assert the zero-CPU-at-rest teardown without reaching into Core Animation (same role as `HaloRingView.test_isBreathing`, `HaloRingView.swift:467`). Add a public stored property named `test_reduceMotionOverride` of type `Bool?`, doc-commented as the Reduce-Motion test seam (`nil` = the live system setting), matching `MembershipBusView.swift:229` and `HaloRingView.swift:458`. Then change `private var reduceMotion` at `:266-268` to read `test_reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`, exactly as `MembershipBusView.swift:232` does. No other behaviour changes in this step.

2. **Write the failing test** in `AudioutCore/Tests/AudioutCoreTests/LevelMeterViewTests.swift`. Add `import AppKit` alongside the existing imports at `:3-5`. Append a new `// MARK:` section after the last test (file currently ends at `:98`) with one `@MainActor @Test` function named `meterLeavingItsWindowStopsTickingAndDeallocates`. Leave the rest of the suite untouched — do not add `@MainActor` to the suite declaration at `:11`.

   The test body, in order:
   - Create the off-screen borderless window using the literal from `MembershipBusTests.swift:268-269` (x: -10_000, y: -10_000, width 60, height 40), held in the outer scope.
   - Declare `weak var weakMeter: LevelMeterView?` in the outer scope.
   - Inside an `autoreleasepool { }` containing a `do { }`-style scope for the strong reference: construct a `LevelMeterView()`, assign it to `weakMeter`, set `test_reduceMotionOverride = false`, add it to `window.contentView!`, call `setLevel(0.5)`, and assert as a precondition that `test_isDisplayLinkRunning` is `true` and `test_targetLevel` is greater than zero. Then call `removeFromSuperview()` and assert `test_isDisplayLinkRunning` is `false` and `test_targetLevel` is `0`. The strong reference must go out of scope before the pool closes. The `autoreleasepool` is a precaution: AppKit may autorelease a reference during `removeFromSuperview`, so drain the pool before checking deallocation. No existing test in this target asserts an NSView deallocates, so this is unproven here.
   - After the pool, `#expect(weakMeter == nil, …)` with a message saying a stopped link releases its target so the orphaned row can die.
   - Name the defect in one comment sentence above the test, per root `AGENTS.md:148`: deleting the `viewDidMoveToWindow` override from `LevelMeterView` turns this test red — the meter keeps a live display link, keeps ticking off screen, and never deinits.

   Run `bash scripts/run-tests.sh --filter LevelMeter` now and paste the output. It must show `Test run with 7 tests` with `meterLeavingItsWindowStopsTickingAndDeallocates` failing on the "link stopped" assertion (and, if execution gets that far, on `weakMeter == nil`). A green run here means the test is not seeing the defect — stop and report.

3. **Add the fix** to `AudioutCore/Sources/AudioutSharedUI/LevelMeterView.swift`: a `public override func viewDidMoveToWindow()` that calls `super.viewDidMoveToWindow()` and then calls `reset()` when `window == nil`. Place it immediately after `viewDidChangeEffectiveAppearance` (ends `:166`), before the `updateLayerColors()` private method at `:168`. Give it a one- or two-sentence doc comment in the register of `MembershipBusView.swift:216-217`: a meter whose row is discarded by a popover rebuild has nothing left to show, so it zeroes and stops rather than ticking off screen forever. Nothing else in the file changes — `setLevel`, `tick()`, `reset()` and the start/stop helpers stay exactly as they are.

4. **Re-run** `bash scripts/run-tests.sh --filter LevelMeter` and paste the output: 7 tests, all passing.

   If the link-stopped and target-zero assertions pass but `#expect(weakMeter == nil)` alone fails: do NOT loosen or delete that assertion, do NOT add `removeObserver` calls or any other `deinit` change. Stop and report the exact output as a spec/reality discrepancy.

### Out of scope — do not touch
- `PopoverController.swift`, `DeviceRowView.swift`, `AppRowView.swift`, `MainOutRowView` — no caller changes. The host's existing `setLevel` calls are correct.
- `MembershipBusView.swift`, `HaloRingView.swift`, `AlignmentStageView.swift` — read-only references; do not "align" them.
- Do NOT add a `window != nil` guard to `setLevel` or to `startDisplayLinkIfNeeded`. Off-window `setLevel` still works by design, and snapshot tests rely on driving meters without a window (`test_setDisplayedLevel`, `LevelMeterView.swift:318`).
- Do not change the ballistics constants, the dB mapping, the gradient, the layer setup, or any existing test in `LevelMeterViewTests`.
- Do not touch the two notification observers registered at `LevelMeterView.swift:117-130` or add `removeObserver` to `deinit`; that is not this ticket.
- Do not edit `.scratch/code-review-2026-09-17/issues/09-level-meter-display-link.md` (its Status line is managed by the orchestrator).
- Do not commit, push, create a branch, or open a PR.
- No cleanup, no abstractions, no error handling for impossible cases, no backwards-compat shims.

### Verification
```bash
bash scripts/run-tests.sh --filter LevelMeter
```
Expected final line: `Test run with 7 tests in 1 suite passed` (a duration follows). Trust only a line containing `Test run with N tests` — a filter that matches nothing prints a green summary with no tests.

Pre-change baseline observed in this scoping session: `Test run with 6 tests in 1 suite passed after 0.036 seconds.`

Test seam: `AudioutCore/Tests/AudioutCoreTests/LevelMeterViewTests.swift:11` (`@Suite struct LevelMeterViewTests`), the seam named by the ticket. Defect the new test catches: a `LevelMeterView` with a non-zero level removed from its window keeps its `CADisplayLink` running, which retains the view, so it ticks forever and never deinits.

If a compile check is wanted separately from the test run, it is `bash scripts/build.sh`. Never a bare `swift build`, `swift test`, `swift run`, or `xcodebuild`.

### Execution plan
One track, all four steps in order — the test and the fix touch two files that only make sense together.

- **Track A — LevelMeterView display-link teardown.** Files: `AudioutCore/Sources/AudioutSharedUI/LevelMeterView.swift`, `AudioutCore/Tests/AudioutCoreTests/LevelMeterViewTests.swift`.
- **Model:** sonnet. **Effort:** medium — the edit is small, but the autorelease/deallocation detail in step 2 has to be got right.
- **Concurrency:** single track, nothing to parallelise. Working tree is clean at `a14ff11f`, so no uncommitted work is depended on.

### Executor rules (copy verbatim into the handoff prompt)
> - Work only in `/Users/alechenderson/Projects/AirPlay Controller/.claude/worktrees/cr-09-level-meter-display-link`. Use absolute paths; never `cd` to another checkout.
> - Follow the steps in order. Do not add, merge, reorder, or skip steps.
> - Before editing in any folder, read the nearest AGENTS.md above it (and the root one) — here that means `AGENTS.md`, `AudioutCore/AGENTS.md`, and `AudioutCore/Sources/AudioutSharedUI/AGENTS.md`. Folder rules and traps bind even when the work order doesn't repeat them.
> - If reality contradicts a Verified fact or a step is impossible as written, STOP and report the discrepancy. Do not improvise a workaround.
> - Tests go ONLY through `bash scripts/run-tests.sh --filter LevelMeter`; compiles ONLY through `bash scripts/build.sh`. Never a bare `swift test`, `swift build`, `swift run`, `swift package`, or `xcodebuild` — the hook denies them and they bypass the capacity permits and the second Mac.
> - Trust only a line reading `Test run with N tests` — a filter that matches nothing prints a green summary. Never judge a run by the word "passed" alone.
> - Run the new test BEFORE making the fix and paste the failing output. A test that passes before the change proves nothing.
> - Before reporting progress, audit each claim against a tool result from this session. Only report work you can point to evidence for. If tests fail, say so with the output.
> - "Done" means the Verification command was run in this session and passed. Paste its output.
> - Do not commit, push, branch, or open a PR. Leave the change in the working tree.
> - Touch nothing in the Out-of-scope list.
> - Deliver what was asked, at the scope intended. If the spec seems mistaken or a better approach exists, say so in a sentence and continue as specified rather than quietly narrowing, widening, or transforming it.
