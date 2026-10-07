# Handover: build the new Scenes tab (direction F2)

Written 2026-10-07 for a Codex agent picking this up cold. Read this file top to bottom before touching code.

## 1. Where you are

- Repository: the Audiout Mac app, a native AppKit macOS menu-bar app (Swift).
- Worktree: `/Users/alechenderson/Projects/AirPlay Controller/.claude/worktrees/touchbar-play-button-status-05e2b1`
- Branch: `claude/scenes-tab-redesign-ee9802`, cut from `origin/main` at commit `ccd0ed98`. No source changes yet.
- Untracked: only `.scratch/scenes-redesign/`, which holds everything below. If you are in a different checkout and those files are missing, stop and ask the owner for them.

Read these before anything else, in this order:

1. `AGENTS.md` at the repo root.
2. `CLAUDE.md` at the repo root. It is written for another agent but every build, test, branch and merge rule in it binds you too.
3. `AudioutCore/AGENTS.md`
4. `AudioutCore/Sources/AudioutWindowUI/AGENTS.md` (the folder you will mostly edit).

## 2. What the owner wants

Rebuild the **Scenes** tab of the app so it looks and works like the **Speakers** tab beside it:

- A 210 pt sidebar on the left lists the saved scenes, sorted by name. Each row shows the scene's icon with a soft magenta glow behind it, the scene name, and a caption with the speaker count ("1 speaker", "3 speakers"). Nothing else.
- The page on the right is the selected scene's editor. It has the shared page header (an icon well you click to change the icon, an inline rename field, the count as its caption), a "Speakers" title, one rounded card listing every speaker with a membership control, and a "Delete scene…" button beside the line "Changes are saved as you go."
- The membership control is the app's own round node, not a system checkbox: a filled gold disc means the speaker is in the scene, a hollow grey ring means it is not, a dimmed disc with a gold rim plus the word "Unavailable" means it is in the scene but the Mac cannot reach it. The whole row is clickable.
- When a speaker is toggled, the count on the page and the count in the sidebar row change together, with the digits sliding (instant when Reduce Motion is on).
- With no scenes saved: the sidebar says "No scenes yet", and the page shows a header plus one card row titled "Add scene…" with a gold "Add scene…" button. There is no second row.
- "Add scene" at the bottom of the sidebar and ⌘N open the existing scene-creation sheet. Right-click on a sidebar row offers "Rename…" and "Delete scene…".

What goes away: the current card grid of scenes, the dashed "add" tile, the member chips, the push into a separate editor, the back control, the Done/Save button, and every "Playing" or "Feeding" status mark on this tab.

Rulings the owner has already made. Do not reopen them:

- No status words or marks anywhere on this tab. The owner said users would not understand them. Which scene is playing is shown in the Mixer tab only.
- Nothing on this tab plays or activates a scene.
- No membership "rail" (the vertical gold line the Mixer draws). Only the round nodes.
- Gold is used only for the membership node and the empty page's button.
- The creation sheet and the icon picker stay as they are.
- Defaults for the small open questions: sidebar sorted by name; sidebar caption is the count only; the Speakers tab's own sidebar keeps its behaviour.

## 3. The design files

All under `.scratch/scenes-redesign/`:

| File | What it is |
|---|---|
| `direction-f2/mock.png` | The picture of the finished screen, dark and light. This is the visual target. |
| `direction-f2/brief.md`, `direction-f2/changes.md` | The design brief for the membership control, colour and the count roll |
| `direction-f/brief.md`, `direction-f/changes.md`, `direction-f/mock.png` | The layout F2 inherits |
| `SHARED-BRIEF.md` | Fixed rules every design direction started from |
| `WORK-ORDER.md` | **The step-by-step build plan. This is what you execute.** |
| `direction-a` … `direction-e2` | Earlier rejected directions. Background only; do not build from them. |

One difference from the mock: the empty page's mock shows two rows. Build only the "Add scene…" row.

## 4. One decision is still open

`WORK-ORDER.md` opens with a blocking question. The brief asks for the node to fill from ring to disc over 0.15 s when toggled. That drawing lives in `AudioutCore/Sources/AudioutSharedUI/MembershipBusView.swift`, which the Mixer tab also uses, so animating it changes the Mixer too.

- **Option 1 (recommended, and what the work order is written for):** no fill animation. The node switches state at once, as it does today. The hover grow and the count roll still ship.
- **Option 2:** widen the scope to `MembershipBusView.swift` so every node, Mixer included, animates. This needs a new plan; do not improvise it.

The owner has not answered yet. Ask before you start. If you cannot ask, build option 1 and say so at the top of your report.

## 5. How to execute the work order

`WORK-ORDER.md` was written for an executor agent. You are that executor. It has 58 numbered steps in phases A to I, run in order, in this worktree, as one serial pass.

Its "Executor rules" section binds you. In short:

- Follow the steps in order. Do not add, merge, reorder or skip steps.
- If the code contradicts a "Verified fact" or a step is impossible as written, stop and report the mismatch. Do not invent a workaround.
- Touch nothing in the "Out of scope" list.
- If a step would change something another screen also draws and the work order does not name that screen, stop and report it.
- After the last step, grep for every name in "Retired terms" and list any hit the steps did not cover.
- Every new or moved test needs one comment sentence directly above it naming the code change that would make it fail. A new test goes into an existing suite before it starts a new file.
- Folder `AGENTS.md` lines carry no dates or decision ids. `AGENTS-HISTORY.md` is append-only. `DESIGN.md` is rewritten from the code you shipped, not from the plan.

Build checkpoints are at steps 34 and 48. Tests compile as one target, so no test can run until the whole sweep is done.

## 6. Commands

Use only these wrapper scripts. Never run bare `swift build`, `swift test`, `swift run`, `swift package` or `xcodebuild`: the wrappers manage a machine-wide build-capacity pool and a second build Mac that other agents share.

```bash
bash scripts/build.sh
```

```bash
bash scripts/run-tests.sh --filter "MixerWindowControllerTests|ScenesSidebarViewControllerTests|RollingCountLabelTests|MembershipRailTests|GroupsInkTemperatureTests|GroupsHeaderParityTests|GroupRenameFieldTests|GroupEditorClickTargetTests|MembershipWellContrastTests|SidebarActionsTests|IncreaseContrastLiveReconcileTests|CompositedTokenContrastTests"
```

Done means: the build passes, the filtered run prints `Test run with N tests in 12 suites passed` with zero failures, and the retired-terms grep is clean outside `AGENTS-HISTORY.md` files and `dev/notes/`. Paste that output in your report.

A build may queue for a free capacity permit for several minutes. That is normal; wait, do not retry in a loop. `bash scripts/capacity.sh status` shows who holds what.

Tests must never open a visible window or play sound. The repo's pre-commit guard blocks code that could.

## 7. Committing, pushing, merging

- Never commit or push to `main`. All work stays on `claude/scenes-tab-redesign-ee9802`.
- Do not commit `.scratch/scenes-redesign/` unless the owner asks.
- Before the first commit, run `git config core.hooksPath .githooks` once so the guards run. The guards run the relevant tests on commit; a failing guard means fix the code, never bypass it.
- When done: `git push -u origin HEAD`, then `gh pr create --fill`, then `bash scripts/review-branch.sh` and follow what it prints.
- **Never merge.** Stop after the pull request exists and the review has run, and ask the owner. Only after a clear yes: `gh pr merge <number> --merge --auto`.

## 8. Things that will trip you up

- The `window-snapshot` executable (the offscreen renderer for this screen, run with `AUDIOUT_RUN_PRODUCT=window-snapshot bash scripts/run-app.sh <out-dir>`) currently writes blank frames. Another session is fixing that separately. Keep `AudioutCore/Sources/window-snapshot/main.swift` compiling and update its scene states as step 32 says; do not try to fix the blank frames.
- To see the real app with your change, use `bash scripts/run-app.sh` (offline, mock speakers). Building a signed `.app` under the shared dev id needs the live-test slot first: `bash scripts/livetest.sh acquire --label <branch>`. Never build the default bundle id; that overwrites the owner's installed copy.
- The editor view controller's `show(groupID:devices:)` can run before its view loads, so anything set there must survive a later `loadView`.
- A sidebar split item built with `.sidebar(withViewController:)` breaks the toolbar. Copy how the Speakers split builds its plain `NSSplitViewItem`, pinned to `SurfaceLayout.sidebarWidth` with `canCollapse = false`.
- `GroupsInkTemperatureTests` reads the editor's private `membershipWell` property by name. Do not rename it.
- Analytics event names are an external contract. The four `scene:*` captures must keep firing from the same places.

## 9. Report back

Lead with the outcome. Then: which option you built for the open decision, the pasted build and test output, the retired-terms grep result, any step you stopped on and why, and the pull request link if you got that far.
