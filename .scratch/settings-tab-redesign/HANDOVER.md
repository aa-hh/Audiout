# Handover: Settings tab redesign (direction D revised, with colour)

Written 2026-10-07 for an agent taking this over cold. Everything below is checked against the tree at the time of writing.

## Where things stand

- **Worktree:** `/Users/alechenderson/Projects/AirPlay Controller/.claude/worktrees/settings-tab-redesign-0dd6a3`
- **Branch:** `claude/settings-tab-redesign-0dd6a3`, based on `ccd0ed98` (origin/main at the time). Committed locally as `056c23ba` (the code), `872108df` (these design files) and `9cc49f6a` (roadmap 050 bookkeeping). **The branch is not pushed to origin yet.** The code commit passed Guard 4's scoped suites (1831 tests in 98 suites).
- **Code:** built in two tracks from `work-order.md` (this folder). Both tracks passed their build and their test filter. A review then found four problems (below). Those are the next job.
- **Diff** (`git show --stat 056c23ba`): 31 files, five files moved from `AudioutWindowUI` to `AudioutSharedUI`, four new source files:
  - `AudioutCore/Sources/AudioutSettingsUI/SettingsPane.swift`
  - `AudioutCore/Sources/AudioutSettingsUI/RemoteSettingsViewController.swift`
  - `AudioutCore/Sources/AudioutSettingsUI/LicenseSettingsViewController.swift`
  - `AudioutCore/Sources/AudioutSharedUI/IconLabelCellView.swift`
- **Owner:** Alec. He picked this design on 2026-10-06 and has not seen it running yet.

## What the change is

The Settings screen keeps its sidebar-plus-pane split, but:

- The sidebar has five rows: General, Audiout Remote, Appearance, Audio, License. Each row is two lines: the section name, then a live readout of what is set there ("Opens at login", "On · 2 iPhones allowed", "Match system · Full gold", "1 app stays on this Mac", "Trial · 9 days left"). Readout rule: something the user must act on wins; else the fact that changes what they hear or who can control the Mac; else the section's headline setting.
- Every pane opens with the Speakers tab's page header, showing a bare glyph with no icon well.
- Rows are `ListRowView`s on `GroupedSectionView` cards. The License pane is a recessed `.well`.
- Colour: Buy Audiout is the gold `ProminentButton` in the trial and unregistered states. The sidebar glyph and License header glyph take `Tokens.Color.ring` only while the user must act. Everything else is neutral.
- General was split into General, Audiout Remote and License. A running trial now reads "Audiout plays on every speaker until your trial ends on <date>." It used to fall through to "Registered. Thank you for supporting Audiout."
- To make this possible, `ListRowView`, `GroupedSectionView`, `PageHeaderView`, `DeviceIconWellView`, `GroupsPaneLayout` and the Speakers sidebar's two-line cell (`IconLabelCellView`, `SidebarRowView`) moved from `AudioutWindowUI` to `AudioutSharedUI`, because Settings cannot import WindowUI.

## Next job: fix the review findings

The full review text is in `review.md` (this folder). In short:

1. **Selected sidebar row loses its selection inks.** `SettingsSidebarViewController.swift` around lines 127 and 280–284: `setReadout` calls `outlineView.reloadItem(node)`. The rebuilt cell is inked as unselected and nothing re-inks it, because `reloadItem` keeps the existing `SidebarRowView`. Every readout push on the selected row (each Settings open, each Launch-at-login toggle, each key entered) leaves dark text on the accent pill. **Fix:** reconfigure the live cell in place, the way the Speakers sidebar does (`AudioutWindowUI/SidebarViewController.swift:899-905`, "Never through `reloadItem`/`reloadData`"). Get the cell with `outlineView.view(atColumn:row:makeIfNecessary: false)`, set its labels and tint, then re-ink it from its row view. Keep `noteHeightOfRows` for the line-count change. Add a test in `SettingsRootViewControllerTests` that pushes a readout to the selected row and asserts its name label uses the selection ink.
2. **License pane goes stale while the sidebar stays current.** `LicenseSettingsViewController.swift` around 333–338: `viewWillAppear` only calls `revalidate()` when the status is nil and never calls `refreshLicenseStatus()`. The header caption, status sentence, button title and Buy visibility only update on first load or on a sheet or validator event. Scenario: a trial user opens License on day 5, comes back after midnight or after the trial ends. The sidebar says "Trial · 8 days left" or "Trial ended" while the pane still says 9 days and offers the wrong button. **Fix:** call `refreshLicenseStatus()` at the top of `viewWillAppear`. Add a test that moves the trial expiry and re-shows the pane.
3. **Stale AppDelegate wiring.** `AppDelegate.swift:217-222`, `:652`, `:2511`: `generalSettingsController` is written but never read, and two comments still describe the old General-hosts-the-licence wiring. **Fix:** delete the property and its assignment; reword the two comments to name the License section.
4. **Unverified key is re-checked less often.** Before, General's `viewWillAppear` re-asked the server about an unanswered key on every Settings open. Now only the License pane does, plus launch. "Key saved, not verified" can persist across Settings opens. **Fix:** call the licence controller's `revalidate()` (only when the status is nil) from `SettingsRootViewController.refreshReadouts()`, or from `AppDelegate` where it already reacts to Settings becoming visible (`AppDelegate.swift:1455`). Pick one and say which.
5. Not a code fix: `AudioutSettingsUI/AGENTS-HISTORY.md:95, 143, 145, 158` still name `BorderedListView` and `SettingsForm.sectionHeader`. That file is append-only. Leave it.

After the fixes, run:

```bash
bash scripts/build.sh
bash scripts/run-tests.sh --filter 'SettingsRootViewControllerTests|GeneralSettingsCompanionTests|SettingsAccentAndHintsTests|AudioSettingsLatencyTests|AudioSettingsRemoteReloadTests|AudioSettingsWakeRestoreTests|AboutSectionTests|AppSurfaceControllerTests|SurfaceScreenSwitchCostTests|IncreaseContrastLiveReconcileTests|LicenseDeepLinkTests'
```

Track A's filter, which covers the moved views, passed and its files are untouched by these fixes:

```bash
bash scripts/run-tests.sh --filter 'DeviceIconWellViewTests|GroupsHeaderParityTests|MembershipWellContrastTests|SidebarActionsTests|SpeakersPageTests|DeviceDetailViewTests|IncreaseContrastLiveReconcileTests|PopoverControllerTests'
```

## After the fixes

1. **Show Alec a running build** before any PR. This is a UI change he has only seen as an HTML comp. The project rule on bundle ids applies (root `CLAUDE.md`, "Know what is being tested"): UI work reuses the standing dev id, and that needs the live-test slot first:
   ```bash
   bash scripts/livetest.sh acquire --label claude/settings-tab-redesign-0dd6a3
   APP_NAME="Audiout Dev" BUNDLE_ID="com.audiout.Audiout.dev" bash scripts/make-app.sh
   ```
   If the slot is busy, report who holds it and use a fresh id instead. Release the slot (`bash scripts/livetest.sh done`) the moment Alec gives a verdict. Things to look at: every pane in light and dark; the selected row's inks after toggling Launch at login (finding 1); a trial build's License pane; Increase Contrast on; VoiceOver on a sidebar row (should read "License, Trial, 9 days left").
2. **Commit** the fixes on this branch (never on `main`). The pre-commit guards run the scoped suites. Guard 11 checks every new test for its "Red if…" sentence and bans real-time waits.
3. **Land it** through the PR flow in root `CLAUDE.md` ("Critical workflow rules"): push, `gh pr create --fill`, `bash scripts/review-branch.sh` (run the printed passes as subagents, then `--continue`). **Do not merge** without Alec's explicit yes.

## Open items Alec has not ruled on

- During a trial, "Enter license…" opens the licence sheet already filled with the trial key (`LicenseSheetViewController.swift:84`). The sheet was out of scope.
- The shipped light-mode theme tile ring is gold at 1.77:1, under the 3:1 floor for non-text. Flagged in `direction-d2-color/notes.md`, not changed.
- The analytics events doc in the `audiout-shared` repo describes `settings:pane_selected`'s `pane` as "the clicked pane's title" without listing values, so the two new titles ("Audiout Remote", "License") need no doc change. Do not edit that repo from here.
- The `RuleView` doc comment still says Settings uses the stock separator.

## Reading path

Read in this order. Stop when you have what you need for the job in hand.

1. **This file.**
2. **Repo rules:** root `CLAUDE.md` (build, test, commit and landing rules; never a bare `swift build` / `swift test`), root `AGENTS.md` (architecture rules and traps).
3. **Folder rules** for every folder you touch: `AudioutCore/Sources/AudioutSettingsUI/AGENTS.md`, `AudioutSharedUI/AGENTS.md`, `AudioutWindowUI/AGENTS.md`. Grep the matching `AGENTS-HISTORY.md` before debugging anything in that folder.
4. **Product and design truth:** `PRODUCT.md` (voice, users, licence model) and `DESIGN.md` (tokens, components; the Settings paragraph under Layout was rewritten by this change).
5. **The spec Alec approved:**
   - `direction-d2/brief.md`: the design brief, readout strings per state, assumptions.
   - `direction-d2-color/comp.html` and `comp.png`: the visual truth, dark and light, every pane and the sidebar in eight households.
   - `direction-d2-color/notes.md`: the colour decisions with contrast figures.
   - `inputs.md`: the content inventory and hard constraints every direction was held to.
6. **The work order:** `work-order.md`. The Verified facts section maps every file and line the change touched; the Steps section is what was built; Out of scope lists what must not change.
7. **The review:** `review.md`.
8. **The code:** `git show 056c23ba`. Start with `SettingsRootViewController.swift` and `SettingsSidebarViewController.swift`, then the five pane controllers, then `AppDelegate.makeSettingsRoot()`.
9. **Background only, if you want the why:** `compare.html` (the four directions and the pick), `direction-a` to `direction-d` (rejected directions with their briefs).

All paths without a leading folder are in `.scratch/settings-tab-redesign/` in the worktree.
