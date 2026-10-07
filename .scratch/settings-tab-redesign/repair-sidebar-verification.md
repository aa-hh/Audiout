# Sidebar selection repair

`setReadout` now updates the outline view's existing cell through the same configuration used at creation. The cell reads selection and emphasis from its actual row, keeps the current glyph's resting tint, and updates text, tooltip and accessibility label. Line-count changes still call `noteHeightOfRows` without animation.

The regression test inspects AppKit's actual row and cell in a never-shown borderless window parked at (-10000, -10000). It covers focused and unfocused selection colors, a newly changed resting glyph after deselection, live readout text and accessibility, and actual row heights of 40, 54, then 40 points. It does not use the detached cell created by the old readout test hooks.

Before the production repair:

```text
AUDIOUT_TEST_NO_CACHE=1 bash scripts/run-tests.sh --filter 'SettingsRootViewControllerTests.selectedSidebarReadoutKeepsItsLiveSelectionInks'
exit 1
Test selectedSidebarReadoutKeepsItsLiveSelectionInks() failed after 0.247 seconds with 14 issues.
Test run with 1 test in 1 suite failed after 0.247 seconds with 14 issues.
suite: FAILED on remote alechamilton@SUMUP-M9Y197RFVG.local — not re-run here.
```

All 14 failures were live name, glyph or readout color assertions. Text, accessibility and height assertions passed. Full output: `repair-sidebar-red.log`.

After the production repair:

```text
AUDIOUT_TEST_NO_CACHE=1 bash scripts/run-tests.sh --filter SettingsRootViewControllerTests
exit 0
Test run with 40 tests in 3 suites passed after 1.029 seconds.
suite: passed on remote alechamilton@SUMUP-M9Y197RFVG.local.
```

Full output: `repair-sidebar-green.log`. `git diff --check` also passed.

`scripts/real-time-tests.sh` does not exist on this branch, so that check could not run. No timed waits were added. No shared view, palette, design, commit, push or live app launch was changed or performed. Other agents own the concurrent AppDelegate and licence repairs; the parent will verify their combined source after integration.
