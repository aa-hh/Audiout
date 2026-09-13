# Work order: header tab capsule leading offset on macOS 14
Revised again (orchestrator): fenced SurfaceToolbar.swift:87 after the second spec check.
Revised because: the coordinator's six spec-check findings are applied below. I re-checked each changed citation with a fresh read this session.

### Goal
On macOS 14.4 the header's tab capsule starts about 41 pt further right than on macOS 26/27. The fix moves it back to where 26/27 put it, and 26/27 get no new behaviour at all. The cause is confirmed with a throwaway probe app run in the `sonoma-14.4` VM and on this Mac. On 14.4, `NSToolbar` always starts its first item at x=91: the three window buttons' leading space stays reserved whether they are hidden, removed from the view tree, or moved. macOS 27 starts it after the visible close button: x=50 with the close dot shown, x=26 with it hidden. No public setting fixes it on 14.4:
- `.unifiedCompact` gives 80 and a shorter strip.
- `.expanded` moves the items to a second row.
- `alignmentRectInsets` puts the view at 50, but clicks on its left part no longer reach it.
- Moving the item's container once is undone by the next toolbar layout pass.

The one approach that held: on macOS below 26, the capsule moves its own toolbar container so its left edge sits at x=50 (close dot shown, the pinned window) or x=26 (close dot hidden, the menu-bar popover). It re-applies that when it joins a window, whenever AppKit moves the container, and when pin flips. That covers both window modes, which is the literal reading of "match 26/27"; the unpinned 14.4 popover moves from 91 to 26 as well.

### Verified facts
1. The tabs item's view is `SurfaceToolbarTabCapsule`, set as `item.view` with `sizingItem` wired: `SurfaceToolbar.swift:413-419`. The class is at `SurfaceToolbarSeatButton.swift:619`. It overrides no `viewDidMoveToSuperview`, `viewDidMoveToWindow` or `layout` (grep; the only overrides in :619-800 are `draw` and `intrinsicContentSize`).
2. The capsule doc at `SurfaceToolbarSeatButton.swift:617-618` says "Nothing here is behind `#available`: the package deploys to 14.2." The `SurfaceToolbarSeat` doc at `SurfaceToolbarSeatButton.swift:25` also says "the package deploys to 14.2". The real minimum is `.macOS("14.4")`: `AudioutCore/Package.swift:79`.
3. The `#available` ban exists because current-screen cues were gated to 26+, so 14–25 showed no current screen: `SurfaceToolbarSeatButton.swift:23-27` and `AudioutPopoverUI/AGENTS.md:37` ("Never put a cue behind `#available`", inside the bullet at :30-40). A layout correction for 14–25 is not a cue, so the ban does not forbid it. The doc needs amending so it stays true.
4. Root house rule 8: "Any other deviation from system chrome gets a documented 'why' in the nearest AGENTS.md" (`AGENTS.md:350-351`).
5. The toolbar uses `.unified` style: `SurfaceToolbar.swift:182`. Minimise and zoom are hidden with `isHidden` only: `ControlPanelWindowController.swift:204-205`. The close button is shown when pinned (`:276`) and hidden when unpinned (`:324`).
6. Pin order: `AppSurfaceController.setPinned` calls `shell.setPinned` and then `syncToolbar()` (`AppSurfaceController.swift:895-897`). `syncToolbar` calls `toolbarController.setPinned` (`:873-876`), which lands in `SurfaceToolbarController.setPinned` (`SurfaceToolbar.swift:192-195`). At construction the persisted pin is applied (`AppSurfaceController.swift:253`) before the toolbar is attached (`:280`). `tabsItem` is a private property of the controller (`SurfaceToolbar.swift:144`).
7. A reveal tick changes the item size through `publishWidthToItem()` and lays out the container: `SurfaceToolbarSeatButton.swift:697-699, 719-722`. The mouseDown fix starts at `SurfaceToolbarSeatButton.swift:429`.
8. Probe results, 14.4 (Build 23E214), bare `.unified` toolbar, window 653 wide, first item 140 wide:
   - Baseline: first item at x=91, container x=87. The close button spans x=19–33.
   - Unchanged at 91 with the close dot hidden, the buttons removed from the view tree, the buttons moved, or `titlebarAppearsTransparent` off.
   - Container moved once: back to 87 after an item resize.
   - Re-align approach, with the container's frame-change notification plus `viewDidMoveToWindow`, rule "container.x += target − capsule's left edge in window coordinates": x=50 at open, after an item resize to 180, after a window resize and after re-showing the window. Clicks 3 pt inside the left edge still reach the view. After hiding the close dot and calling align: x=26.
   - No loop: 5 frame writes over the whole sequence.
   - The container's superview chain is `NSToolbarItemViewer > NSToolbarView > NSTitlebarView > NSTitlebarContainerView`.
9. Probe on macOS 27 (this Mac): bare toolbar puts the first item at x=50 with the close dot shown and x=26 with it hidden. The 50 matches Alec's crops. macOS 26+ wraps every item in a glass view (`AudioutPopoverUI/AGENTS-HISTORY.md:40`), which is why the fix must not run there.
10. Real app on 14.4 (brief's accessibility readout): container at 87 plus 4 gives the capsule edge at 91, and the Mixer radio sits 3 pt inside (padding) at 94. After the fix the expected numbers are container 46 and Mixer 53 when pinned, container 22 and Mixer 29 when unpinned.
11. Package tools version is 5.10: `AudioutCore/Package.swift:1`.
12. Baseline: `bash scripts/run-tests.sh --filter 'SurfaceToolbarTests|AppSurfaceControllerTests|ControlPanelWindowControllerTests'` gives `Test run with 123 tests in 4 suites passed after 7.845 seconds.`

### Steps
1. **`SurfaceToolbarSeatButton.swift`, class `SurfaceToolbarTabCapsule`.** Add one internal method, `alignLeadingEdgeForOlderMacOS()`. On macOS 26 and later it returns immediately (`#unavailable(macOS 26)` gate).
   - Otherwise it needs a non-nil `superview` (the toolbar's item container) and a non-nil `window`, or it returns.
   - Target x: 50 if `window.standardWindowButton(.closeButton)` exists and is not hidden, else 26.
   - It converts its own bounds to window coordinates, computes `shift = target − minX`, and does nothing if `abs(shift) < 0.5`.
   - Otherwise it calls `setFrameOrigin` on the superview with x = `superview.frame.minX + shift` and y unchanged.
2. **Same class, container observation.** Add a stored `weak var observedContainer: NSView?`.
   - Override `viewWillMove(toSuperview:)`: if `observedContainer` is set, remove `self` as observer of `NSView.frameDidChangeNotification` for that object and clear it.
   - Override `viewDidMoveToSuperview()`: on macOS below 26 only, with a non-nil superview, set `postsFrameChangedNotifications = true` on the superview. Register `self` with the selector form, `NotificationCenter.default.addObserver(self, selector:name:object:)`, not the block form. Store it as `observedContainer`. The `@objc` selector method calls `alignLeadingEdgeForOlderMacOS()`.
   - Override `viewDidMoveToWindow()`: call super, then `alignLeadingEdgeForOlderMacOS()`.
   - Every override calls super.
3. **Same file, two doc edits.**
   - (a) Capsule doc, lines 617-618. Replace the sentence "Nothing here is behind `#available`: the package deploys to 14.2." with prose covering four points:
     - Nothing that draws is behind `#available`; the package deploys to 14.4.
     - The one exception is the leading-edge correction, which is layout, not a cue.
     - Why it exists: on macOS 14 (verified 14.4) a `.unified` toolbar reserves leading room for all three window buttons even when two are hidden, and puts the first item at x=91. macOS 26+ starts after the visible close button (50, or 26 when hidden).
     - Why it re-applies on every container frame change: AppKit re-places the container on each toolbar layout.
   - (b) `SurfaceToolbarSeat` doc, line 25. Change "deploys to 14.2" to "deploys to 14.4". No other word on lines 23-27 changes.
4. **`SurfaceToolbar.swift`, `setPinned(_:)` (:192-195).** After `applyPinAppearance()`, add exactly `(tabsItem?.view as? SurfaceToolbarTabCapsule)?.alignLeadingEdgeForOlderMacOS()`. Do not use the `test_tabCapsule` hook. The close button's visibility flips without moving the container, so no notification fires.
5. **`AudioutCore/Sources/AudioutPopoverUI/AGENTS.md`.** Insert one new bullet directly after the bullet ending at line 40 and before the "The animated tab-name reveal is GONE" bullet (line 41). It should say, in two or three lines:
   - Below macOS 26, `SurfaceToolbarTabCapsule` moves its own toolbar container so its left edge sits at x=50 (close dot shown) or x=26 (hidden).
   - Why: macOS 14 reserves leading room for all three window buttons and puts the first item at x=91, while 26+ lays out after the visible close button.
   - It re-applies on every container frame change and on pin flip, because AppKit re-places the container on each toolbar layout.
   - It is layout, not a cue, so the `#available` ban does not cover it.

### Out of scope — do not touch
- `ControlPanelWindowController.swift`: no window-button, style-mask or toolbar-style changes.
- `SurfaceToolbarSeat` values, tab widths, padding, `publishWidthToItem`, the mouseDown fix at `SurfaceToolbarSeatButton.swift:429-440`, the title and pin items.
- No `#available` around any drawing.
- Leave `SurfaceToolbar.swift:87` ("while the package deploys to 14.2") unchanged: it describes a removed earlier attempt.
- In `AudioutPopoverUI/AGENTS.md`, only the step 5 bullet is added. The stale "BORDERED items" bullet at :30 stays as is. No other AGENTS.md files change.
- Leave `scripts/run-on-vm.sh`, `scripts/guest-setup.sh`, the uncommitted `AUDIOUT_MOCK_BLUETOOTH` block in `AudioutCore/Sources/AudioutCore/OwnToneBackend.swift`, and `.scratch/header-capsule-offset-macos14/` alone.
- No commit, no push, no golden regeneration, no app build for the eye check.
- No cleanup, no abstractions, no error handling for impossible cases, no backwards-compat shims.

### Verification
No test on this Mac can see the change. The new code returns immediately on macOS 26+, and the suite runs on macOS 27, so no new test gets written. The check that stands in is the accessibility readout in the 14.4 VM. The executor's verification is items 1–5.

1. `bash scripts/build.sh` succeeds.
2. `bash scripts/run-tests.sh --filter 'SurfaceToolbarTests|AppSurfaceControllerTests|ControlPanelWindowControllerTests'` prints a line `Test run with 123 tests in 4 suites passed`. Trust only that line.
3. `bash scripts/run-on-vm.sh` prints a line starting `GUEST-LAUNCHED`.
4. Run the readout command below (scp `ax-toolbar.applescript`, open the popover, run the script).
   - Pass, pinned: tabs `AXGroup` x = 46 ± 3; `AXRadioButton | Mixer` x = 53 ± 3; Scenes and Settings follow at +74 and +104, with widths 74/30/30 and y=12, h=28.
   - Pass, unpinned: `AXGroup` x = 22 ± 3 and Mixer x = 29 ± 3.
   - Both profiles: title `AXGroup` x=288 w=76, and pin `AXButton` x=603 w=42, unchanged.
   - Then flip pin in the guest with `osascript -e 'tell application "System Events" to tell process "AudioutApp" to click (first button of toolbar 1 of window 1)'` and re-run the script. The other profile's numbers must appear. Flip back afterwards.
5. Still in the VM: click the Scenes tab, then Settings, via accessibility `click` on each radio, and re-read. The capsule's `AXGroup` x must stay at the same value, the tab reveal finished and the widths moved.

Readout command (from this Mac, worktree root):
```
MULE=$(git config --get audiout.remotehost)
SP=/private/tmp/claude-501/-Users-alechenderson-Projects-AirPlay-Controller--claude-worktrees-mac-app-older-macos-49adc4/b55346a0-a557-493d-93ad-d5c74e209569/scratchpad
scp -q "$SP/ax-toolbar.applescript" "$MULE":/tmp/ax-toolbar.applescript
ssh "$MULE" 'zsh -ls' <<'EOF'
IP=$(tart ip sonoma-14.4)
G="-i $HOME/.ssh/id_tart_guest -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
scp -q ${=G} /tmp/ax-toolbar.applescript alec@$IP:/tmp/ax-toolbar.applescript
ssh -n ${=G} alec@$IP 'sleep 6; osascript -e "tell application \"System Events\" to tell process \"AudioutApp\" to click menu bar item 1 of menu bar 2"; sleep 2; perl -e "alarm 60; exec @ARGV" osascript /tmp/ax-toolbar.applescript'
EOF
```

After the executor finishes, the orchestrator handles the macOS 26/27 check. It builds the standing dev id `com.audiout.Audiout.dev` under the live-test slot and hands it to Alec for an eye check of the header. There is no accessibility readout on this Mac, so that eye check is the only 26/27 visual proof.

Open question, not blocking: macOS 15.x also takes the new code path and was not probed. The rule sets an absolute position, so where 15 already lays out like 26 it does nothing. A different container view tree on 15 is unverified.

### Execution plan
- **Track A (steps 1–5), SERIAL within itself, no other tracks.** Files:
  - `AudioutCore/Sources/AudioutPopoverUI/SurfaceToolbarSeatButton.swift`
  - `AudioutCore/Sources/AudioutPopoverUI/SurfaceToolbar.swift`
  - `AudioutCore/Sources/AudioutPopoverUI/AGENTS.md`
- Model: sonnet. Effort: medium.
- Track check: Verification 1–2 here, then 3–5 in the VM.
- The working tree already has uncommitted changes, none of them part of this work order:
  - modified: `AudioutCore/Sources/AudioutCore/OwnToneBackend.swift`
  - untracked: `scripts/run-on-vm.sh`, `scripts/guest-setup.sh`, `.scratch/header-capsule-offset-macos14/`
- Verification needs the two untracked scripts, so run in this worktree, not an isolated one forked from the last commit.

### Executor rules (copy verbatim into the handoff prompt)
> - Follow the steps in order. Do not add, merge, reorder, or skip steps.
> - Before editing in any folder, read the nearest AGENTS.md above it (and the root one) if the repo has them — folder rules and traps bind even when the work order doesn't repeat them.
> - If reality contradicts a Verified fact or a step is impossible as written, STOP and report the discrepancy. Do not improvise a workaround.
> - Before reporting progress, audit each claim against a tool result from this session. Only report work you can point to evidence for. If tests fail, say so with the output.
> - If the work order names a new test, run it before making the change and paste the failing output. A test that passes before the change proves nothing.
> - "Done" means the Verification commands were run in this session and passed. Paste their output.
> - Touch nothing in the Out-of-scope list.
> - Deliver what was asked, at the scope intended. If the spec seems mistaken or a better approach exists, say so in a sentence and continue as specified rather than quietly narrowing, widening, or transforming it.

The throwaway probe sources are in `/private/tmp/claude-501/-Users-alechenderson-Projects-AirPlay-Controller--claude-worktrees-mac-app-older-macos-49adc4/b55346a0-a557-493d-93ad-d5c74e209569/scratchpad/probe/`. I made no changes to the repository.