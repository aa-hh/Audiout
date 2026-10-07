# Settings help verification

Worktree: `settings-tab-redesign-0dd6a3`. Original handover repairs are committed and pushed as `14e8a38f`. Help and the owner's later layout refinement remain uncommitted at this checkpoint.

## Before the later refinement

- Combined Settings/shared UI check: 205 tests in 16 suites passed on the second Mac. Command and output are in `combined-tests-final.log`. Tests followed initial implementation; no failing baseline is claimed for that implementation.
- Native inspection exposed an Escape defect in pinned Light License help. An invisible real-panel regression reproduced lost owner focus. After the focus repair, a second Escape exposed an invalid superclass cancellation call. The helper now focuses its owner before presentation and forwards later cancellation through the responder chain.
- Final focused check after those repairs: 105 tests in 10 suites passed on the second Mac, exit 0 (`helper-focus-fixed.log`).
- `scripts/make-app.sh` built and Developer ID signed the separate `com.audiout.Audiout.settingshelppreview69aa` preview, exit 0. Generated preview environment selects the mock backend. A later deep, strict signature check passed after that environment was added. Logs: `help-preview-final-build.log`, `help-preview-final-sign.log`.
- Native confirmation on 2026-10-07: pinned Light License help opens; first Escape removes the popover and focuses its help button while License stays visible; second Escape follows ordinary Settings cancellation to Mixer. No crash.
- Earlier native checks covered all five panes, Light/Dark native help, live volume and accent updates, one popover at a time, pane changes, and Advanced collapse. Those checks preceded the latest layout refinement.

Full keyboard traversal, VoiceOver reading, system contrast/motion settings and physical audio have not been verified. Headless checks do not replace those checks. The preview is isolated and uses the mock backend.

## Later refinement

- Removed redundant help from Launch at login, reconnect, Theme, Accent, the Remote invitation and Apps that stay on this Mac. Eight explanations remain. Current state, warnings and action results stay visible.
- Two failing geometry probes observed an empty card at 70 points despite a 56-point fitted size. The Add button and its row were both 44 points, with zero native alignment insets. The stack reserved 14 spare points. Increasing only that stack's vertical hugging priority fixes the extra space. Add/remove/reopen geometry now passes.
- Connection volume opts into a two-line title. Tests measure the complete text height, adjacent help, no overlaps and vertical control centering at the real pane width. Advanced initially has one buffer row; feedback mounts during reconnecting/results and disappears when cleared. The launch-option warning stays visible.
- The first combined refinement run tested 208 cases and failed only a redundant exact-width comparison on native half-point rounding. The observed text-fit and centering assertions passed. Removed that implementation comparison and corrected the new suite to use `IsolatedSuite`, its scratch folders and in-memory settings.
- Final check: `TASK_SETTINGS_FILTER=$(sh .githooks/guard-test-scope.sh)` then `bash scripts/run-tests.sh --filter "$TASK_SETTINGS_FILTER"`. Exit 0, 2,011 tests in 110 suites passed on `alechamilton@SUMUP-M9Y197RFVG.local` in 170.860 seconds. This was an actual run on the final sources, not a reused result. Log: `refinement-final-tests.log`.

- Fresh `scripts/make-app.sh` preview build exited 0; generated mock environment was re-signed and `codesign --verify --deep --strict` passed. Logs: `refinement-preview-build.log`, `refinement-preview-sign.log`.
- Native confirmation in Light and Dark: empty app card is compact; Add app opens its picker; full connection title wraps into two lines with centered slider/value/help; expanded Advanced has one idle buffer row and no divider. A mock buffer change mounted Reconnecting speakers feedback; after completion and dismissal the card returned to one row. The buffer was restored to 1,000 ms. Wrapped-title help opened with full text; Escape closed it and returned focus while Settings stayed visible. Appearance has plain Theme/Accent titles; General has plain login/reconnect titles.

Native add/remove of saved exclusions was not performed; the isolated geometry test covers that lifecycle. Remote invitation and conditional License behavior are covered by headless tests. Full keyboard traversal, VoiceOver and system accessibility variants remain unverified. No physical audio was tested. No PR or submitted-PR review exists at this pre-submission checkpoint.

## Submitted PR and review repairs

PR [320](https://github.com/aa-hh/Audiout/pull/320) was created before the full review. Round 1 reviewed submitted commit `3294c03ac71ddaecc5a053a04912ce5793b0d3fc` and posted two HIGH findings plus one duplicate MEDIUM finding. The retained defects were stale buffer readouts before Audio first mounted and Audio publishing a pane size despite the fixed Settings host.

- A remote failing run reproduced the defects: 21 tests in three suites, two failing tests and six failed assertions (`../settings-repair-red.log`). The repair reconciles the retained buffer before the unloaded-view guard, preserves it when controls first mount, and deletes Audio's obsolete size publisher. Invisible native geometry tests observe Advanced expansion and collapse.
- Integrated incoming main commit `d8427c020fd43bc1679fc16735d35db1b75ea061`, preserving its Scenes behavior and the branch's shared Settings views. The scoped integration moves the existing rolling count label into SharedUI and uses the shared generic header. The source plan is `integration-work-order.md`.
- Fresh combined command: `TASK_SETTINGS_FILTER=$(bash .githooks/guard-test-scope.sh)` followed by `AUDIOUT_TEST_NO_CACHE=1 bash scripts/run-tests.sh --filter "$TASK_SETTINGS_FILTER"`. Exit 0: 3,014 tests in 148 suites passed on `alechamilton@SUMUP-M9Y197RFVG.local` in 196.605 seconds (`integrated-tests.log`).
- `bash scripts/build.sh` exited 0 and compiled on the second Mac (`integrated-build.log`). The staged diff against incoming main passes `git diff --cached --check MERGE_HEAD`; no unresolved index entries remain.
- The user stopped native app control for this turn. No final native inspection of the integration was performed, and the running preview was left alone. Earlier native observations above apply to `3294c03`, before these review repairs and the Scenes integration.

Round 2 will run on the pushed repair commit before merge. The owner has authorized merging after the required review and checks.
