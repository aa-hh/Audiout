Revised once after spec check: step 3 expected failure value, AGENTS.md line cite, apply overload, four extra scope fences.

# Work order — 08: clear `AppRowView`'s slider drag flag on keyboard and VoiceOver changes

## Goal

`AppRowView.volumeChanged` sets `isDraggingSlider = true` on every slider change and clears it only when the current event happens to be `.leftMouseUp`. A keyboard, scroll or VoiceOver volume change arrives as a single event that is never `.leftMouseUp`, so the flag latches on and `apply(...)` stops repainting the slider and readout for the rest of that row's life. Replace the logic with the switch `MainOutRowView.masterChanged` already uses, prove it with a test that fails first, delete the now-stale `STABILITY(D4)` marker, and correct the four target-scoped docs that still say markers exist in these two targets.

## Verified facts

- The defect, verbatim: `isDraggingSlider = true` / `let event = NSApp?.currentEvent` / `if event?.type == .leftMouseUp { isDraggingSlider = false }` — `AudioutCore/Sources/AudioutSharedUI/AppRowView.swift:720-722`.
- The marker line to delete sits immediately above it, at `AudioutCore/Sources/AudioutSharedUI/AppRowView.swift:718`, and begins `// STABILITY(D4): the drag flag clears only when...`.
- `apply(...)` gates both the slider value and the readout text on the flag: `if !isDraggingSlider { slider.integerValue = ...; readoutLabel.stringValue = ... }` — `AppRowView.swift:269-272`. So one assertion on the slider value covers the whole gated branch.
- The fixed shape to copy, `MainOutRowView.masterChanged` — `AudioutCore/Sources/AudioutPopoverUI/MainOutRowView.swift:689-694`:
  ```swift
  switch NSApp?.currentEvent?.type {
  case .leftMouseDown, .leftMouseDragged:
      isDraggingMaster = true
  default:
      isDraggingMaster = false
  }
  ```
  Its explanatory comment is at `MainOutRowView.swift:681-688`.
- `AppRowView`'s slider and the action method are both `private`: `private let slider = NSSlider()` at `AppRowView.swift:206`, `@objc private func volumeChanged` at `AppRowView.swift:719`, wired at `AppRowView.swift:569-570`. `@testable import` reaches internal, not private, so the test cannot fire the action without a new hook.
- `AppRowView.test_setVolume` calls the delegate directly and never enters `volumeChanged` — `AppRowView.swift:1063-1065`. It cannot catch this defect; the existing test at `AppRowViewTests.swift:211-217` asserts exactly that (`"test_setVolume only fires the delegate"`).
- The hook to mirror, `DeviceRowView.test_fireSliderAction(settingValueTo:)` — `AudioutCore/Sources/AudioutSharedUI/DeviceRowView.swift:2362-2367`:
  ```swift
  public func test_fireSliderAction(settingValueTo value: Int) {
      slider.integerValue = value
      guard let action = slider.action,
            let target = slider.target as? NSObject else { return }
      _ = target.perform(action, with: slider)
  }
  ```
  Its doc comment is at `DeviceRowView.swift:2356-2361`.
- The same defect was already fixed and tested on the device row: `DeviceRowView.volumeChanged` switch at `DeviceRowView.swift:2262-2270`, and the test `keyboardShapedSliderChangeNeverWedgesTheDragFlag` at `AudioutCore/Tests/AudioutCoreTests/DeviceRowConnectionStateTests.swift:619-637`. It works because `NSApp` is nil headless, so `NSApp?.currentEvent?.type` is nil and the `default` branch runs.
- `NSApp` is nil in this test process and must always be optional-chained — rule at `AudioutCore/Sources/AudioutSharedUI/AGENTS-HISTORY.md:66`; `MainOutRowView.swift:746-747` records the same ("always nil under `swift test`").
- The test suite: `@MainActor @Suite struct AppRowViewTests` at `AudioutCore/Tests/AudioutCoreTests/AppRowViewTests.swift:13-14`, Swift Testing. Its row builder `makeRow(selected:)` applies a config with `volume: 42` — `AppRowViewTests.swift:83-96`. `AppRowView.Configuration.init` signature at `AppRowView.swift:143-145`.
- `AppRowView.test_volume` reads the control: `public var test_volume: Int { slider.integerValue }` — `AppRowView.swift:1080`.
- No test hook exposes the readout label's *text*; only its colour (`test_readoutTextColor`, `AppRowView.swift:851`). So the test asserts the slider value only.
- Folder rule: "`test_*` hooks must drive the same delegate path as the live control" — `AudioutCore/Sources/AudioutSharedUI/AGENTS.md:13`. The new hook fires the real target/action, satisfying it.
- Every `STABILITY(` occurrence in the repo (`git grep -n STABILITY`): the one at `AppRowView.swift:718`; one at `AudioutCore/Sources/AudioutSettingsUI/GeneralSettingsViewController.swift:805` (different finding, different target); C6/C7/C8/D5/D6 markers throughout `AudioutCore/Sources/AudioutCore/`; plus doc lines and MARK headings.
- In `AudioutPopoverUI` the only remaining occurrence is a MARK heading with no parenthesised id: `// MARK: Live slider drag (STABILITY D4, controller half)` at `AudioutCore/Sources/AudioutPopoverUI/PopoverController.swift:844`. So after this change, "no `STABILITY(id)` markers remain" is literally true for both `AudioutSharedUI` and `AudioutPopoverUI`.
- The four doc lines to change, all of which currently claim markers exist in their target:
  - `AudioutCore/Sources/AudioutSharedUI/AGENTS.md:40` — `- Stability findings carry \`STABILITY(id)\` markers; sketches in [../../../dev/notes/stability-audit-2026-07-18.md](../../../dev/notes/stability-audit-2026-07-18.md).`
  - `AudioutCore/Sources/AudioutSharedUI/AGENTS-HISTORY.md:50`, `AudioutCore/Sources/AudioutPopoverUI/AGENTS.md:67`, `AudioutCore/Sources/AudioutPopoverUI/AGENTS-HISTORY.md:58` — all three carry the identical sentence `- Known stability findings in this target carry \`STABILITY(id)\` inline markers — details and fix sketches in [../../../dev/notes/stability-audit-2026-07-18.md](../../../dev/notes/stability-audit-2026-07-18.md).`
- `AudioutCore/AGENTS-HISTORY.md:501` is package-scoped ("in this package") and stays true, since C6/C7/C8/D5/D6 markers remain under `AudioutCore/Sources/AudioutCore/`. **My call: leave it, and leave `PopoverController.swift:844` and `PopoverControllerTests.swift:3336`** — both are MARK headings naming the controller-side drag logic, which this change does not touch, and neither is a `STABILITY(id)` marker. Nothing in either folder's AGENTS.md requires otherwise.
- There is no `AGENTS.md` under `AudioutCore/Tests/`; the governing rules for the test are `AudioutCore/AGENTS.md:11-12` (`run-tests.sh --filter`, never bare `swift test`; tests must stay invisible) and the root `AGENTS.md`.
- Pre-change baseline, run in this session: `bash scripts/run-tests.sh --filter AppRow` → `Test run with 72 tests in 2 suites passed after 3.138 seconds.`, exit code 0.

## Steps

1. **Add the hook.** In `AudioutCore/Sources/AudioutSharedUI/AppRowView.swift`, immediately after `test_setVolume(_:)` (ends at line 1065), add a `public func test_fireSliderAction(settingValueTo value: Int)` that is a line-for-line copy of `DeviceRowView.swift:2362-2367` — set `slider.integerValue = value`, then `guard let action = slider.action, let target = slider.target as? NSObject else { return }`, then `_ = target.perform(action, with: slider)`. Give it a two-or-three-line doc comment in the shape of `DeviceRowView.swift:2356-2361`: this fires the slider's own target/action with the slider as sender — the dispatch AppKit performs during a real change — unlike `test_setVolume`, which only calls the delegate.

2. **Write the failing test.** In `AudioutCore/Tests/AudioutCoreTests/AppRowViewTests.swift`, inside `AppRowViewTests`, add one `@Test` function named `keyboardShapedSliderChangeNeverWedgesTheDragFlag`, placed directly after `settingVolumeFiresDelegate` (ends line 217). Model it on `DeviceRowConnectionStateTests.swift:619-637`, including a MARK heading in that file's style. Body: build the row with the existing `makeRow()` helper (volume 42); call `row.test_fireSliderAction(settingValueTo: 30)` — headless, `NSApp` is nil, so this is the keyboard/VoiceOver-shaped path; then call the single-argument `row.apply(_:)` (`AppRowView.swift:251`, the same overload `makeRow` uses at `AppRowViewTests.swift:86`; NOT `apply(_:isSelected:)`) with a fresh `AppRowView.Configuration` identical to `makeRow`'s but `volume: 55` (same `appID: "com.example.app"`, `name: "Example App"`, `icon: nil`, `selectedDestinationID: "local"`, `destinations: makeDestinations()`); then `#expect(row.test_volume == 55, ...)` with a message naming the defect — a non-mouse change must not wedge `isDraggingSlider` and block the model push. Comment, in the test, why a nil current event is the keyboard/VoiceOver shape.

3. **Run the test and confirm it fails.** `bash scripts/run-tests.sh --filter AppRow`. It must fail on this one test, and the failure reads `30 == 55` — `test_fireSliderAction` sets the control to 30 before firing the action, and the wedged flag then pins the slider at 30 so `apply` cannot move it to 55. (Not 42: 42 is what `settingVolumeFiresDelegate` sees because `test_setVolume` never touches the control.) Paste that failure. If it passes, STOP — the test is not seeing the defect.

4. **Fix `volumeChanged`.** In `AudioutCore/Sources/AudioutSharedUI/AppRowView.swift`, delete the `// STABILITY(D4): ...` comment line at 718 and replace the three lines `isDraggingSlider = true` / `let event = NSApp?.currentEvent` / `if event?.type == .leftMouseUp { isDraggingSlider = false }` (lines 720-722) with the switch quoted in Verified facts, using `isDraggingSlider` in place of `isDraggingMaster`. Leave the readout update and the delegate call that follow (lines 723-724) untouched. Above the switch, write a short comment — shorter than `MainOutRowView.swift:681-688`, same spirit, why not what: the flag exists so `apply(...)` cannot yank the thumb out from under a live mouse drag; read it from whether a drag is actually in flight, because a keyboard or VoiceOver change is a single event that is never `.leftMouseUp` and the old logic latched the flag forever; cite `dev/notes/stability-audit-2026-07-18.md` §D4.

5. **Rerun and confirm green.** `bash scripts/run-tests.sh --filter AppRow`, with `AUDIOUT_TEST_NO_CACHE=1` so the pass cache cannot skip the run. Expect `Test run with 73 tests in 2 suites passed`.

6. **Update the four docs.** Replace each of the four lines listed in Verified facts with one line saying no `STABILITY(id)` markers remain in that target, keeping the same link to the audit note as history. Use this exact text at all four sites (it fits both current phrasings, and the `../../../` depth is the same for all four files):

   `- No \`STABILITY(id)\` markers remain in this target; the audit's findings and fix sketches are history in [../../../dev/notes/stability-audit-2026-07-18.md](../../../dev/notes/stability-audit-2026-07-18.md).`

   Keep each line's position in its list; change nothing else in those files.

## Out of scope — do not touch

- `AudioutCore/Sources/AudioutSharedUI/DeviceRowView.swift`, `AudioutCore/Sources/AudioutPopoverUI/MainOutRowView.swift`, `AudioutCore/Sources/AudioutPopoverUI/PopoverController.swift` — read-only references here.
- Do **not** port `DeviceRowView`'s scoped mouse-up monitor (`installSliderDragEndMonitor`, `DeviceRowView.swift:2280-2300`) into `AppRowView`. The settled fix is the `MainOutRowView` switch alone.
- `AudioutCore/Sources/AudioutSettingsUI/GeneralSettingsViewController.swift:805` (the other `STABILITY(D4)`), every `STABILITY` marker under `AudioutCore/Sources/AudioutCore/`, `AudioutCore/AGENTS-HISTORY.md:501`, `PopoverController.swift:844`, `PopoverControllerTests.swift:3336`.
- Do not add a readout-text test hook, do not rename or retire `test_setVolume`, do not touch the existing `settingVolumeFiresDelegate` test, do not reformat or reflow the AGENTS files beyond the one replaced line each.
- No commits, no pushes, no branch or worktree operations. Everything stays uncommitted in this worktree.
- Do not add a `test_isDraggingSlider` get/set hook (or any hook beyond `test_fireSliderAction`); the test proves the flag through `test_volume` alone.
- `dev/notes/stability-audit-2026-07-18.md` stays as written; it is history, and every edited doc line still links to it.
- The review artifacts stay as written: `.scratch/code-review-2026-09-17/areas/popover.md`, `.scratch/code-review-2026-09-17/REVIEW.md`, and the ticket `.scratch/code-review-2026-09-17/issues/08-app-row-drag-flag.md` (do not change its `Status:` line; the orchestrator owns that).
- No cleanup, no abstractions, no error handling for impossible cases, no backwards-compat shims.

## Verification

Test seam: `AudioutCore/Tests/AudioutCoreTests/AppRowViewTests.swift:13` (`@Suite struct AppRowViewTests`). Defect the new test catches: after a slider change that is not a mouse drag, `AppRowView` ignores every later `apply(...)` and its slider stops tracking the model.

Command:

```bash
AUDIOUT_TEST_NO_CACHE=1 bash scripts/run-tests.sh --filter AppRow
```

- Pre-change baseline observed in this session: `Test run with 72 tests in 2 suites passed after 3.138 seconds.`, exit 0.
- After step 2, before step 4: the run must FAIL on `keyboardShapedSliderChangeNeverWedgesTheDragFlag` only.
- Done: `Test run with 73 tests in 2 suites passed`, exit 0.

A `--filter` that matches nothing still prints green and exits 0. Exit code and the word "passed" prove nothing on their own — the executor must paste the literal `Test run with N tests in 2 suites passed` line, and N must be 73.

`AUDIOUT_TEST_NO_CACHE=1` is required: `run-tests.sh` caches passing runs and will otherwise skip a real run. The mule was unreachable during the baseline, so expect a local run of several minutes on a cold build.

## Execution plan

One track, serial by construction — it is the whole job, and steps 3-5 are strictly ordered.

- **Track A** — all six steps. Files: `AudioutCore/Sources/AudioutSharedUI/AppRowView.swift`, `AudioutCore/Tests/AudioutCoreTests/AppRowViewTests.swift`, `AudioutCore/Sources/AudioutSharedUI/AGENTS.md`, `AudioutCore/Sources/AudioutSharedUI/AGENTS-HISTORY.md`, `AudioutCore/Sources/AudioutPopoverUI/AGENTS.md`, `AudioutCore/Sources/AudioutPopoverUI/AGENTS-HISTORY.md`.
- **Model:** opus. **Effort:** medium.
- The worktree at `/Users/alechenderson/Projects/AirPlay Controller/.claude/worktrees/cr-08-app-row-drag-flag` is clean at `a14ff11f`; no uncommitted work is depended on.

## Executor rules (copy verbatim into the handoff prompt)

> - Follow the steps in order. Do not add, merge, reorder, or skip steps.
> - Work only inside `/Users/alechenderson/Projects/AirPlay Controller/.claude/worktrees/cr-08-app-row-drag-flag`. Never touch the `main` checkout or any other worktree.
> - Before editing in any folder, read the nearest AGENTS.md above it (and the root one) if the repo has them — folder rules and traps bind even when the work order doesn't repeat them.
> - If Edit/Write refuse in this worktree, make the edit through the shell instead (`python3`, a heredoc, or `sed`) — but never with `git` write commands.
> - Never commit, push, stash, merge, or checkout. All work stays uncommitted.
> - Tests and builds go through `bash scripts/run-tests.sh --filter AppRow` (and `bash scripts/build.sh` if you need a compile check) — never a bare `swift test`, `swift build`, `swift run`, or `xcodebuild`.
> - If reality contradicts a Verified fact or a step is impossible as written, STOP and report the discrepancy. Do not improvise a workaround.
> - Before reporting progress, audit each claim against a tool result from this session. Only report work you can point to evidence for. If tests fail, say so with the output.
> - Run the new test before making the fix and paste the failing output. A test that passes before the change proves nothing.
> - "Done" means the Verification command was run in this session and passed. Paste the literal `Test run with N tests in 2 suites passed` line; a green exit with no such line means nothing matched.
> - Touch nothing in the Out-of-scope list.
> - Deliver what was asked, at the scope intended. If the spec seems mistaken or a better approach exists, say so in a sentence and continue as specified rather than quietly narrowing, widening, or transforming it.
