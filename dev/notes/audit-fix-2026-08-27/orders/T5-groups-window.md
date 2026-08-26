# T5 work order — Mixer/Groups window (`AudioutWindowUI`) audit fixes

**Branch:** `claude/fix-groups-window` — create as a worktree from this audit branch's HEAD
(`git worktree add .claude/worktrees/fix-groups-window -b claude/fix-groups-window`, then
`git push -u origin claude/fix-groups-window`). The parent tree is clean; no uncommitted work is needed.

**Owned files (may edit):**
- `AudioutCore/Sources/AudioutWindowUI/*` (all files) and its `AGENTS.md`
- `AudioutCore/Sources/AudioutSharedUI/DeviceIcon.swift` — ONLY the top `enum DeviceIcon` half (cache addition, Track 4). **Collision note:** track T2 (a separate work order) edits `DeviceIconController` (the persistence half, bottom of the same file). Keep your hunk inside `enum DeviceIcon`; expect a nearby textual merge.
- `AudioutCore/Sources/AudioutApp/AppDelegate.swift` — ONLY `installMainMenu()` (:1219-1240). Narrow sanctioned exception: T7 owns the rest of AppDelegate. Smallest possible hunk; flag it in your final report.
- Test files: `MixerWindowControllerTests.swift`, `MembershipRailTests.swift`, `SidebarActionsTests.swift`, `GroupRenameFieldTests.swift`, `IconPickerTests.swift`, `DeviceDetailViewTests.swift`, `DeviceIconResolverTests.swift` (all under `AudioutCore/Tests/AudioutCoreTests/`).

**Binding build/test rule (from the coordinator):** ALL compiles and test runs go through the wrapper scripts, which route work to the remote test mule: `bash scripts/build.sh` and `bash scripts/run-tests.sh --filter <Suite>` (full suite only for the final check). Bare `swift build` / `swift test` is FORBIDDEN — it opts out of the mule, the machine-wide concurrency cap and the sources cache, and pins work to the machine running many parallel agents (a repo hook also blocks it). `AUDIOUT_BUILD_LOCAL=1` only if the mule is unreachable, and report that you used it. Traps: never pipe `run-tests.sh` through `| tail` (it eats the exit code — redirect to a file and read the file); never kill/abandon an in-flight remote test run (orphaned legs pin the build lock).

**Handoff notes for the reviewer:**
- The AppDelegate hunk (Step 22) is a sanctioned one-off inside T7's territory.
- `DeviceIcon.swift` will merge against T2's persistence-half changes.
- `MembershipRailTests.swift` is edited by Tracks 1 and 3 (different regions; the runner merges).
- Preserve the module's theming (zero hard-coded colours — every new label uses `Tokens.Color.*`, which are stock semantics for text) and the EQ accessibility work untouched. Regressions there are unacceptable.

---

## Goal

Fix the audit findings for the Groups window (sidebar + group editor + device detail + creation sheet + icon picker) so the surface stops lying on its highest-stakes action (deleting the group that is playing), stops tearing down the content pane on every backend event (which destroys typing, clicks and keyboard focus several times a second during discovery), reports failures it currently swallows, and closes a set of small honesty/accessibility/HIG gaps. Audience: a general Mac user with saved speaker groups and live audio in other rooms — copy is plain speech, and the UI never claims a state the model does not have.

## Verified facts

The executor may rely on these without re-deriving them. Line numbers are pre-change.

- Delete alert copy `"Deleting a group doesn't change which speakers are playing."` at `AudioutWindowUI/GroupEditorViewController.swift:846`; Delete is the first (default) button (:847), and a window-less pane deletes with NO confirmation (:855-857). `test_confirmDelete()` exists at :1017-1020; `performDelete(id:)` at :1004-1014; `editingGroup` computed property at :652-655.
- `GroupController.deleteGroup(id:)` (`AudioutCore/Sources/AudioutCore/GroupController.swift:629-634`): if the deleted group is the Main Out target it calls `setMainOut(.selectedDevices)` (:631) → `applyRouting()` (:457-462, :469-488) → `backend.setOutputSet(routableOutputIDs)` — playback switches to the Selected Devices set's AirPlay members. A group speaker that is ALSO in Selected Devices keeps playing; one that is not, stops. So the audit's suggested sentence ("stops sending audio to its speakers") is NOT exactly true; the wording in Step 1 is.
- `MixerWindowController.refreshAll()` re-shows the editor unconditionally on every visible-screen backend event (`MixerWindowController.swift:491-494`); `update(devices:)` gates only on visibility (:297-301). The sidebar has a projection gate (`reloadSidebarIfNeeded` + `SidebarProjection`, :540-591) with seam `test_sidebarReloadCount` (:537, :553) and an unconditional user-action variant `refreshSidebar()` (:531-538). Editor wiring block at :219-248; create-sheet `onComplete` at :428-435.
- `GroupEditorViewController.show(groupID:devices:)` (:542-570) writes `nameField.stringValue = group.name` (:547) with no `currentEditor()` check, then `rebuildCandidates` (:588-591) → `buildRows` (:594-628), which destroys and rebuilds every `MembershipRowView`. `saveOrReport` (:682-692) re-renders via `show(...)` on a save failure (:688); its alert helper `presentPersistFailureAlert` at :697-704. `membershipToggled` (:760-788) calls `rebuildCandidates` directly. `commitRename` at :664-674; `restoreNameField` :708-712; `cancelRename` :718-722.
- `MembershipRowView.apply(device:checked:iconSymbolName:)` exists at `MembershipRowView.swift:249-280` and resets `checkbox.isEnabled = true` (:255). The checkbox a11y label is set once in `apply` (:276-277: `"Remove/Add \(device.name) …"`), never on toggle (`checkboxToggled` :396-400, `isChecked` setter :117-124). `railArmed` property :54-55. Sole-member pinning: `GroupEditorViewController.swift:619-622` (tooltip string at :621); `membershipWell.rows` re-point at :626; `updateRail()` at :638-643.
- Rail armed tone: `buildRows` sets `row.railArmed = isActiveGroup` (:603) — ALL rows of the active group's editor go gold, saved-membership-driven. `Device.isSelected` means "currently in the backend's output set (streaming now)" (`AudioutCore/AGENTS.md`; `Device.swift:126`); `Device.isLocalDevice` at `Device.swift:91`. `GroupController.saveGroup` is a pure model op (:559-568) — editing an active group's membership does not re-route. The synced-local sink for the Mac arms off saved Main-Out membership (`GroupController.isMainOutMember(_:)`, :822; `mainOutMemberIDs` :762-767 reads the group's saved members).
- `cancelRename()` calls `nameField.window?.makeFirstResponder(nil)` (:718-722) — the exact dead-Tab state A11Y-GROUPS fixed (`SidebarViewController.swift:152-159`). The sidebar's `outlineView` is a private property (`SidebarViewController.swift:92`).
- Creation sheet: `commit()` swallows a thrown `createGroup` via `try?` (`GroupCreationSheetController.swift:380-383`) and ignores `alreadyExisted`; `finish` dismisses only when `view.window != nil` (:396-399). `configure` filters candidates to `isAvailable` (:271-278); `buildRows` (:281-301) pins rows to the stack edges (:298-299); Create enablement `isCreateEnabled` (:313). `GroupController.createGroup` dedups by member SET and returns `alreadyExisted` (:591-607); nothing anywhere blocks duplicate NAMES.
- Main menu is App + File▸Close only — no Edit menu (`AudioutApp/AppDelegate.swift:1219-1240`), so ⌘C/⌘V/⌘X/⌘A/⌘Z are dead in every text field of the app.
- Icon picker filter matches raw symbol names only (`IconPickerViewController.swift:359-362`); the plain-language map + `accessibilityLabel(forSymbol:)` exist at :287-318. `refreshSelectionRingColor()` (:271-279) is called only at build time and from `viewDidChangeEffectiveAppearance` (via `AppearanceObservingView`, :98-101, :472-478) — neither `Tokens.accentStyleDidChangeNotification` (`Tokens.swift:72-73`) nor the workspace a11y notification is observed. The two-observer pattern to copy: `AudioutSharedUI/EQResponseCurveView.swift:208-217`.
- Sidebar cells: `makeIconLabel` (`SidebarViewController.swift:868-886`) conveys unavailable/active by colour/glyph only, and gives the icon image the row's own name as `accessibilityDescription` (:874). `select(_:notify:)` returns silently when the target node is gone (:440-447; `suppressSelectionCallback` :444-449). The context-menu device item's title is fixed `"New Group from Selection…"` (:733-739) while the clicked/selected ids are already computed there (:736-737); the bottom bar already retitles `"New Group from \(count) Speakers…"` (:293-299). `SidebarContainerView.performKeyEquivalent` claims ⌘N unconditionally (:699-707); `test_performCmdN()` drives it (:600-607); `reload` restores selection at :416.
- Device detail: `refreshUI()` calls `rebuildGroupRows()` unconditionally (`DeviceDetailViewController.swift:520-549`); `rebuildGroupRows` (:650-671) rebuilds one `NSButton` per group with a fresh `NSImage` (:722-725; chevron :734-738); `shownGroupIDs` at :123/:657. Name label built at :179-187; About value labels (`statusValueLabel`/`kindValueLabel`/`airPlayValueLabel`, :111-113) flow through `makeMetadataRow` (:472-499); none are selectable. Stale "user-resizable with drag memory" doc comments at `DeviceDetailViewController.swift:51-53` and `MainOutDetailViewController.swift:28-30`.
- The empty-state headline uses `Tokens.Color.secondaryLabel` (`MixerWindowController.swift:856`). `Tokens.Color.label` is stock `.labelColor` (`Tokens.swift:83`) and `.labelColor` is in `GroupsWindowTextColorLockTests`' allowed stock list (:100-109), so Step 7 passes the colour lock.
- Test fixtures: `MixerWindowControllerTests.makeWindow()` (:29-42, demo fleet of 7, `test_isVisibleOverride`), `makeGroup1` (:49-53 — members `sonos-move`+`office`, actually selected, so their `isSelected` echoes true); `MembershipRailTests.makeEditor()` (:243-263 — hand-built devices with default `isSelected == false`, group members `office`+`mixer`); `activeGroupDrivesTheNodeToneToo` (:355-372) asserts ALL rows armed for the active group — it pins the OLD semantics and must be updated by Step 4. `SidebarActionsTests` menu-title expectations at :51-52, :78, :89, :99; ⌘N tests at :144-180. Icon search tests (`IconPickerTests.swift:53-113`) keep passing under Step 19 (no curated plain-language label adds a "pod" match the raw names lack — checked by hand against the :287-312 map). `GroupsWindowTextColorLockTests` builds sidebar cells through the public `outlineView(_:viewFor:item:)` (:241-243) — reuse that pattern for Step 11's test. To force a `GroupStore.save` throw in a test: create a plain FILE at `scratchDir/"blocker"`, then `GroupStore(directory: scratchDir/"blocker"/"sub")` — `createDirectory` throws (`GroupStore.swift:126-132`). New suites inherit `IsolatedSuite`; existing edited suites already do.
- Module rules constraining the diffs (`AudioutWindowUI/AGENTS.md`): the editor pane has NO scroll view and ZERO height headroom at 7 devices (`theActiveGroupsMarkersAddNoHeightToTheEditorPane`) — nothing in this order may add a vertical band to the editor pane; text colours frozen to stock greys; the `membershipWell` property NAME is load-bearing (reflection in tests); window-snapshot goldens are unreproducible — NEVER regenerate; no absolute-width assertions in the Groups pane (AppKit rounding grid varies BETWEEN RUNS).

## Steps

String conventions: match the files' existing style — `\u{201C}`/`\u{201D}` for curly quotes and `\u{2019}` for apostrophes inside Swift string literals; literal `…` in menu/button titles.

### Track 1 — editor, window shell, sidebar, creation sheet

1. **P0-1 + P2-2 + hardening-16 + P2-6 — the delete confirmation.** In `GroupEditorViewController.swift`, extract the alert construction from `deleteTapped` (:839-858) into a private `makeDeleteAlert(for group: Group) -> NSAlert`; `deleteTapped` resolves the group via the existing `editingGroup` property (return if nil). The alert:
   - `messageText` = `Delete \u{201C}<group.name>\u{201D}?`
   - `informativeText` branches on `groupController.activeGroupID == group.id`:
     - active: exactly `This group is playing now. Deleting it switches playback to Selected Devices; speakers that are only in this group will stop.`
     - inactive: the existing sentence, unchanged.
   - Buttons stay in the current order (Delete first, so the `.alertFirstButtonReturn` mapping at :853 is untouched); then set `alert.buttons[0].hasDestructiveAction = true`, `alert.buttons[0].keyEquivalent = ""`, `alert.buttons[1].keyEquivalent = "\r"` (Cancel becomes the Return default).
   - The window-less `else` branch (:855-857) becomes a plain `return` with a comment naming `test_confirmDelete()` as the headless path.
   - Add seam `public func test_makeDeleteAlert() -> NSAlert?` (nil when nothing is being edited).
   - Tests (MixerWindowControllerTests): (a) inactive group → informative text is the existing sentence, message names the group, `buttons[0].hasDestructiveAction`, `buttons[0].keyEquivalent == ""`, `buttons[1].keyEquivalent == "\r"`; (b) after `controller.activateGroup(id:)` + re-`update` → the active sentence; (c) headless `requestDelete()` no longer deletes (`controller.groups.count` unchanged) and `test_confirmDelete()` still does.

2. **P1-1(b) — the editor's projection gate.** In `GroupEditorViewController.swift`, split `show(groupID:devices:)` (:542-570): move its body into a new private `render(group:devices:)`; the public `show` resolves the group (existing guard), builds an `EditorProjection`, returns early when it equals `lastRenderedProjection`, else calls `render`. `render` computes and stores `lastRenderedProjection` itself at its end (single writer), so the failure re-render in `saveOrReport` (:688) — change it to call `render` directly with the freshly resolved group — always repaints and re-syncs the projection. `EditorProjection` is a file-private Equatable struct capturing exactly what the editor renders: group id, group name, resolved icon symbol (`DeviceIcon.resolve(group.iconSymbolName, default: Group.defaultIconSymbolName)`, the same call as :576), active flag (`groupController.activeGroupID == groupID`), and one row entry per candidate — candidates computed with the same rule as `rebuildCandidates` (:589: available OR member) — holding device id, name, `isAvailable`, resolved row icon (`deviceIconController?.symbolName(for:) ?? device.kind.symbolName`), membership flag, and the armed value from Step 4's rule. A projection stale toward re-rendering (e.g. after `membershipToggled`'s direct `rebuildCandidates`) is fine — the gate may only err toward rendering, never toward skipping. Add seam `public private(set) var test_renderCount = 0`, incremented in `render`.
   - Test (MixerWindowControllerTests, mirroring `sidebarReloadSkipsAnEQOnlyChangeButNotARename` :211-227): open a group's editor; an EQ-only device change through `window.update(devices:)` leaves `test_renderCount` unchanged; a device rename bumps it by 1.

3. **P1-1(a) — never overwrite a field being typed in.** Inside `render`, wrap the `nameField.stringValue` write and its `updateNameFieldWidth()` (:547-548) in `if nameField.currentEditor() == nil { … }`. Everything else in `render` still runs.
   - Test (GroupRenameFieldTests, reusing the hosted-window pattern at :251-268 including its early-return-when-no-field-editor compromise): focus the title field, set the field editor's string to a half-typed name, then call `editor.show(groupID:devices:)` with the same group but one device renamed (so the gate passes and `render` runs); the field editor's string is unchanged.

4. **P2-1 — rail armed = "this speaker is receiving the Main Out feed now".** In `buildRows`, replace :603 with: `row.railArmed = isActiveGroup && (device.isLocalDevice ? memberSet.contains(device.id) : device.isSelected)`. For AirPlay/BT/Cast rows the routed truth is the backend echo `isSelected`; for the local Mac the synced-local sink follows saved Main-Out membership, which for this (active) group IS `memberSet`. Node FILL stays checked-driven (unchanged). Resulting vocabulary, all honest: checked+routed = gold filled (live member); checked+not-routed = ember filled (saved, not live — the audit's "fills gold while nothing is sent" lie, fixed); unchecked+still-routed = gold hollow (still receiving, no longer saved); unchecked+unrouted = ember idle. The hook, well ring and "Playing now" badge stay keyed to the active flag (unchanged) — the reassurance line (:135-150) carries the rest. Apply the same expression in Step 5's reuse path. Update the stale doc comment at :78-84 and the `AudioutWindowUI/AGENTS.md` "Gold means LIVE… armed/idle end to end" bullet to state the per-row routed truth (docs land with code).
   - Tests: rewrite `MembershipRailTests.activeGroupDrivesTheNodeToneToo` (:355-372): after `activateGroup`, rebuild the devices array with `isSelected = true` on the member devices (`office`, `mixer`) before `editor.show(...)`; expect armed true for those two and false for `a`/`c`/`e`. Add two cases: a member device with `isSelected == false` reads idle; a non-member device with `isSelected == true` reads armed. `activeGroupDrivesTheOriginHookTone` (:343-353) is unchanged and must keep passing.

5. **P1-2 — reuse rows instead of rebuilding.** In `rebuildCandidates(memberSet:)` (:588-591): compute the new candidate list into a local BEFORE overwriting `candidateDevices`; if its id sequence equals `candidateDevices.map(\.id)` and `rowsByID` is non-empty, assign the property and update in place — per device: `rowsByID[id]?.apply(device:checked:iconSymbolName:)` (signature at `MembershipRowView.swift:249`), then Step 4's armed assignment; re-apply the sole-member pinning exactly as :619-622 (`apply` re-enables, so pinning must re-run after it); then re-point `membershipWell.rows` (:626) and call `updateRail()`. Otherwise fall through to the existing assign + `buildRows`. Add seam `public func test_membershipRow(for deviceID: String) -> NSView?` returning `rowsByID[deviceID]`.
   - Test: grab a row instance; `editor.show(...)` with the same candidates but a changed device name → same instance (`===`) and `test_candidateDeviceIDs` unchanged; `show(...)` with a device removed → the row for a remaining id is a fresh instance (rebuilt).

6. **P2-3 — Escape hands focus somewhere real.** In `cancelRename` (:718-722) delete the `makeFirstResponder(nil)` line and invoke a new `public var onDidCancelRename: (() -> Void)?` instead. In `SidebarViewController` add `public func claimKeyboardFocus()` (the window's `makeFirstResponder(outlineView)`) and seam `public var test_outlineIsFirstResponder: Bool`. Wire in `MixerWindowController`'s editor block (:239-248): `onDidCancelRename` → `sidebarViewController.claimKeyboardFocus()`. Update the `AudioutWindowUI/AGENTS.md` bullet "nothing else ever calls `makeFirstResponder`" to name this sanctioned site.
   - Test (GroupRenameFieldTests): host `window.contentController`'s view in an NSWindow (never ordered front — tests stay invisible), `makeFirstResponder` the title field (early-return if no field editor, per the file's existing compromise), send `cancelOperation(_:)` through the field editor; expect `test_outlineIsFirstResponder == true` and the window is not its own first responder.

7. **P3-1 — headline hierarchy.** `MixerWindowController.swift:856`: `messageLabel.textColor = Tokens.Color.label` (stock `.labelColor` — passes the colour lock; the subtitle stays tertiary).

8. **P2-8 — a gone selection clears the highlight.** In `SidebarViewController.select(_:notify:)` (:440-447): when `findNode` returns nil or `row < 0`, set `suppressSelectionCallback = !notify`, call `outlineView.deselectAll(nil)`, reset the flag, return.
   - Test (SidebarActionsTests): select `.group(id: "g1")`, `reload` with only `g2` present, expect `currentSelection == nil`.

9. **P2-9 — the context-menu title says what it acts on.** In `menuNeedsUpdate`'s device case (:733-739): one id → title `New Group from \u{201C}<device.name>\u{201D}…` (a 1-element `ids` is always the clicked row); several → `New Group from <ids.count> Speakers…` (the same format as :295). Update `SidebarActionsTests` :51-52 (nothing selected → the quoted-name title), :78 (2 selected, clicked inside → `New Group from 2 Speakers…`), :89 (clicked outside the selection → quoted-name), :99 (quoted-name); add one assertion for the 2-selected TITLE via `test_contextMenuItems`.

10. **P3-2 — ⌘N yields to a field editor.** At the top of `SidebarContainerView.performKeyEquivalent` (:699-707): if `window?.firstResponder` is an `NSTextView` whose `isFieldEditor` is true, return `super.performKeyEquivalent(with: event)`. Leave the `razor:` comment as is.
    - Test (SidebarActionsTests): host the sidebar's view plus an editable `NSTextField` in an NSWindow (not ordered front), focus the field (early-return if no field editor appears), expect `test_performCmdN() == false` and no callback fired. The three existing headless ⌘N tests (:144-180) must keep passing unchanged.

11. **P1-8 + P3-6 — sidebar VoiceOver state.** In `makeIconLabel` (:868-886): build `let spoken = text + (dimmed ? ", unavailable" : "") + (showsActiveMarker ? ", playing now" : "")` and call `cell.textField?.setAccessibilityLabel(spoken)` on EVERY pass (cells are reused — the unconditional set is what clears a stale suffix). Same words the visible UI uses ("Unavailable" annotation, "Playing now" marker/tooltip). Also change :874 to pass `accessibilityDescription: nil` (decorative — the text field speaks; matches `DeviceDetailViewController.swift:736`).
    - Test (SidebarActionsTests or MixerWindowControllerTests, via the public `outlineView(_:viewFor:item:)` pattern from `GroupsWindowTextColorLockTests:241-243`): an unavailable device cell's text-field a11y label ends `, unavailable`; the active group's ends `, playing now`; an ordinary cell's equals the bare name; the icon image's `accessibilityDescription` is nil.

12. **P1-4 — the creation sheet reports a failed save.** In `GroupCreationSheetController.commit()` (:372-385) replace the `try?` guard with `do/catch`; on catch: set a new seam `public private(set) var test_saveFailureReported = false` to true, and — only when `view.window != nil` — present an `NSAlert` sheet on it: `messageText` `Couldn\u{2019}t create the group.`, `informativeText` `The group couldn\u{2019}t be saved. Try again.`, style `.warning` (mirrors `GroupEditorViewController.presentPersistFailureAlert`, :697-704). Return with the form intact — no `finish`, Create stays enabled.
    - Test (MixerWindowControllerTests): build the sheet over a `GroupController` whose `GroupStore` directory is un-creatable (the blocker-file fixture in Verified facts); `test_commit()` → `onComplete` never fired, `test_saveFailureReported == true`, `test_nameFieldText` and `test_checkedDeviceIDs` intact.

13. **P1-3 — `alreadyExisted` is said out loud.** Still in `commit()`: when `result.alreadyExisted` and `view.window != nil`, do NOT `finish` immediately — present an `NSAlert` sheet: `messageText` `Those speakers are already saved as \u{201C}<result.group.name>\u{201D}.`, `informativeText` `You can open that group, or go back and change the selection.`, first button `Open \u{201C}<result.group.name>\u{201D}` (default), second `Go Back`. Open → `finish((group:alreadyExisted:))` exactly as today; Go Back → nothing (sheet stays, form intact). Window-less (headless/test) runs keep today's behavior: `finish(result)` directly.
    - Test: a headless dedup commit (create a group, then commit a sheet with the identical member set) still calls `onComplete` with `alreadyExisted == true` — a behavior lock on the headless path. The existing `createSheetDedupsIdenticalMemberSetToExistingGroup` and `createSheetDedupDoesNotOverwriteExistingGroupsIcon` must keep passing unchanged.

14. **P2-5 — duplicate names refused with an explanation.** Two commit sites, one rule: a trimmed name that `localizedCaseInsensitiveCompare`s equal to ANOTHER group's name is refused.
    - `GroupEditorViewController.commitRename` (:664-674): after the `trimmed != group.name` guard, check `groupController.groups` excluding `group.id`; on a hit: `restoreNameField()`, set a new seam `public private(set) var test_duplicateNameRefused = false` to true, present (window-guarded, shape of :697-704) `messageText` `That name is already taken.`, `informativeText` `Another group is named \u{201C}<trimmed>\u{201D}. Choose a different name.`, and return before `saveOrReport`.
    - `GroupCreationSheetController.commit()`: the same check against ALL groups BEFORE `createGroup` (refusing the name wins over resolving the member set); same copy, alert on the sheet's window, form intact, its own `test_duplicateNameRefused` seam.
    - Tests: rename to an existing name (different case) → model unchanged, field restored, seam true; renaming a group to its OWN name with different case is still allowed; sheet commit with a taken name → `onComplete` not fired, `groups.count` unchanged, seam true.

15. **P1-5 — honest empty checklist.** In `GroupCreationSheetController.buildRows()` (:281-301): when `candidateDevices` is empty, add one non-interactive row to the stack — `NSTextField(wrappingLabelWithString:)` with exactly `No speakers found yet. Speakers appear here once they\u{2019}re reachable on your network.`, `Tokens.Color.secondaryLabel`, `Tokens.Font.body`, pinned to the stack's edges like the rows (:298-299). Add seam `public var test_emptyChecklistText: String?` (the label's text when mounted, else nil).
    - Test: `configure` with zero available devices → seam returns the copy and `test_isCreateEnabled == false`; with one available device → seam nil.

### Track 2 — device detail + Main Audio panes

16. **P2-7 — group-rows change gate.** In `DeviceDetailViewController.rebuildGroupRows()` (:650-671): compute a projection array of `(id, name, resolvedSymbol)` per member group (resolution exactly as :722: `DeviceIcon.resolve(group.iconSymbolName, default: Group.defaultIconSymbolName)`); early-return when it equals the stored last projection; else store and rebuild as today (an empty list compares equal to empty, so the "None" row is stable too). Add seam `public private(set) var test_groupRowsRebuildCount = 0`, incremented on an actual rebuild.
    - Test (DeviceDetailViewTests): show a device that is in one group; baseline the count; `refresh(device:)` with only a volume/connection change → unchanged; rename the group in the controller and `refresh` again → +1.

17. **P3-3 — copyable facts.** Set `isSelectable = true` on `nameLabel` (in the :179-187 block) and on `valueLabel` inside `makeMetadataRow` (:472-499). Nothing else about the labels changes.
    - Test (DeviceDetailViewTests): the field carrying the device name and the three About value fields report `isSelectable == true` (walk `view`'s descendant text fields).

18. **P3-4 — stale doc comments.** `DeviceDetailViewController.swift:51-53` and `MainOutDetailViewController.swift:28-30`: replace the "the screen is user-resizable with drag memory" clause so both read (grammar adapted per sentence): "…the Equalizer's Advanced fold exceeds the Groups screen's height budget, and the surface frame is FIXED for every screen (`AppSurfaceController` — the frame never changes), so scrolling is the only room; growing the window was rejected (roadmap 039)." Comment-only; no code change.

### Track 3 — icon picker + membership row

19. **P1-7 — search speaks the user's words.** `IconPickerViewController.updateCuratedGrid` (:359-362): keep a name when the trimmed text is a case-insensitive substring of the raw name OR of `Self.accessibilityLabel(forSymbol:)` (:314). One predicate change.
    - Tests (IconPickerTests): `"kitchen"` → result contains `fork.knife`; `"living"` → contains `sofa.fill`; `"apple tv"` → contains `appletv.fill`. The four existing filter tests (:53-113) must keep passing unmodified.

20. **Design-system P3-5 (assigned here from T9) — live ring re-resolution.** In `loadView` (near the `AppearanceObservingView` hookup, :98-101) register two selector-based observers on one new `@objc` method that calls `refreshSelectionRingColor()`: `NSWorkspace.shared.notificationCenter` for `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification`, and `NotificationCenter.default` for `Tokens.accentStyleDidChangeNotification` — copy the shape at `EQResponseCurveView.swift:208-217` (no removal needed; post-10.11 AppKit auto-unregisters). Add seam `public private(set) var test_ringRefreshCount = 0`, incremented inside `refreshSelectionRingColor()`.
    - Test (IconPickerTests): `configure(currentSymbolName:defaultSymbolName:)` so a ring exists, load the view, baseline the count, post both notifications (posting the real workspace notification from a test is the established pattern — `AudioutSharedUI/AGENTS.md`), expect the count to rise by 2.

21. **P2-4 — the checkbox label follows the toggle.** In `MembershipRowView.swift`: extract the two-line label composition at :276-277 into a private `updateCheckboxAccessibilityLabel()` reading the current `checked`/`device`, called from `apply`, from `checkboxToggled` (:396-400), and from the `isChecked` setter (:117-124). Add seam `public var test_checkboxAccessibilityLabel: String?`.
    - Test (MembershipRailTests): an unchecked row announces `Add Office to group`; after `test_toggle()` → `Remove Office from group`; after `isChecked = false` → back to Add.

### Track 5 — Edit menu

22. **P1-6 — standard Edit menu.** In `AppDelegate.installMainMenu()` (:1219-1240), after the File item add an Edit `NSMenuItem` + `NSMenu(title: "Edit")` with, in order (ALL `target: nil`, so they travel the responder chain):
    | Title | Action | Key equivalent |
    |---|---|---|
    | Undo | `Selector(("undo:"))` | `z` |
    | Redo | `Selector(("redo:"))` | `Z` (capital = ⌘⇧Z) |
    | — separator — | | |
    | Cut | `#selector(NSText.cut(_:))` | `x` |
    | Copy | `#selector(NSText.copy(_:))` | `c` |
    | Paste | `#selector(NSText.paste(_:))` | `v` |
    | Delete | `#selector(NSText.delete(_:))` | none |
    | Select All | `#selector(NSText.selectAll(_:))` | `a` |
    Extend the method's doc comment by one sentence (the field editor implements the verbs; the key equivalents only fire if a main-menu Edit menu carries them). NOTHING else in AppDelegate changes — a sanctioned one-off in T7's file; flag it in the report. No test (menu construction has no existing coverage); `bash scripts/build.sh` is the check.

### Track 4 — symbol-image cache (SERIAL, after Tracks 1/2/3 merge)

23. **P2-12 — cache resolved symbol images in `DeviceIcon`.** In `AudioutSharedUI/DeviceIcon.swift`, inside `enum DeviceIcon` (top half only — see the T2 collision note): add `public static func image(_ name: String, pointSize: CGFloat? = nil, weight: NSFont.Weight = .regular) -> NSImage?` — resolves `NSImage(systemSymbolName: name, accessibilityDescription: nil)`, applies the symbol configuration when `pointSize` is given, sets `isTemplate = true`, memoizes in a private static dictionary keyed on all three (a string key `"\(name)|\(pointSize ?? -1)|\(weight.rawValue)"` is fine), documented main-thread-only (all call sites are AppKit view code), no eviction (bounded by the curated set + device kinds × a few sizes). Returned images are SHARED — callers must not mutate them (tinting stays a view property, which every call site already uses).
    Adopt at exactly three row-build sites: `SidebarViewController.makeIconLabel` (:874, no pointSize), `MembershipRowView.apply` (:257-264 → `DeviceIcon.image(symbolName, pointSize: PopoverColumnGrid.iconGlyphPointSize, weight: .regular)` — the row-level a11y label from :274/Step 21 carries the name; the image description was redundant), and `DeviceDetailViewController.makeGroupRow` (:722-725 group icon and :734-738 chevron `"chevron.right"`). Leave `refreshIcon` (:789-796) and every icon-well/preview site alone (single instances carrying meaningful descriptions).
    - Tests (DeviceIconResolverTests): same key → identical instance (`===`); different pointSize → different instance; result `isTemplate == true`; unknown symbol → nil.

## Out of scope — do not touch

- **Deferred audit items (deliberate — list them in your final report so the reviewer knows they were not missed; do NOT attempt):** P2-10 (editor-pane scroll/clipping at a 10-14 speaker fleet — needs a live mock-fleet check; roadmap 039), window-audit P3-5 (icon-grid arrow-key navigation / NSCollectionView rebuild — too large), P3-7 (undo via NSUndoManager — larger feature; Step 22 is only its prerequisite), P2-11 (membership-control legend — settled design decision, Warm Signal v4 §Call-1).
- `PopoverController` and everything in `AudioutPopoverUI`; `Tokens.swift`; `AudioutSettingsUI`; model code in `AudioutCore/Sources/AudioutCore/` (`GroupController`, `GroupStore`, `Device` are READ-ONLY here — every fix is UI-side); `AirPlayEngine/`; `scripts/`; `DeviceIconController` (T2's region of DeviceIcon.swift); AppDelegate outside `installMainMenu`.
- No renames of `membershipWell` (a test reaches it by reflection); no changes to `GroupsPaneLayout` numbers; no new vertical bands in the editor pane (zero height headroom); no warm-token text colours (frozen to stock greys); no regenerating window-snapshot goldens; no absolute-width assertions in Groups-pane tests.
- No cleanup, no refactors beyond the named extractions, no new abstractions, no error handling for impossible cases, no backwards-compat shims, no localization pass, no extra a11y sweeps beyond the named findings.

## Verification

All through the wrappers (binding rule in the header). Track-scoped filtered runs during the work; the FINAL check after all tracks merge:

```
bash scripts/build.sh
bash scripts/run-tests.sh --filter MixerWindowControllerTests --filter MembershipRailTests --filter SidebarActionsTests --filter GroupRenameFieldTests --filter IconPickerTests --filter DeviceDetailViewTests --filter GroupsWindowTextColorLockTests --filter GroupsHeaderParityTests --filter AppSurfaceControllerTests --filter MembershipBusTests --filter MembershipWellContrastTests --filter SidebarWarmSurfaceTests --filter DeviceIconWellViewTests --filter DeviceIconResolverTests
bash scripts/run-tests.sh          # full suite, once, at the end
```

**Pre-change baseline (observed by the scoping agent, 2026-08-27, this branch):** the filter list above minus `DeviceIconResolverTests` ran GREEN — `Test run with 297 tests in 13 suites passed after 16.331 seconds.` One earlier attempt of the same run crashed with an uncaught `NSException` in ViewBridge/`NSRemoteView` under machine load and passed cleanly on re-run — if you hit that exact crash, re-run before diagnosing; it is environmental.

Done = the filtered run AND the full suite pass in YOUR session with output pasted (redirect to a file if long — never `| tail`). Every new seam/test named in the steps exists and runs. Commits go through the repo's guards (Guard 7 self-review included) — do not bypass with `--no-verify`.

## Execution plan

The branch forks from this audit branch's committed HEAD (tree is clean — nothing uncommitted to depend on). Parallel tracks run in isolated worktrees and merge back; the shared test file (`MembershipRailTests.swift` between Tracks 1 and 3) does NOT force serial — the runner merges. Verification runs once, on the combined result, after all tracks finish.

| Track | Steps | Files | Model | Effort | Concurrency |
|---|---|---|---|---|---|
| 1 | 1-15 | GroupEditorViewController.swift, MixerWindowController.swift, SidebarViewController.swift, GroupCreationSheetController.swift, AudioutWindowUI/AGENTS.md; tests: MixerWindowControllerTests, MembershipRailTests, SidebarActionsTests, GroupRenameFieldTests | opus | high | PARALLEL |
| 2 | 16-18 | DeviceDetailViewController.swift, MainOutDetailViewController.swift; tests: DeviceDetailViewTests | sonnet | medium | PARALLEL |
| 3 | 19-21 | IconPickerViewController.swift, MembershipRowView.swift; tests: IconPickerTests, MembershipRailTests | sonnet | medium | PARALLEL |
| 5 | 22 | AudioutApp/AppDelegate.swift (installMainMenu only) | sonnet | low | PARALLEL |
| 4 | 23 | AudioutSharedUI/DeviceIcon.swift + three adoption sites in files owned by Tracks 1/2/3; tests: DeviceIconResolverTests | sonnet | low | SERIAL — consumes the merged SidebarViewController.swift, MembershipRowView.swift, DeviceDetailViewController.swift |

## Acceptance checklist

- [ ] Active-group delete alert states the true consequence; inactive keeps the old sentence; Cancel is the Return default; Delete is marked destructive; window-less delete is a no-op.
- [ ] An EQ-only backend event re-renders neither the editor pane nor the detail pane's group rows (seam counts prove it); a rename/availability change still does.
- [ ] Typing in the rename field survives a backend event; Escape lands keyboard focus on the sidebar outline.
- [ ] Rail armed tone follows the routed truth per row; MembershipRailTests updated accordingly and green.
- [ ] Creation sheet: failed save reported, dedup announced (window path), duplicate names refused at both commit sites, empty checklist explains itself.
- [ ] Edit menu present with all seven verbs, target nil.
- [ ] Icon search matches plain words; selection ring re-resolves on accent + a11y notifications; membership checkbox label follows toggles.
- [ ] Sidebar: VoiceOver speaks unavailable/playing-now; gone selection deselects; context-menu titles name their target; ⌘N yields to field editors.
- [ ] Symbol images cached in DeviceIcon and adopted at the three row sites.
- [ ] Deferred items (P2-10, window P3-5, P3-7, P2-11) listed in the final report as deliberately not done.
- [ ] Filtered suites + full suite green via the wrappers, output pasted.

## Open decisions (made here; surface to Alec only if he asks)

1. **P0-1 active-delete copy** states the true rule ("switches playback to Selected Devices; speakers that are only in this group will stop") rather than the audit's simpler-but-not-always-true "stops sending audio to its speakers" — verified against `GroupController.swift:629-634`.
2. **P2-1:** per-row armed = routed-now (backend echo `isSelected`; saved membership for the local Mac) — chosen over the whole-rail-drops-armed variant, which would lie whenever a saved member is merely powered off.
3. **P2-5:** refuse duplicates (case-insensitive) with an explanation — chosen over Finder-style auto-suffixing; matches the empty-name refusal's honesty.
4. **P2-4:** refresh the verb label — chosen over dropping the verb (keeps the existing announced vocabulary).
5. **P1-3:** modal choice sheet (Open / Go Back) on the creation sheet's window; headless keeps the current silent resolve so existing flows/tests hold.
6. **P2-12:** `refreshIcon` (:789-796) deliberately NOT cached (a single header image carrying a meaningful description; the hot rebuilds are gated by Steps 2/16 anyway).

## Executor rules (verbatim)

> - Follow the steps in order. Do not add, merge, reorder, or skip steps.
> - If reality contradicts a Verified fact or a step is impossible as written, STOP and report the discrepancy. Do not improvise a workaround.
> - Before reporting progress, audit each claim against a tool result from this session. Only report work you can point to evidence for. If tests fail, say so with the output.
> - "Done" means the Verification commands were run in this session and passed. Paste their output.
> - Touch nothing in the Out-of-scope list.
> - Deliver what was asked, at the scope intended. If the spec seems mistaken or a better approach exists, say so in a sentence and continue as specified rather than quietly narrowing, widening, or transforming it.
