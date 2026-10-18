Revised after the owner added the alignment-intercept flake from run 37172910789 (Track D); replaces the first version of 2026-10-04.

# Work order: fix or re-justify the 19 CI quarantines (issue #258) plus the alignment-intercept flake

## Goal

Make the tests quarantined under issue #258 hold on the GitHub `macos-26` runner (3 cores, no awake display, Reduce Motion reported ON) so the quarantines can come off, and record which tests legitimately stay quarantined. The repo's merge gate is the full suite on that runner, so every skipped test is a hole in the gate. Three real root causes were found by reading the two failing runs' logs: (1) ten tests read the runner's live Reduce Motion setting through a seam the test never pinned; (2) one test renders at the runner's 1x pixel density instead of the authored 2x; (3) shard 1 runs 645 tests in one process where `CompanionServerTests` hot-spins a cooperative thread for its waits (218,769,038 polls in 120 s in run 37167357043), which starves `DispatchQueue.global()` work and every other suite in that process. The AirPlayEngine cadence tests measure real sleep accuracy; three of the four can use the tracker's injectable clock, one cannot and stays quarantined. One further CI-only flake (`auditionUsesIndependentWizardPacerAndKeepsOnlyPairAudible`) is a 4-second production deadline racing a starved runner; the file already has the pattern for it.

## Verified facts

Runner behaviour (from the failing logs):
- Run 37167357043 shard 1 ran as ONE process, "Test run with 645 tests in 28 suites", all suites started at once (log lines 36226-36251 of `gh run view 37167357043 --log-failed`). `scripts/run-tests.sh:322-334`: Swift Testing runs tests concurrently in one process; `--parallel` adds no worker fan-out.
- In that run `CompanionServerTests.commandRoundTripDeliversTheReply` recorded "timed out after 120.0s (218769038 polls)" — a busy loop — while all four `PermissionStateObserverTests` waits recorded "timed out after 120.0s (1 polls)" (log lines 36740, 37044, 37046, 37050).
- `SurfaceToolbarTests.theSelectedHighlightIsConcentricWithTheCapsulesBorder` failed at 160° and 200° only, both appearances: outside alpha 0.1098 against bare 0.0588 (log lines 113689-113696). Bare 0.0588 ≈ `capsuleRestFillAlpha` 0.06 (`SurfaceToolbarSeatButton.swift:150`), so Increase Contrast is OFF on the runner (it would multiply by `increaseContrastGain` 1.5, line 187). The straddle at 1 pt outside the highlight edge is a 1x-pixel sampling artefact; the test passes on the owner's 2x Macs.
- Run 37172910789 attempt 1 shard 3: `auditionUsesIndependentWizardPacerAndKeepsOnlyPairAudible` got `start.value → "The speaker pair changed before clicks could start."` at line 445, then timed out at 446 and failed 449 (attempt-1 log lines 4236, 4714-4716). Trivial tests in that attempt took 80-104 s (`LicenseGateTrialAnalyticsTests passed after 103.806 seconds`).

Reduce Motion seams (each reads `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` unless its override is non-nil):
- `DeviceRowView.test_reduceMotionOverride` / `reduceMotion` — `AudioutCore/Sources/AudioutSharedUI/DeviceRowView.swift:904-908`; the row re-runs `updateBus()` on `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification` (observer registered at `DeviceRowView.swift:450-454`, handler at 921-934). `busNode(...)` renders `.connecting` for the energize beat only when `energizePending, !reduceMotion, case .off` (`DeviceRowView.swift:857`).
- `PopoverController.test_reduceMotionOverride` (`PopoverController.swift:3760`) feeds only `beginEnergize` (`PopoverController.swift:2910-2912`); it is NOT forwarded to rows — `row.apply(... energizePending:)` at `PopoverController.swift:3158` and `3217` passes no motion flag.
- `PopoverController.test_deviceRow(for:)` returns `deviceRowsByID[id]` (`PopoverController+TestSupport.swift:11-13`).
- `SetupRibbonView`: `let spins = status.spins && !reduceMotion; statusSpinner.isHidden = !spins` (`SetupRibbonView.swift:503-504`); `test_isWaiting` is `!statusRow.isHidden && !statusSpinner.isHidden` (line 643); override var at line 646. `OnboardingViewController.test_ribbonReduceMotionOverride` (public, `OnboardingViewController.swift:2294-2297`) sets it. The row's `test_isWaiting` is independent of Reduce Motion — `reduceMotionDropsTheLocalNetworkWaitSpinners` (`OnboardingUITests.swift:875-879`) asserts `!test_ribbonIsWaiting` AND `test_rowIsWaiting(.localNetwork)` under override `true`.
- `FoldAnimator.test_reduceMotionOverride` (`FoldAnimator.swift:78`); `animate(...)` settles synchronously under Reduce Motion: `advance(to: reduceMotion ? .greatestFiniteMagnitude : now)` (`FoldAnimator.swift:133`). `FoldAnimator.shared` is a process-wide singleton; `test_settleNow()` at line 139.
- `CardView.setBodyCollapsed(animated:)` hands the fold to `FoldAnimator.shared.animate` (`CardView.swift:420`); `PopoverPanelViewController.foldAnimator: FoldAnimator = .shared` (`PopoverPanelViewController.swift:251`) drives `insertRow`/`removeRow` (`:1124`, `:1158`, `:1277`); its own `test_reduceMotionOverride` (line 247) only decides whether the animated path is taken.
- Existing set/restore pattern: `FoldAnimatorTests.swift:21-25` — `defer { FoldAnimator.shared.test_reduceMotionOverride = nil; FoldAnimator.shared.test_settleNow() }` then set the override.
- Existing notification-driven re-derive pattern: `EnergizeTests.swift:84-86` sets `row.test_reduceMotionOverride` then posts `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification` on `NSWorkspace.shared.notificationCenter`.

Quarantined tests and their files:
- `EnergizeTests.swift:156` (`sourceSwitchRaisesPendingBeatOnOffMembersAndAnnounces`, suite is `@MainActor final class ... : IsolatedSuite`, line 30-31). Failing assertion at line 168.
- `OnboardingUITests.swift:835, 916, 933, 1209`; `makeVC` at 290-296.
- `CardViewCollapseTrajectoryTests.swift:107`; doc comment at lines 32-34 wrongly says the animated path runs "regardless of the CI machine's accessibility settings". Suite is `@MainActor @Suite final class ... : IsolatedSuite` (line 36-37).
- `PopoverControllerRowRevealMotionTests.swift:56, 74`; both already call `FoldAnimator.shared.test_settleNow()` (lines 67, 84). Suite `@MainActor @Suite struct` (line 24-25).
- `PopoverControllerRowRevealTests.swift:200` (`reMountingDuringAnAnimatedCloseEvictsTheStaleClip`); calls `FoldAnimator.shared.test_settleNow()` at 215. Suite `@MainActor @Suite struct` (24-25).
- `SurfaceToolbarTests.swift:864`; `render(_:appearanceName:)` at 418-424 uses `view.bitmapImageRepForCachingDisplay(in:)` + `cacheDisplay(in:to:)`; `color(_:atPoint:in:)` at 431-437 already scales the probe by `rep.pixelsWide / bounds.width`; `render(` has 9 call sites in the file. Precedent for an explicit `NSBitmapImageRep(bitmapDataPlanes:pixelsWide:pixelsHigh:bitsPerSample:samplesPerPixel:hasAlpha:isPlanar:colorSpaceName:bytesPerRow:bitsPerPixel:)`: `AlignmentPlateCellTests.swift:83-86`.
- `CompanionServerTests.swift:346`; `@Suite struct CompanionServerTests` (line 18, not `@MainActor`); 33 `@Test`s, 75 `waitUntil` call sites, `waitUntil` at 63-69 wraps `SuiteWait.untilOnRunLoop`; `Thread.sleep(forTimeInterval: 1.5)` at 834 and `0.2` at 1091; `makeHub()` (line ~117) and `connectClient` (130-160) call `waitUntil`. `SuiteWait.swift` says `untilOnRunLoop`/`settle` only wait on the main thread ("returns in 0.003s on a secondary thread and 0.00002s on a cooperative-pool thread", `SuiteWait.swift:177-181`). Async precedent in the same target: `CompanionEndToEndTests.swift:243-250` (`nonisolated private func waitUntil(...) async -> Bool` over `SuiteWait.until`) with call sites `try #require(await waitUntil { ... }, "...")` at 291, 319, 322.
- `PermissionStateObserverTests.swift:138, 155, 174, 264`; suite is `IsolatedSuite` (`@MainActor`, `IsolatedSuite.swift:195-196`); its `pollUntil` (118-125) wraps async `SuiteWait.until`; its only `Thread.sleep`/`RunLoop` hit is a doc comment at line 131; `SpawnLedger` completes via `DispatchQueue.global().asyncAfter` (line 53).
- `.github/workflows/tests.yml:59` (shard 1 regex) names `CompanionServerTests` and `PermissionStateObserverTests`; line 61 (shard 2) has `...CompanionLicenseActivationTests|CompanionSnapshotBuilderTests...`; line 63 (shard 3) has `...PermissionModeTests|PhaseControllerTests...`. The shard-1 comment (lines 48-56) defines membership as files holding blocking waits.
- `AirPlayEngine/Tests/AirPlayEngineTests/WriteCadenceTests.swift:29, 239, 390`; `SchedulingProbeTests.swift:90`. `WriteCadenceTracker.init(stallGapSeconds: Double = 5.0, now: @escaping () -> Double = WriteCadenceTracker.monotonicSeconds)` (`AirPlayEngine/Sources/AirPlayEngine/AirPlayEngine.swift:2002`); `symmetricJitterInflatesBucketsButNotNetDrift` and `mixedGapsNetExactly` already use `WriteCadenceTracker(now: { simulatedSeconds })` (`WriteCadenceTests.swift:200, 283`). `WriteSchedulingProbe.init(logInterval: Double = 5.0, ringCapacity: Int = 1024)` (`AirPlayEngine.swift:2496`) and `recordWriteArrival()` reads `Self.nowMs()` (line 2534); the engine builds its probe with defaults at line 246 and its tracker at line 217 (`private nonisolated let cadence = WriteCadenceTracker()`, no clock seam).
- `NativeBackendBTAlignmentInterceptTests.swift:398` (`auditionReservesTheTickSlotUntilStopCompletes`) and `:423` (`auditionUsesIndependentWizardPacerAndKeepsOnlyPairAudible`) use the default dispatch `delayClock` and never set the deadlines. `NativeBackend.companionAuditionPreparationSeconds = 4`, `companionAuditionStopSeconds = 4` (`NativeBackend.swift:532, 534`, internal vars). `activateCompanionAudition` refuses with "The speaker pair changed before clicks could start." when `Date() >= preparationDeadline` (`NativeBackend+Bluetooth.swift:2108-2112`). Precedent in the same file: lines 485-490 set both to 60 with the comment "this test is not about the deadline — so it does not race one". The audition drives gains on `SpyBTSink` (a test double, `:246`), never a real `BTSyncedSink`, so `test_waitForPendingRebuild()` (`BTSyncedSink.swift:1061`) does not apply.
- `scripts/run-tests.sh:25`: `AUDIOUT_TEST_NO_CACHE=1` forces a run; a green run on identical sources is otherwise skipped (`CLAUDE.md` "A pass covers everything it ran"). `AUDIOUT_TEST_PACKAGE=AirPlayEngine` selects the engine package (`run-tests.sh:39`).
- Working tree is clean; the branch is at origin/main 4a2b3641.

## Steps

Track A — Reduce Motion pins and the 2x render (AudioutCore test files only)

1. `EnergizeTests.swift`, `sourceSwitchRaisesPendingBeatOnOffMembersAndAnnounces` (line 156): remove the `.enabled(if:)` trait so the line reads `@Test func ...`. Immediately after `popover.test_switchMainOut(.selectedDevices)`, for each id in `["en-a", "en-b", "en-c"]` set `popover.test_deviceRow(for: id)?.test_reduceMotionOverride = false`, then post `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification` on `NSWorkspace.shared.notificationCenter` exactly as lines 85-86 do. Add one comment sentence: the controller's override reaches `beginEnergize` only, the rows read the live setting, and the notification makes each row re-derive its node. Assertions unchanged. Defect still caught: `beginEnergize` not seeding the beat, or `apply(energizePending:)` not rendering `.connecting` on an `.off` member.
2. `OnboardingUITests.swift`: in the four tests at lines 835, 916, 933, 1209 remove the `.enabled(if:)` trait, and add `vc.test_ribbonReduceMotionOverride = false` on the line after each `let vc = makeVC(...)`. Nothing else changes. Defect still caught: the ribbon not showing the wait beat (status line plus spinner) while a prompt is undecided.
3. `CardViewCollapseTrajectoryTests.swift`, `firstAndSecondCollapseShareIdenticalStartHeight` (line 107): remove the trait; as the first statement add the `FoldAnimatorTests.swift:21-25` pattern — `defer` restoring `FoldAnimator.shared.test_reduceMotionOverride = nil` and calling `FoldAnimator.shared.test_settleNow()`, then set the override to `false`. Rewrite the doc paragraph at lines 32-34 to say the fold runs on `FoldAnimator.shared`, which answers Reduce Motion, so the animated test pins its override. Defect still caught: a collapse whose mid-flight expand restarts from 0 instead of the live height.
4. `PopoverControllerRowRevealMotionTests.swift`: in both tests (lines 56, 74) remove the trait and add the same defer-then-set-false pattern as step 3 as the first statements. Defect still caught: the reveal publishing the grown height before the fold has travelled.
5. `PopoverControllerRowRevealTests.swift`, `reMountingDuringAnAnimatedCloseEvictsTheStaleClip` (line 200): same as step 4. Defect still caught: a stale closing clip left mounted on re-insert.
6. `SurfaceToolbarTests.swift`, `render(_:appearanceName:)` (418-424): replace `bitmapImageRepForCachingDisplay(in:)` with an explicit rep at 2x — `NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width) * 2, pixelsHigh: Int(view.bounds.height) * 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)` (the `AlignmentPlateCellTests.swift:83-86` shape), set `rep.size = view.bounds.size`, then `view.cacheDisplay(in: view.bounds, to: rep)`. Update its doc comment: the probes were authored at the owner's 2x density and the runner draws at 1x, where a 1-pt probe straddles the highlight's antialiased edge. Then remove the trait from `theSelectedHighlightIsConcentricWithTheCapsulesBorder` (864). All 9 `render(` callers go through the new helper unchanged. Defect still caught: a highlight corner radius that is not concentric with the capsule (the 10-pt bulge).

Track B — shard-1 starvation (CompanionServerTests, PermissionStateObserverTests, tests.yml)

7. `CompanionServerTests.swift`: make `waitUntil` (63-69) `async -> Bool` over `await SuiteWait.until(timeout:sourceLocation:condition)` exactly as `CompanionEndToEndTests.swift:243-250`, marking it `nonisolated private` if the compiler asks. Rewrite its doc comment to say the state these tests wait for arrives on dispatch queues, so the poll yields its thread instead of pumping a run loop that has no sources on a non-main thread (which the old form did, measured as a busy loop on CI). Make every caller `async`: `makeHub()`, `connectClient(...)` become `async throws`; every `@Test ... throws` whose body (directly or through those helpers) calls `waitUntil` becomes `async throws`; every `#expect(waitUntil {...}, ...)` becomes `#expect(await waitUntil {...}, ...)`, every `try #require(waitUntil {...}, ...)` becomes `try #require(await waitUntil {...}, ...)`. Replace `Thread.sleep(forTimeInterval: 1.5)` (834) with `try await Task.sleep(for: .seconds(1.5))` and `Thread.sleep(forTimeInterval: 0.2)` (1091) with `try await Task.sleep(for: .milliseconds(200))`. Remove the trait from `commandRoundTripDeliversTheReply` (346). Nothing else in the file changes; no assertion changes. After this step the file contains no `Thread.sleep`, `RunLoop`, `.wait(` or `untilOnRunLoop`. Defect still caught: a command reply never reaching the client.
8. `PermissionStateObserverTests.swift`: remove the trait from the four tests (138, 155, 174, 264). No other change — the suite has no blocking wait; it was starved by step 7's busy loop in the same process.
9. `.github/workflows/tests.yml`: in the shard-1 regex (line 59) delete `CompanionServerTests|` and `PermissionStateObserverTests|`; in the shard-2 regex (line 61) insert `CompanionServerTests|` between `CompanionLicenseActivationTests|` and `CompanionSnapshotBuilderTests`; in the shard-3 regex (line 63) insert `PermissionStateObserverTests|` between `PermissionModeTests|` and `PhaseControllerTests`. Both files now hold no blocking waits, which is the shard-1 membership rule in the comment at lines 48-56. Do not edit that comment.

Track C — AirPlayEngine cadence tests

10. `WriteCadenceTests.swift`, `nominalFeedStaysNearZero` (29): remove the trait; drop `async throws`; build the tracker as `WriteCadenceTracker(now: { simulatedSeconds })` with `var simulatedSeconds: Double = 0` (the line-200 idiom); replace each `try await Task.sleep(...)` with `simulatedSeconds += audioSeconds`. Tighten the two bounds to exact: `abs(snapshot.deficitSeconds) <= 1e-9` and `abs(snapshot.overrunSeconds) <= 1e-9`. Rewrite the doc comment: an exactly paced feed must land in neither bucket. Defect still caught: a zero gap charged to deficit or overrun.
11. `WriteCadenceTests.swift`, `longGapIsChargedToStallNotDrift` (239): remove the trait; build `WriteCadenceTracker(stallGapSeconds: 0.05, now: { simulatedSeconds })`; replace `Thread.sleep(forTimeInterval: 0.15)` with `simulatedSeconds += 0.15` and `Thread.sleep(forTimeInterval: 0.01)` with `simulatedSeconds += 0.01`. Assertions unchanged. Defect still caught: a gap past the threshold read as drift, or a sub-threshold gap not read as deficit.
12. `AirPlayEngine/Sources/AirPlayEngine/AirPlayEngine.swift`, `WriteSchedulingProbe`: add a stored `private let nowMs: () -> Double` set from a new init parameter `nowMs: @escaping () -> Double = WriteSchedulingProbe.nowMs` (same idiom and doc wording as `WriteCadenceTracker.now`, lines 1995-2005); `recordWriteArrival()` (2534) reads `self.nowMs()` instead of `Self.nowMs()`. The engine's construction at line 246 is untouched (default). Then in `SchedulingProbeTests.swift`, `interArrivalGapReflectsRealGaps` (90): remove the trait; build `WriteSchedulingProbe(logInterval: 3600, ringCapacity: 128, nowMs: { simulatedMs })`; replace the five `Thread.sleep(forTimeInterval: 0.005)` with `simulatedMs += 5` and the `Thread.sleep(forTimeInterval: 0.05)` with `simulatedMs += 50`. Assertions unchanged (`count == 6`, `maxMs > 40`, `p50Ms < 20`). Update the doc comment that says "no explicit timestamps to inject". Defect still caught: inter-arrival gaps not derived from successive arrivals, or the long gap not surfacing as the max.
13. `WriteCadenceTests.swift`, `engineWritePathNominalFeedStaysNearZero` (390): KEEP the trait; change only its reason string to exactly: `"Quarantined on GitHub runners 2026-10-04: measures real Task.sleep pacing through the engine hot path and AirPlayEngine.cadence has no clock seam; the paced arithmetic is pinned by nominalFeedStaysNearZero and the wiring by engineWritePathFeedsCadenceTracker. Issue #258."`

Track D — alignment-intercept deadline race (NativeBackendBTAlignmentInterceptTests only)

14. `NativeBackendBTAlignmentInterceptTests.swift`: in `auditionReservesTheTickSlotUntilStopCompletes` (398) and `auditionUsesIndependentWizardPacerAndKeepsOnlyPairAudible` (423), before `backend.start()`, add `backend.companionAuditionPreparationSeconds = 60` and `backend.companionAuditionStopSeconds = 60` with the same comment sentence as lines 485-488 ("...this test is not about the deadline — so it does not race one"). No quarantine is added. Defect still caught: unchanged (tick-slot reservation; pacer independence and pair-only audibility). The deadline itself remains tested at lines 570, 774, 814, 1064.

## Out of scope — do not touch

- `AudioutCore/Sources/**` other than nothing — Track A, B and D edit no production source. Do not forward `PopoverController.test_reduceMotionOverride` to rows, do not add seams to `SetupRibbonView`, `SurfaceToolbarSeat`, `NativeBackend`, or `CompanionServer`.
- `AirPlayEngine.swift` outside the `WriteSchedulingProbe` init/`recordWriteArrival` change; no clock seam for `AirPlayEngine.cadence`.
- `SuiteWait.swift` in either package; no new wait helper, no deadline change.
- The other `untilOnRunLoop` users in non-`@MainActor` suites (list in Cross-area questions); not this order.
- `scripts/run-tests.sh`, `.githooks/*`, the tests.yml shard-1 comment, cache or permit settings.
- Do not delete, rename, or re-word any test; do not change any threshold except step 10's tightening; no new tests; no `print`.
- `BTSyncedSinkTests`, `BTSinkClockStormTests`, `NativeBackendTests.ManualDelayClock` — unrelated to the audition flake (test double sink, no real rebuild).
- No commits, no pushes (the orchestrator pushes).

## Retired terms

none

## Verification

The local runs prove the tests still pass with the quarantine lines gone (locally `CI` is unset, so they always ran); the PR's own GitHub `tests` check on the real `macos-26` runner is the final proof that they now hold there. Run each pair in order; the second needs `AUDIOUT_TEST_NO_CACHE=1` or the runner skips it as already green.

Track A:
- `bash scripts/run-tests.sh --filter 'EnergizeTests|OnboardingUITests|CardViewCollapseTrajectoryTests|PopoverControllerRowRevealMotionTests|PopoverControllerRowRevealTests|SurfaceToolbarTests'` → "Test run with N tests ... passed", 0 issues.
- `AUDIOUT_TEST_NO_CACHE=1 AUDIOUT_TEST_MODE=serial bash scripts/run-tests.sh --filter '<same>'` → passed.

Track B:
- `bash scripts/run-tests.sh --filter 'CompanionServerTests|PermissionStateObserverTests'` → passed; the output must show CompanionServerTests ran (not a no-match green).
- `AUDIOUT_TEST_NO_CACHE=1 AUDIOUT_TEST_MODE=serial bash scripts/run-tests.sh --filter 'CompanionServerTests|PermissionStateObserverTests'` → passed.
- `grep -c 'Thread.sleep\|RunLoop\|\.wait(\|untilOnRunLoop' AudioutCore/Tests/AudioutCoreTests/CompanionServerTests.swift` → 0.

Track C:
- `AUDIOUT_TEST_PACKAGE=AirPlayEngine bash scripts/run-tests.sh --filter 'WriteCadence|SchedulingProbeTests'` → passed.
- `AUDIOUT_TEST_NO_CACHE=1 AUDIOUT_TEST_MODE=serial AUDIOUT_TEST_PACKAGE=AirPlayEngine bash scripts/run-tests.sh --filter 'WriteCadence|SchedulingProbeTests'` → passed.

Track D:
- `bash scripts/run-tests.sh --filter NativeBackendBTAlignmentInterceptTests` → passed.
- `AUDIOUT_TEST_NO_CACHE=1 AUDIOUT_TEST_MODE=serial bash scripts/run-tests.sh --filter NativeBackendBTAlignmentInterceptTests` → passed.

Final: `grep -rn 'Issue #258' --include='*.swift' .` → exactly one hit, `WriteCadenceTests.swift` `engineWritePathNominalFeedStaysNearZero`, with the step-13 string.

Then the orchestrator pushes and the `tests` workflow (all three shards + airplayengine) is the check that counts. If a Track A test still fails on the runner with its override pinned, that is new information about the runner, not a reason to loosen: report it and re-quarantine that one test with the observed values.

Test seams: no new tests. Nothing a new test could see changes; each step names the defect the existing test still catches. The stand-in check for the Reduce Motion fixes is the CI run itself (the runner is the only machine in play with the setting on).

Report section the executor must fill: "stays quarantined: `WriteCadenceEngineWritePathTests.engineWritePathNominalFeedStaysNearZero` — measures real sleep pacing through the engine hot path; `AirPlayEngine.cadence` has no clock seam."

## Execution plan

Four tracks, all PARALLEL, disjoint files. The branch has no uncommitted work; worktrees fork from 4a2b3641.

- Track A — steps 1-6. Files: `EnergizeTests.swift`, `OnboardingUITests.swift`, `CardViewCollapseTrajectoryTests.swift`, `PopoverControllerRowRevealMotionTests.swift`, `PopoverControllerRowRevealTests.swift`, `SurfaceToolbarTests.swift` (all under `AudioutCore/Tests/AudioutCoreTests/`). Model opus, effort medium. Routine edits, but six files and a render helper that must keep 8 other callers green.
- Track B — steps 7-9. Files: `CompanionServerTests.swift`, `PermissionStateObserverTests.swift`, `.github/workflows/tests.yml`. Model opus, effort medium. Step 7 is a 75-site mechanical async conversion where one missed `await` is a compile error, not a silent bug.
- Track C — steps 10-13. Files: `AirPlayEngine/Tests/AirPlayEngineTests/WriteCadenceTests.swift`, `SchedulingProbeTests.swift`, `AirPlayEngine/Sources/AirPlayEngine/AirPlayEngine.swift`. Model opus, effort low. Separate package.
- Track D — step 14. File: `NativeBackendBTAlignmentInterceptTests.swift`. Model opus, effort low. One step, one file; it cannot join Track A without widening A's filter to a 2-minute suite, and the owner asked for it to be handled alongside — if the runner prefers fewer worktrees, fold it into Track A and add `NativeBackendBTAlignmentInterceptTests` to A's filter.

No combined verification is needed after the merge: no two tracks edit the same file and no track's filter names another track's suite.

## Executor rules (copy verbatim into the handoff prompt)
> - Follow the steps in order. Do not add, merge, reorder, or skip steps.
> - Before editing in any folder, read the nearest AGENTS.md above it (and the root one) if the repo has them — folder rules and traps bind even when the work order doesn't repeat them.
> - If reality contradicts a Verified fact or a step is impossible as written, STOP and report the discrepancy. Do not improvise a workaround.
> - Before reporting progress, audit each claim against a tool result from this session. Only report work you can point to evidence for. If tests fail, say so with the output.
> - If the work order names a new test, run it before making the change and paste the failing output. A test that passes before the change proves nothing.
> - "Done" means the Verification commands were run in this session and passed. Paste their output.
> - Touch nothing in the Out-of-scope list.
> - Deliver what was asked, at the scope intended. If the spec seems mistaken or a better approach exists, say so in a sentence and continue as specified rather than quietly narrowing, widening, or transforming it.
> - If a step changes code that another screen, window or surface also draws or calls and the work order does not name that surface, STOP and report it as a discrepancy before editing. Flagging it and continuing is not enough; the owner decides whether the change applies there.
> - When the work order lists Retired terms, after the last step run `git grep -n -i` for each term across `AudioutCore/Sources`, `AudioutCore/Tests`, `DESIGN.md` and every `*.md`, fix the hits a step covers, and list every other hit with file:line in your report. A new or moved test carries one comment sentence naming the code change that turns it red.
> - A test you add or move carries one comment sentence naming the code change that turns it red; a new test extends an existing suite before it starts a new file; folder AGENTS.md lines carry no dates, rulings or decision ids, and AGENTS-HISTORY.md is only appended to; DESIGN.md sections are rewritten from the shipped code, never from the plan.

## Cross-area questions

- [GitHub runner] The runner's Reduce Motion state is inferred, not read: ten tests failed with exactly the values Reduce Motion ON produces (fold snaps to its end, ribbon spinner hidden, row beat dropped) and no web source documents the image's `com.apple.universalaccess` defaults. Steps 1-5 are correct regardless (tests must pin the seams they depend on); only the un-quarantine outcome depends on it, and the CI run settles it. (affects steps 1-5)
- [GitHub runner] The 1x pixel density on the runner is inferred from the 160°/200° straddle and the local pass; `bitmapImageRepForCachingDisplay` on a windowless view was not measured on either machine. Step 6 fixes the scale explicitly, so the outcome does not depend on the guess. (affects step 6)
- [AudioutCore/Tests] Sixteen other non-`@MainActor` suites also call `SuiteWait.untilOnRunLoop` and therefore busy-spin on a cooperative thread while their condition is unmet: AlignmentTickInjectorTests, BTFanoutTests, BTDeviceEnumeratorTests, BTSpeakerTimingTests (5 sites), CastFakeReceiverLoopTests (2), CastOutputManagerTests, DACPServerTests, NativeBackendBTDevicesTests, NativeBackendBTHardwareVolumeTests, NativeBackendBTSelectionTests, NativeBackendCastTests, NativeBackendSyncedLocalSelectionTests, NativeCaptureCoordinatorTests, NativeDiscoveryTests, PerAppCaptureCoordinatorTests, SyncedLocalFanoutTests. Their spins are short today; they are the next candidates if shard 2/3 starvation appears. Not in this order. (affects nothing now; context for step 8's shard move)
- [Mule, BTSyncedSinkTests] `ringDropsAreCountedPerGateAndResetWithTheSession` (chunks 0 of 2, once in five mule runs) was not researched; it exercises a real `BTSyncedSink`, unlike the audition tests, so it does not share step 14's root cause. (affects nothing)
