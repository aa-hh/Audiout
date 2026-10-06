Revised after spec check: 20 items. Second revision (orchestrator, 2026-10-05): six re-check fixes folded in, and the branch now starts from main because PR #271 merged.

# Work order: Speakers tab redesign (direction M final, green)

### Goal
Build the Speakers tab as `M/FINAL/BRIEF.md` specifies, with the token and colour placements from `M/FINAL-GREEN/BRIEF.md` §1 and `M/FINAL-GREEN-2/NOTES.md`, in the Audiout Mac app. Branch `claude/speakers-tab-m` (worktree `.claude/worktrees/speakers-tab-m`) is cut from `main` `b52b513b`, which contains PR #271 (`4ef0fbe6`). Commit `f21fe1b9` on it adds the design briefs. The PR targets `main`.

What changes:
- **Sidebar:**
  - Section titles become "System Audio" + Main Audio plate, then "Speakers" + Overview plate.
  - The two visibility groups become "Shown in Mixer" and "Hidden unless in use".
  - The presence dot goes. Reachable speakers come first, then an "N unavailable" divider row, then unreachable speakers in cool greys.
  - Rows keep their identity and move instead of the whole list reloading.
  - Command-Delete forgets the selected speakers that can't be found.
- **Overview page:** five counts with per-kind timing and a shimmer while each count is unknown; problem rows only when true; a new Local Network row and its event.
- **Speaker and Main Audio pages:** cool greys. A green "Ready"/"Connected" status word. Forget waits until the can't-be-found list is filled.
- **Forget sheet:** names up to two speakers and says what happens if one comes back.

Why: the owner's rulings say today's counts don't add up, the dots read as broken, green is the tab's colour, and Forget must never be offered for a speaker that is merely slow to appear.

The briefs are committed on the branch (`f21fe1b9`) under `.scratch/speaker-management-followup/mockups/`; their rendered PNGs sit untracked in the same worktree:
- `.scratch/speaker-management-followup/mockups/M/FINAL/BRIEF.md` (FINAL below)
- `…/M/FINAL-GREEN/BRIEF.md` §1 only (the token and its contrast table)
- `…/M/FINAL-GREEN-2/NOTES.md`, `mockup.png`, `mockup-dark.png`

FINAL is binding for every string, spoken label, size and ink this order does not override. Its line numbers refer to `b9b70310`, so re-anchor by symbol name. Where this order and FINAL disagree, this order wins.

### Verified facts
(Read at `4ef0fbe6`, which `main` `b52b513b` contains; between the two, `main` changed none of the files cited here except 10 lines of `PopoverController.swift`, which this order only references. Re-anchor by symbol if a line has drifted. That commit touched only `SurfaceToolbarSeatButton.swift` and `SurfaceToolbarTests.swift`, so every line below matches `24790260`.)

**Layout and tokens**
- Window width is 713 and the sidebar is 210 (`AudioutCore/Sources/AudioutSharedUI/SurfaceLayout.swift:16`, `:20`). The page column is `contentPaneWidth − insets` (`AudioutWindowUI/GroupsPaneLayout.swift:61`), giving 475 per `FINAL-GREEN-2/NOTES.md:7`. So the card is 475 wide and the strip is 447 (475 − 18 − 10). The four kind tiles are 92.4 each with Unavailable at its 77.4 minimum.
- Row height R is 32 under the source-list style at medium row size, measured offscreen on macOS 27 (my probe: `rowHeight=32`).
- Symbols checked on macOS 27:
  - Present: `antenna.radiowaves.left.and.right.slash`, `questionmark.circle`, `wifi`, `plus.circle`, `airplayaudio`, `radio`, `radio.fill`, `tv.and.hifispeaker.fill`, `laptopcomputer`.
  - Missing: `tv.and.hifispeaker`.
- `Device.Kind` symbols: localMac `laptopcomputer`, bluetooth `radio.fill`, cast `tv.and.hifispeaker.fill` (`AudioutCore/Device.swift:74`, `:90`, `:94`). `isDiscoveredOverLocalNetwork` is true for homePod, appleTV, airportExpress, sonos, generic and cast (`Device.swift:61-68`).
- `Tokens`:
  - `equalizer` is `warmDynamic(name:dark:0x41B07A, light:0x007835)` at `Tokens.swift:494-496`.
  - Call shape: `warmDynamic(name:dark:darkHighContrast:light:lightHighContrast:)` at `:1503-1505`.
  - `labelCool` at `:512-514`, `labelCool2` at `:528-530`.
  - `meter` has Increase Contrast values (`:328-330`). An Increase Contrast flip fires no appearance change (`AccessibilityDisplayRedraw.swift:16-27`).
  - The `label3` doc lists "subsection headers" at `:117`.
  - Fonts: `heading` `:1270-1272`, `caption` `:1287`, `captionMedium` `:1297-1299` (doc `:1295-1296`), `captionEmphasized` `:1303-1305`.
- `TokenContrastMatrixTests.everyInstrumentClearsItsFloorAcrossAppearanceAndIncreaseContrast` holds its entries list at `:179-243`. Its `ContrastEntry.groundsFor` takes the appearance (`:117-125`), so each appearance can have its own ground.

**Sidebar (`AudioutWindowUI/SidebarViewController.swift`)**
- `Node.payload` is a `let` with cases header, speakersOverview, mainOut and device (`:51-65`). Switches over it sit at `:560`, `:1043`, `:1137` and `:1163`.
- Constants: titles at `:93-98`, the caption constant `playingWhileHiddenCaption` at `:98`.
- Every `reload` rebuilds all nodes, calls `reloadData`, and restores only the first selection (`:512-548`).
- The Speakers plate is a root leaf (`:528-532`).
- Menu: strings at `:368-419`. Forget is gated on `isLost` = `liveDevice == nil` (`:458-460`, `:389`, `:413`).
- Dot code: `dotState` at `:467-471`. `SidebarPresenceDotView` at `:948-996`, also used by the Overview (`SpeakersPageViewController.swift:321-327`, `:441`).
- Cells:
  - `activeMarkerView` at `:816-828`.
  - Header cell centred, ink `label2` (`:1235-1258`).
  - Heights at `:1135-1145`. `PlateRowView.rowHeight = 36` at `:917`.
  - `rowViewForItem` gives the plate row view only to the Overview plate (`:1150-1159`).
  - `makeIconLabel` inks `label3` when dimmed (`:1291`, `:1293`).
  - Spoken suffixes at `:1305-1311`: ", can’t be found", ", unavailable" and ", in the Mixer while it plays".
  - `newCell` adds the dot slot at `:1343-1354`.
- `shouldSelectItem` is `!isGroupItem` (`:1127-1130`).
- Add-scene bar: height 28, leading 8 (`:249-251`).
- The command-N container view is at `:1008-1029`.
- The context-menu delegate is `self` (`:200-202`).
- `GroupsInkTemperatureTests`:
  - The suite doc `:18-21` and `// MARK: 10` at `:269` describe the sidebar's stock ink.
  - `sidebarCellsKeepStockInk` (`:271-293`) pins `label2` headers and `label3` unavailable rows, and builds bare `Node(...)` values at `:274-290`.
- `PlateRowView()` is built bare in `IncreaseContrastLiveReconcileTests.swift:176`.

**Outline-view behaviour (probe in scratchpad JXA)**
- Inside `beginUpdates`/`endUpdates`, `moveItem(at:inParent:to:inParent:)` and `insertItems` apply one at a time, each against the state the previous call left, as long as the model is changed before each call.
- A multiple selection follows moved rows across parents. Probe output: `selected: a1,a3` → `after: A,a3,a2,c1,B,b1,a1`, `selected after: a3,a1`.

**Overview page (`AudioutWindowUI/SpeakersPageViewController.swift`)**
- `SpeakerLibraryCounts` (`:9-36`) carries the analytics properties.
- `SpeakerSearch` (`:43-92`):
  - `quietWindow` 0.5 at `:48`, `ceiling` 10 at `:51`.
  - `libraryDidChange` returns early once `isDone` (`:75-84`).
  - `finish` captures `speaker:library_counted` (`:86-91`).
- The page rebuilds every row on each `reload` (`:228-274`).
- Header: caption, spinner, green check (`:277-309`). Title "Speakers" (`:119`).
- Kinds strip: `.fillEqually` plus Unknown (`:331-381`).
- Row order today is kinds, Bluetooth, lost, Pair (`:238-267`).
- Pair chevron is `label2` (`:416`).
- Test hooks: `test_subtitleText` (`:437-444`, which reads `SidebarPresenceDotView` at `:441`), `test_kinds` (`:447`), `test_discoveryShowsSpinner` (`:468`).
- `DiscoverySettleTracker(quietWindow:schedule:)` with `start()` and `note(deviceIDs:)` (`AudioutSharedUI/DiscoverySettleTracker.swift:35-57`).
- Tests:
  - A `Timers` helper indexed by arming order (`SpeakersPageTests.swift:31-34`, `:142-144`, `:164`).
  - The `device` helper defaults to `.generic` (`:26-27`), and `forgetReportsExactlyTheLostIDsAndTheRowsFire` builds attic and garage with it (`:97`).
  - `searchFinishesAtTheCeilingWhenTheListNeverGoesQuiet` is at `:155-166`.

**Speaker page (`AudioutWindowUI/DeviceDetailViewController.swift`)**
- `isLost` = remembered (`:607-609`). It hides the editor (`:727`), shows Forget (`:732`) and picks the list pin (`:756-769`).
- Four list pins and two Forget pins (`:378-389`).
- Caption logic at `:655-668`; the glyph is the red failure triangle (`:223-224`).
- Captions "Listed …" at `:709-715`.
- Warm inks at `:219`, `:271`, `:278`, `:281`, `:307`, `:931`, `:950`.
- The green equalizer mark is `EqualizerMarkView` (`:1374-1386`) and is kept.
- `refreshEQTitleRow` (`:683-693`) runs after `applyPerDeviceSectionVisibility` in `refreshUI` (`:629`, `:650`).
- `SpeakerPresentationStatus` `.available`/`.connected` read "Ready"/"Connected" (`AudioutCore/SpeakerLibraryController.swift:15-25`).
- A record is reachable when `isLocalDevice` (`:109`) or `isAvailable` (`:113-115`).
- A record with no saved details (`metadataIsKnown == false`) exists only as a scene member: records are live ids ∪ metadata ids ∪ group members (`:302`), and `metadataIsKnown` = `device != nil || metadata != nil` (`:316`).

**Main Audio, list row, equalizer editor**
- Main Audio warm inks at `MainOutDetailViewController.swift:103`, `:128`.
- `ListRowView` caption default `label2` (`:65`); glyph default tint `label2` (`:45`).
- The equalizer editor's warm inks are at `AudioutSharedUI/EQEditorView.swift:216, 240, 307, 334, 376, 381, 384, 475, 506`. It is constructed only by the two pages (`DeviceDetailViewController.swift:187`, `MainOutDetailViewController.swift:73`).
- `EQResponseCurveTests:209` pins `label2` for the curve view's ruler, which is a different file.

**Integration (`AudioutWindowUI/MixerWindowController.swift`)**
- `setSpeakerSearchDone` at `:434-437`.
- Forget wiring: all three doors call `requestForget` (`:226-228`). `requestForget` at `:561-573`; `makeForgetAlert` at `:597-634`.
- `SidebarProjection` has `isInUse` and `isFound` (`:849-876`). There is no `isPlaying`, so FINAL §1.4.8 is stale. `isInUse` drives the caption through `isVisibleInMixer` (`SpeakerLibraryController.swift:132-139`).
- `refreshSidebar` and `reloadSidebarIfNeeded` at `:820-841`; `showDetail` at `:508-516`; `refreshSpeakers` at `:793-813`.
- These controllers are constructed only here (`:135-141`).

**App wiring (`AudioutApp/AppDelegate.swift`)**
- `speakerSearch` is a lazy var (`:380`).
- `onDone` calls `setSpeakerSearchDone` (`:1103`); the controller is seeded at `:2422`.
- The Local Network read is `permissionAuditModel?.localNetworkStatus == .denied` (`:1392-1393`).
- The audit Task is at `:2049-2060`. The audit re-probes Local Network (`AudioutCore/SetupModel.swift:1284-1294`).
- `SystemSettingsPane.localNetwork.url` (`SetupModel.swift:124-150`).
- The Bluetooth read is a static `CBManager.authorization` lookup (`AudioutCore/BluetoothPermission.swift:17-19`).
- Announcement pattern: `PopoverController.swift:2761-2769`. Heading role: `NSAccessibility.Role(rawValue: "AXHeading")` (`PopoverPanelViewController.swift:1379-1381`).

**Tests, tools and guards**
- Beeps from unhandled keys are silenced in tests through `noResponderFor:` (`AudioutCore/Sources/TestKeySilencer/TestKeySilencer.m`). `NSSound.beep()` is used nowhere in `Sources`.
- `window-harness/main.swift:97-99` expects the old titles.
- `AudioutWindowUI/AGENTS.md` is 298 words; Guard 12 refuses growth past 300 (`.githooks/guard-agents-docs.sh:37-41`).
- `DESIGN.md` sections:
  - frontmatter colours `:4-30` (equalizer `:27`)
  - Equalizer-Hue Fence `:302-345` (last paragraph `:339-345`; the Instrument Ground Rule starts at `:347`)
  - Typography hierarchy `:403-417`
  - the Speakers page paragraph `:498-515`; Speakers Sidebar and Pages `:690-730`
  - "deploys to 14.2" at `:642` and `:782`; `Package.swift:79` is `14.4`
- No planned file matches `is_risk_path` (`scripts/review-branch.sh:62-86`).
- audiout-shared `docs/analytics-events.md`: table at `:39-40`, no Mac `speaker:` rows. The only `speaker:` row is the phone's `speaker:password_prompt_shown` (origin/main `:124`). Its main checkout has someone else's uncommitted edits to this file around `:45` and `:60`.
- The words "speakers found" also appear outside this work: `AudioutOnboardingUI/SetupCardView.swift:89`, `:116` and `AudioutPopoverUI/PopoverController.swift:2155`.

### Steps

**Track T0: tokens (runs first)**

1. `AudioutCore/Tests/AudioutCoreTests/TokenContrastMatrixTests.swift`, entries list `:179-243`:
   - Add `speakersAccent`, floor 4.5, on panel, raised and well.
   - Add `labelCool on sidebar`, floor 4.5, and `labelCool2 on sidebar`, floor 3.0. Their `groundsFor` returns one ground per appearance:
     - `("sidebar", NSColor(srgbRed:green:blue:alpha:))` of `#E8E8EA` for `.aqua`
     - `#2C2C2E` for `.darkAqua`
   - Add one comment line saying these two grounds are the assumed darkest light and lightest dark sidebar grounds for macOS 14.4–26, which are unmeasured; macOS 27 measured `#F0F0F0` / `#282828`.
   - Run step 4's command. It must fail to compile because `speakersAccent` does not exist. The two sidebar rows pin values that already hold and will pass; that is expected.
2. `Tokens.swift`, directly after `equalizer` (`:494-496`): add `public static var speakersAccent: NSColor` returning `warmDynamic(name: "speakersAccent", dark: 0x41B07A, darkHighContrast: 0x63D199, light: 0x007835, lightHighContrast: 0x03642B)`.
   - Its doc comment says: the Speakers tab's colour; it means the Mac can reach a speaker; it also marks the tab's one add action; never selection, never a fill behind text in dark, never the Mixer or the sidebar.
   - Include the contrast rationale from `FINAL-GREEN/BRIEF.md` §1's table:
     - light: 5.39 panel/raised, 4.67 well; with Increase Contrast 7.04 / 6.10
     - dark: 6.60 / 5.79 / 7.48; with Increase Contrast 9.50 / 8.34 / 10.77
     - white on the dark value measures 2.72:1, so it is never a fill
3. `Tokens.Font`:
   - Add `headingDigits` = `.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize + 3, weight: .semibold)` directly after `heading`.
   - Add `captionDigits` = `.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)` directly after `caption`. Each gets a one-line doc naming its consumer (the Overview counts; the sidebar's "N unavailable" divider and the Overview total).
   - Remove "subsection headers, " from `label3`'s doc (`:117`).
   - Append "and the Speakers sidebar's subsection headers" to `captionMedium`'s doc (`:1295-1296`).
   - Also in this step, in `AudioutWindowUI/ListRowView.swift:65`, change the caption default `label2` to `labelCool`. This also turns the speaker page's Show in Mixer and Password captions cool (`DeviceDetailViewController.swift:105-111`), which track C wants; it is not a surface leak.
4. Run T0 verification.

**Track S: audiout-shared event row (separate repo, own branch and PR)**

5. In `/Users/alechenderson/Projects/audiout-shared`:
   - Never touch the main checkout, which has someone else's edits. Run `git fetch origin && git worktree add worktrees/speakers-privacy-event -b claude/speakers-privacy-event origin/main`.
   - In `docs/analytics-events.md`, insert exactly one row immediately before the `surface:shown` row:
     `` | `speaker:privacy_settings_opened` | mac | `access` | `local_network` | The Speakers overview's "Local Network access is off" row's Open Privacy Settings… button opens macOS's Privacy & Security ▸ Local Network pane. | ``
   - Commit, push, and run `gh pr create --fill`. Do not merge.

**Track A: sidebar** (`SidebarViewController.swift`, plus edits to existing tests)

6. **Tests first.** Add hooks, parameters and cases with no behaviour yet so the tests compile:
   - `Node.Payload` gains `.divider(Int)` now. Cover every switch with a default: `selection(for:)` (`:560`) returns nil; `menuNeedsUpdate` (`:1043`) breaks; `heightOfRowByItem` (`:1137`) returns `outlineView.rowHeight`; `viewFor` (`:1163`) returns nil.
   - `reload` gains `cantBeFoundIDs: Set<String> = []` and `splitsUnreachable: Bool = true` (unused for now).
   - `IconLabelCellView.nameLabel`: a stored label that is still also assigned to `textField`.
   - `test_groupRows(inGroupTitled:) -> [String]`: the group's children in order, as device ids, with a divider as its label text.
   - `test_standardRowHeight` returns `outlineView.rowHeight`.
   - `test_pressCommandDelete()`: builds `NSEvent.keyEvent(… modifierFlags: .command, characters: "\u{8}", charactersIgnoringModifiers: "\u{8}", keyCode: 51)` and calls `outlineView.keyDown(with:)`.
   - `test_dividerIsSelectable(inGroupTitled:) -> Bool?`: nil when there is no divider.
   - `test_filteredSelection(ofRowKeys:) -> [String]`: keys are the `test_groupRows` keys plus "Overview" and "Main Audio". It maps them to rows, calls `outlineView.delegate?.outlineView?(_:selectionIndexesForProposedSelection:)` (falling back to the proposal when that returns nil), and maps back.

   Then edit `SidebarActionsTests.swift`, each test with its "turns red" sentence:
   - Rewrite `speakersRowIsAPlateThatReopens`: `nameLabel` reads "Overview", spoken "Speakers overview", chevron shown. Drop the `activeMarkerView` line.
   - Rewrite `onlyAHiddenSpeakerInUseCarriesTheCaption`: caption "Shown while in use", height `test_standardRowHeight + 12`.
   - Rewrite `speakersSplitIntoTheTwoGroupsAlphabeticallyWithThisMacFirst` as FINAL test 9:
     - titles `["System Audio","Speakers","Shown in Mixer","Hidden unless in use"]`
     - with `splitsUnreachable: false`, Shown is `["mac","alpha","kitchen","study","zeta"]`
     - with `true`, Shown is `["mac","alpha","zeta","2 unavailable","kitchen","study"]` and Hidden is `["den","onkyo"]`
   - Rewrite `theDotShowsPresenceForEachRecordShape` as a spoken-label test:
     - with an empty can't-be-found list: "Study, unavailable", "Kitchen, unavailable", "Onkyo, shown in the Mixer while in use", "Alpha"
     - with `["study"]`: "Study, can’t be found"
   - Extend `forgetIsOfferedOnlyForLostSpeakersAndReportsOnlyThem` with FINAL test 7: with an empty list, study's menu has no Forget item and no separator for it. Then pass `["study"]` and keep the existing asserts with "Show even when unavailable".
   - Update the titles and menu strings in the other tests to "Shown in Mixer", "Hidden unless in use" and "Show even when unavailable".
   - Add FINAL test 1: select alpha and zeta, make zeta unreachable, reload. Both ids are still selected and zeta sits under the divider.
   - Add FINAL test 8: alpha and study selected with `["study"]` → `onForget == [["study"]]`; only alpha selected → not called.
   - Add FINAL test 10: the divider is not selectable; a proposal of `[alpha, "2 unavailable", kitchen]` drops the divider; a proposal of `["Overview", "alpha"]` drops "Overview".

   In `GroupsInkTemperatureTests`:
   - Rewrite the suite doc `:18-21` to say the sidebar's secondary inks are cool, and that selected rows re-ink to the selection pill's text colour.
   - Rewrite `// MARK: 10` (`:269`) to "// MARK: 10. The sidebar's secondary inks are cool".
   - Rewrite `sidebarCellsKeepStockInk` as FINAL test 2, sidebar half:
     - Build cells for a section title, a subsection header, a divider, both plates, a reachable row and an unreachable row from bare `Node(...)` values. Build the captioned row through `reload(devices:presentationRecords:)` with a hidden, in-use record, and read it with `test_deviceCell(id:)`; a bare node has no record, so it can never carry a caption.
     - Assert section and subsection inks are `labelCool`, the unreachable name `labelCool`, the unreachable icon `labelCool2`, and the reachable name `label`.
     - Assert no text field or image view in any of these cells resolves to `label2`, `label3`, `ember`, `gold` or `failure`.

   In `MixerWindowControllerTests.swift`:
   - Update the titles at `:46`, `:262`, `:286` and `:326`.
   - Rewrite `sidebarRepaintsAConnectedSpeakerWhoseDiscoveryLapsed` (`:553-575`) to read the row's spoken label ("Cast, unavailable" / "Cast" / "Cast, unavailable") instead of the dot.
   - Rewrite `sidebarIsAlphabeticalWithinItsGroupWithTheMacFirst` (`:1304-1320`) to expect `["local-mac","homepod-bed","airport-mixer","sonos-move-2","sonos-move","appletv-lr","office"]`.

   Run A's filter and paste the failures.
7. **Tree model.**
   - `Node.payload` becomes `var` (`.divider(Int)` was added in step 6).
   - Constants: `systemAudioTitle` stays; add `speakersTitle = "Speakers"`; `inMixerTitle = "Shown in Mixer"`; `hiddenTitle = "Hidden unless in use"`; rename `playingWhileHiddenCaption` to `inUseWhileHiddenCaption = "Shown while in use"`.
   - A header is a section title when its text is `systemAudioTitle` or `speakersTitle`; otherwise it is a subsection header.
   - The controller keeps persistent nodes: four headers, the two plate nodes, one divider node per group, and `[String: Node]` for devices.
   - Roots are `[System Audio header [mainOut], Speakers header [speakersOverview], Shown header [rows], Hidden header? [rows]]`.
   - `findNode(titled:)` keeps matching `.header`. `selection(for:)` returns nil for `.divider`.
   - `test_sectionTitles` returns the root header titles only.
8. **Building rows in `reload`.**
   - Store the records, `cantBeFoundIDs` and `splitsUnreachable` on the controller.
   - Sort into groups as today (`:516-523`).
   - A row is reachable when `record.isLocalDevice || record.isAvailable`. Without a record, use `device.isLocalDevice || device.isAvailable`.
   - With `splitsUnreachable`: reachable rows first, then the group's divider (count = unreachable rows) only when that count is above 0, then the unreachable rows, each part in the existing name order. Without it: one name-ordered list and no divider.
   - **First reload** (roots empty): set the model, `reloadData`, expand as today.
   - **Every later reload:**
     - Capture the selected nodes by identity.
     - Inside one `beginUpdates`/`endUpdates`, changing the model before each call:
       - (a) remove nodes absent from both targets, highest index first (`removeItems`);
       - (b) insert the Hidden header root if it is needed;
       - (c) for each group, for each target index i, leave the node if it is already there, `moveItem` it if it sits elsewhere in either group, otherwise `insertItems`;
       - (d) remove the Hidden header if it is no longer needed.
     - Insert and remove use `.effectFade`.
     - Use no animation (`[]` and `NSAnimationContext` duration 0) when `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` is on or `view.window?.isVisible != true`.
     - Update node payloads in place. Re-run cell configuration on visible cells through `view(atColumn:row:makeIfNecessary: false)`. Call `noteHeightOfRows(withIndexesChanged:)` for rows whose caption appeared or went. Never `reloadItem` or `reloadData`.
     - Afterwards, reselect the surviving captured nodes with the selection callback suppressed (`deselectAll` if none survive), then `updateAddButtonTitle()`.
     - Expand a re-added Hidden header unless `hiddenGroupCollapsed`.
9. **Holding moves.**
   - Hold while any of these is true:
     - the pointer is inside the scroll view: a tracking area with `.mouseEnteredAndExited, .activeAlways, .inVisibleRect` and the controller as owner;
     - the context menu is open: `menuWillOpen`/`menuDidClose`;
     - a drag is running: data-source `outlineView(_:draggingSession:willBeginAt:forItems:)` / `…endedAt:operation:`.
   - While held, a reload does these at once: payload and visible-cell updates, removals of ids no longer passed in, and divider-label updates to the count actually drawn under it (removing a divider left with no rows). It stores the latest arguments and applies the full structure when the hold ends.
   - Set a flag around the sidebar's own `onSetVisibility` and `onForget` calls (menu actions, `acceptDrop`, Command-Delete). A reload that arrives while the flag is set applies at once even while held.
10. **Header cells and heights.**
    - A new cell class owns its label as a stored property and does not assign it to the `textField` outlet.
    - Two reuse pools: section titles in `captionEmphasized`; subsection headers in `captionMedium`. Both inked `labelCool`.
    - Label leading on the cell, bottom = cell bottom − 3.
    - Heading role via `NSAccessibility.Role(rawValue: "AXHeading")`. Spoken labels from FINAL §1.8, set on every reuse. `redrawOnAccessibilityDisplayChange()` on the label.
    - `heightOfRowByItem`:
      - section and subsection headers 19, except the "Speakers" title 31
      - both plates `outlineView.rowHeight + 8` (delete `PlateRowView.rowHeight`)
      - divider 24
      - captioned row `rowHeight + 12`
      - other rows `rowHeight`
11. **Speaker and plate cells.**
    - Remove the dot slot and `dotView` from `IconLabelCellView` and `newCell`; the icon pins to the cell's leading edge.
    - Remove `activeMarkerView` and `setActiveMarkerVisible`, and remove `dotState(for:)` and `test_dotState`. Leave the `SidebarPresenceDotView` class itself; track D deletes it.
    - `nameLabel` is the label for every cell. Only speaker rows assign it to `textField`. Speaker names use `.byTruncatingMiddle`; set `outlineView.allowsExpansionToolTips = true`.
    - Resting inks per FINAL §1.5: name `label` or `labelCool`; icon `label` or `labelCool2`; caption `labelCool`, with its own accessibility element turned off; chevron `labelCool2`.
    - `IconLabelCellView` stores the resting inks and gets `applySelectionInks(selected:emphasized:)`:
      - selected and emphasized: `NSColor.alternateSelectedControlTextColor` on every ink
      - selected, not emphasized: `Tokens.Color.label`
      - otherwise: the resting inks
    - New `SidebarRowView: NSTableRowView` whose `isSelected`/`isEmphasized` `didSet` calls that method on `view(atColumn: 0)`. `PlateRowView` becomes its subclass.
    - `rowViewForItem` returns a plate row view for both plates, a `SidebarRowView` for device rows, and nil otherwise.
    - Implement `outlineView(_:didAdd:forRow:)` to re-ink. Re-ink after every in-place cell update.
    - `redrawOnAccessibilityDisplayChange()` on name, icon, caption and chevron.
    - Unreachable rows get a tooltip of name, newline, "Unavailable", "Not connected" or "Can’t be found", then the id as a third line when the record has no saved details. Reachable rows have no tooltip.
    - Spoken label = name plus a suffix from FINAL §1.8:
      - ", can’t be found" when the id is in `cantBeFoundIDs`
      - otherwise ", not connected" for an unreachable Bluetooth speaker
      - otherwise ", unavailable" for any other unreachable speaker
      - the `:1311` suffix ", in the Mixer while it plays" is replaced by ", shown in the Mixer while in use" for a hidden speaker in use
    - Plates: label `bodyEmphasized`/`label`, chevron 10 pt semibold `labelCool2`. Overview: text "Overview", spoken "Speakers overview". Main Audio moves onto the plate path.
    - `PlateRowView` dark fill is `Tokens.Color.label.withAlphaComponent(PlateRowView.darkLiftAlpha)` with `darkLiftAlpha = 0.05`, chosen when `effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua`. Light stays `raised`. Add `viewDidChangeEffectiveAppearance` → `needsDisplay`.
12. **Divider cell** (its own pool), per FINAL §1.3:
    - Glyph: `DeviceIcon.image("antenna.radiowaves.left.and.right.slash", pointSize: 11)` in `labelCool`, in a 22 pt box at the cell's leading edge.
    - Label: "N unavailable" in `Tokens.Font.captionDigits`/`labelCool`, leading 8 after the box, bottom = cell bottom − 3.
    - Rule: an `NSBox` of type `.separator` from label trailing + 8 to cell trailing − 2, centred 3 pt above the label's first baseline.
    - One accessibility element, "N unavailable speakers" or "1 unavailable speaker". Glyph and rule are not elements.
13. **Menu and Command-Delete.**
    - Menu per FINAL §1.9: "Show even when unavailable"; Forget only for ids in `cantBeFoundIDs`, replacing `isLost`. Forget items get `keyEquivalent = "\u{8}"` and `keyEquivalentModifierMask = .command`.
    - New `SidebarOutlineView: NSOutlineView` (the `outlineView` property's type) overrides `keyDown(with:)`. When `keyCode == 51` and the device-independent flags are exactly `.command`, it calls `onCommandDelete` (`() -> Bool`). If that returns false, or for any other key, it calls `super.keyDown`. No `NSSound.beep()`.
    - The handler takes the selected device ids that are in `cantBeFoundIDs`. If there are none it returns false; otherwise it calls `onForget` inside the own-gesture flag and returns true.
14. **Keyboard, drop and announcement.**
    - `shouldSelectItem`: false for group items and dividers.
    - `selectionIndexesForProposedSelection` removes divider rows, and removes plate rows from any proposal of more than one row.
    - `typeSelectStringFor`: display name, "Main Audio" or "Overview"; nil otherwise.
    - `shouldCollapseItem` returns `isHiddenHeader(item)`.
    - `validateDrop`/`acceptDrop` retarget a divider to `outlineView.parent(forItem:)`'s header.
    - After a reload, if exactly one device row was selected, its reachability changed, `view.window?.isKeyWindow == true` and the outline is first responder: post a low-priority `.announcementRequested` on the outline ("<name>, unavailable"/"available"; Bluetooth "not connected"/"connected").
15. **Add-scene bar.**
    - Height `outlineView.rowHeight`, button leading 16.
    - Image is a 26×22 template `NSImage` whose drawing handler draws `DeviceIcon.image("plus", pointSize: 13, weight: .medium)` centred at x 11 and vertically centred. No hairline.
16. Run A verification.

**Track B: Overview and search** (`SpeakersPageViewController.swift`, `SpeakersPageTests.swift`)

17. **Tests first.** Declare these with final names and types but stub behaviour:
    - `SpeakerSearch.Kind: CaseIterable { airplay, bluetooth, cast, thisMac }`
    - `knownKinds: Set<Kind>` (stub: empty), `isEveryKindKnown`, `cantBeFoundIDs` (stub: empty)
    - `isBluetoothAccessGranted: () -> Bool = { true }`, `isLocalNetworkDenied: () -> Bool = { false }`
    - `onChange`, `pageDidAppear()`, `networkQuietWindow = 2.0`
    - page `search: SpeakerSearch?`, `onLocalNetworkAccess`
    - hooks `test_headerCaption`, `test_tileValues`, `test_placeholderCount`, `test_forgetButton`, and `test_reduceMotionOverride: Bool?`

    In `SpeakersPageTests`, add a `Clock` helper: `schedule` records `(now + delay, order, fire)`; `advance(to:)` repeatedly takes the earliest due closure at or before the target (ties by order), sets `now` to that closure's due time, then fires it. It includes closures armed by those fires, and finally sets `now` to the target.

    Rewrite both existing search tests onto the Clock:
    - `searchCapturesTheCountsOnceWhenTheListGoesQuiet`:
      - Keep the "an empty list arms nothing" assert (the Clock has nothing pending after the empty-list call).
      - Keep `captured.events().isEmpty` right after the non-empty update.
      - Replace `try #require(timers.pending.count == 2)` and the two indexed fires (`:142-144`) with `clock.advance(to: 0.5)`. The count assert does not carry over.
      - Keep the trailing `search.libraryDidChange()`, `done == 1 && search.isDone`, the one-event count and the nine-property dictionary.
    - `searchFinishesAtTheCeilingWhenTheListNeverGoesQuiet` (`:155-166`): change the list at t = 0, then every 0.4 s up to 9.6, adding one device each time so the list never stays quiet for 0.5 s. Expect `!search.isDone` at 9.9 and `search.isDone` at 10.0.

    Add:
    - FINAL test 4: This Mac and Bluetooth only; Bluetooth known at 0.5, AirPlay unknown at 1.9 and known at 2.0.
    - FINAL test 5: extend `searchCapturesTheCountsOnceWhenTheListGoesQuiet`; one event at 0.5 with today's nine properties, while `.airplay ∉ knownKinds`.
    - FINAL test 6:
      - (a) Mac and a live HomePod, plus a remembered `attic` HomePod: list empty at 9.9, `["attic"]` at 10.0.
      - (b) no AirPlay or Cast ever live: a remembered HomePod and a no-kind scene member stay out at 10.0 and 30.0, while a remembered Bluetooth speaker is in.
    - FINAL test 11: a filled list; host the page view in a never-ordered-front `NSWindow`; make `test_forgetButton` first responder; add a live speaker and call `reload()`; the same button instance stays first responder.

    Rewrite:
    - `captionIsTheSearchResultAndLostWaitsForIt` → header placeholder and "still looking" values before all kinds are known; total after.
    - `kindsRowCountsEveryKeptSpeakerAndOmitsEmptyKinds` → `test_tileValues == ["2 AirPlay speakers available","1 Bluetooth speaker available","No Cast speakers available","This Mac, available","2 speakers unavailable"]`, header "6 speakers".
    - `forgetReportsExactlyTheLostIDsAndTheRowsFire`:
      - Build attic and garage as `.bluetooth` and leave `isBluetoothAccessGranted` at its `{ true }` default.
      - Set `isLocalNetworkDenied = { true }`; keep `page.setBluetoothAccess(SpeakerBluetoothAccessPresentation(status: .unknown, priming: false))` as the source of the Bluetooth row.
      - Fill the list.
      - Expect the order `[can't be found, Local Network, Bluetooth, Pair]` and `forgotten == [["attic","garage"]]`, and that the Local Network row's button fires `onLocalNetworkAccess`.
      - Update the help-text assert at `:113` to "They haven’t appeared since Audiout opened. They aren’t in any scene." and delete the `test_rowTitles.first == "Bluetooth access is off"` assert at `:112`.
    - In both rewritten tests, drop the `page.isSearchDone = true` lines (`:50`, `:101`); track D deletes the property and cannot edit this file.

    Append to the end of `GroupsInkTemperatureTests` FINAL test 2's Overview half:
    - Build a page with every row shown, using the same fixture rule as `forgetReportsExactlyTheLostIDsAndTheRowsFire`: remembered speakers are `.bluetooth`, `isBluetoothAccessGranted` stays `{ true }`, `isLocalNetworkDenied = { true }`, Bluetooth row from `setBluetoothAccess(.unknown)`, and the search is filled by a schedule that stores closures and fires them all.
    - Walk the page's view tree; no `NSTextField.textColor` or `NSImageView.contentTintColor` resolves to `label2`, `label3`, `ember`, `gold` or `failure`.

    In `MixerWindowControllerTests.aHiddenSpeakersPageStoresItsStateAndCatchesUpWhenShown` (`:235-258`), delete the `setSpeakerSearchDone(true)` line and expect `["Bluetooth access is off","Pair Bluetooth speaker…"]`.

    Run and paste the failures. Test 5 pins kept behaviour and passes before the change; that is expected.
18. **`SpeakerSearch`.**
    - Keep `tracker`, `ceilingArmed`, `finish()`, `isDone` and `onDone` exactly as they are for analytics. The `!isDone` guard applies only to that part.
    - On the first `libraryDidChange` with a non-empty live-id set, or the first `pageDidAppear()`, whichever comes first, start:
      - create and `start()` three `DiscoverySettleTracker`s: Bluetooth 0.5, AirPlay and Cast `networkQuietWindow`, sharing `schedule`;
      - arm `schedule(Self.ceiling)`, which marks every kind known, lifts the can't-be-found hold and fires `onChange`.
    - Every `libraryDidChange` after the start, including the call that starts it:
      - feed each tracker the ids of its kind's records that have a live device (AirPlay = homePod, appleTV, airportExpress, sonos, generic);
      - mark `.thisMac` known when a local record has a live device;
      - set a sticky flag once any AirPlay or Cast record has had a live device;
      - fire `onChange` when `knownKinds` grows.
    - Tracker settle → insert the kind and fire `onChange`.
    - `cantBeFoundIDs`:
      - empty until the hold lifts;
      - then records with `!isLocalDevice && liveDevice == nil`;
      - minus Bluetooth records unless `isBluetoothAccessGranted()`;
      - minus records whose kind is nil or `isDiscoveredOverLocalNetwork` when `isLocalNetworkDenied()` or the sticky flag is false.
19. Add `struct SpeakerOverviewCounts` beside `SpeakerLibraryCounts`:
    - `airplay`, `bluetooth`, `cast`, `mac`, `unavailable`, `total`, counted per FINAL §2.4.
    - `SpeakerLibraryCounts` is unchanged except its doc no longer says the page draws it.
20. **Header** per FINAL §2.1:
    - Title "Overview".
    - Delete the spinner, `subtitleStack`, `presenceDot`, the system-green check, every old caption string, and the hooks `test_subtitleText` (`:437-444`), `test_kinds` (`:447`) and `test_discoveryShowsSpinner` (`:468`). After this step the page holds no reference to `SidebarPresenceDotView`.
    - One caption field in `captionDigits`/`labelCool`: "No speakers", "1 speaker" or "N speakers".
    - While not every kind is known:
      - a 14×8 placeholder, radius 2.5, alone on the line;
      - under Reduce Motion, "Looking for speakers…" in `caption`/`labelCool` instead;
      - spoken value "Looking for speakers".
    - The page uses `search?.isEveryKindKnown ?? true` and `search?.knownKinds ?? Set(Kind.allCases)`.
    - `viewDidAppear` calls `search?.pageDidAppear()`.
21. **Card rows**, built once in `loadView`, toggled by `isHidden` and retitled in place:
    - Order: counts strip, can't be found, Local Network, Bluetooth, Pair. After each `reload`, `listWell.rows` = the visible rows.
    - Glyph tints: `labelCool2`, except Pair `plus.circle` in `speakersAccent`. Pair chevron `labelCool2`.
    - Can't be found:
      - glyph `questionmark.circle`; button "Forget N speakers…" fires `onForget?(search?.cantBeFoundIDs ?? [])`;
      - help, with k = list size and u = Unavailable count: when k == u, "It hasn’t appeared since Audiout opened." (k = 1) or "They haven’t appeared since Audiout opened."; otherwise "k of the u unavailable speakers haven’t appeared since Audiout opened." ("hasn’t" when k = 1);
      - then a space and today's scene sentence (`:252-257`).
    - Local Network: shown when `search?.isLocalNetworkDenied() == true`; glyph `wifi`; title "Local Network access is off"; button "Open Privacy Settings…" → `onLocalNetworkAccess`; help "Allow Local Network access in System Settings to see AirPlay and Cast speakers."
    - `test_rowTitles` lists visible rows only.
22. **Counts strip** per FINAL §2.3 at the 713 width:
    - Glyphs `"airplayaudio"`, `Device.Kind.bluetooth.symbolName`, `Device.Kind.cast.symbolName`, `Device.Kind.localMac.symbolName`, and the slashed-antenna symbol.
    - Both rules are `NSBox` `.custom`, `borderWidth` 0, `fillColor = containerEdge`, with `redrawOnAccessibilityDisplayChange()` and accessibility turned off.
    - "Available" in `captionEmphasized`/`speakersAccent`.
    - Counts in `headingDigits`: kind tiles `speakersAccent` above 0, `labelCool2` at 0; Unavailable `label`, `labelCool2` at 0.
    - Labels `caption`/`labelCool`. Each tile's label first baseline = count first baseline + 15.
    - Unavailable tile width between 77.4 and 126 with high hugging; kind tiles at least 62.
    - Accessibility: strip group "Speaker counts"; tile values and help per FINAL §2.10; an unknown This Mac reads "This Mac, still looking".
23. **Placeholders and motion** per FINAL §2.9:
    - Private `CountPlaceholderView`:
      - draws its rounded rect in `meter` in `draw(_:)`, with `redrawOnAccessibilityDisplayChange()`;
      - holds a 44 pt `CAGradientLayer` (anchor `(0, 0.5)`, colours clear / `meter.blended(withFraction: 0.70 light, 0.30 dark, of: .white)` / clear);
      - re-stamps the gradient colours both in `viewDidChangeEffectiveAppearance` and on `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification` (observed through `NSWorkspace.shared.notificationCenter`), because `meter` has Increase Contrast values.
    - Animation: keyframe `position.x` values `[−44 − x, W − x, W − x]` (x = the placeholder's minX in the page root, W = page width, 503 at 713); key times `[0, 0.6875, 1]`; duration 1.6; repeat forever; timing functions `(0.45, 0, 0.55, 1)` then linear; `beginTime` one shared `CACurrentMediaTime()` base.
    - Add in `viewDidAppear`; remove in `viewDidDisappear`.
    - Count placeholder 20×12, radius 3, over an invisible "00".
    - Arrival: 0.18 s `NSAnimationContext`, timing `(0.16, 1, 0.3, 1)`, placeholder fades to 0 and the count to 1; then remove the animation and post `.valueChanged` on the tile. Later changes to a known count fade the field from 0 to 1 over 0.18 s.
    - Reduce Motion (`test_reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`, re-run on `accessibilityDisplayOptionsDidChangeNotification`): no placeholders; "–" in `headingDigits`/`labelCool2`.
    - When `isEveryKindKnown` flips true, the page is in a key window, and it is on screen: one low-priority "Finished looking for speakers."
    - Leave `isSearchDone` declared but unread; track D deletes it.
24. Run B verification.

**Track C: speaker and Main Audio pages**

25. **Tests first.** Declare `public var cantBeFoundIDs: Set<String> = []` on `DeviceDetailViewController`, unused for now. In `DeviceDetailViewTests`:
    - `rememberedDetailKeepsSceneRelationsAndSharedVisibility`: set `cantBeFoundIDs = ["bt"]` before `show`.
    - Extend `theCaptionReadsKindAndStatusThisMacOrCantBeFound`: with an empty list, study reads "AirPlay Speaker · Unavailable" with no glyph; with `["study"]`, "AirPlay Speaker · Can’t be found" with the glyph. New sentence.
    - Extend `aSpeakerThatCantBeFoundShowsItsStoredToneAndForget`: with an empty list, Forget is hidden and the stored tone is still shown; with `["study"]`, today's asserts.
    - `showInMixerCaptionFollowsTheValueAndLeavesThisMac`: the three new captions.

    In `MixerWindowControllerTests` `:49`, expect "Bluetooth Speaker · Not connected". Run and paste the failures.
26. **`DeviceDetailViewController`.**
    - `isCantBeFound` = `isLost && cantBeFoundIDs.contains(id)`.
    - `refreshSubtitle` always sets `attributedStringValue` (font `caption`, base `labelCool`). Order:
      - This Mac → "This Mac".
      - In the list → today's "Can't be found" text, glyph shown.
      - Record with nil kind → `status.text` alone.
      - Otherwise kind · status, with the status range in `speakersAccent` when the status is `.available` or `.connected`.
    - `subtitleLabel.redrawOnAccessibilityDisplayChange()`.
    - Glyph: `questionmark.circle` at 11 pt in `labelCool2`.
    - Forget is shown and acted on only when `isCantBeFound`.
    - Add pins `listBelowKeptNote` and `listBelowTitleRow` (sectionGap):
      - in `applyPerDeviceSectionVisibility`, first deactivate all six list pins (`listBelowEQWell`, `listBelowBTVolume`, `listBelowForget`, `listBelowHeader`, `listBelowKeptNote`, `listBelowTitleRow`); then `isLost` uses `listBelowForget` when `isCantBeFound`, else `listBelowTitleRow`;
      - in `refreshEQTitleRow`, when `isLost && !isCantBeFound` and the kept note is visible, swap `listBelowTitleRow` off and `listBelowKeptNote` on.
27. Show in Mixer captions (`:709-715`): "Shown while your Mac can reach it." / "Shown even when your Mac can't reach it." / "Shown only while it's in use." (curly apostrophes).
28. **Cool inks:**
    - `label2` → `labelCool` at `DeviceDetailViewController.swift:219, 271, 278, 281, 307, 950`, `MainOutDetailViewController.swift:103, 128`, and `EQEditorView.swift:216, 240, 307, 376, 384`.
    - `label3` → `labelCool2` at `EQEditorView.swift:334, 381, 475, 506`.
    - Chevron `label2` → `labelCool2` at `DeviceDetailViewController.swift:931`.
29. Run C verification.

**Track D: integration** (after A, B and C are merged)

30. **Tests first.** Declare `public var speakerSearch: SpeakerSearch?` on `MixerWindowController`, unused for now.
    - Update `forgetAlertCountsScenesAndRefusesToEmptyOne` to step 32's strings (den, 2 scenes, "those scenes"; attic, 1 scene, "that scene").
    - Add `forgetAlertNamesUpToTwoSpeakersAndCountsTheRest`:
      - Fixture: three remembered named speakers (A, B, C), each in no scene. A fourth id with no saved details exists only as a member of one scene. That scene also holds a live speaker, so forgetting does not empty it.
      - Forgetting all four → "“A”, “B” and 2 more will be removed from 1 scene. If one turns up again, it comes back to the speaker list, but not to that scene."
      - Forgetting A, B and C → all three named: "“A”, “B” and “C” aren’t in any scene. If one turns up again, it comes back to the speaker list."
    - Rewrite `aHiddenSpeakersPageStoresItsStateAndCatchesUpWhenShown`: attach a filled `SpeakerSearch` while the Scenes tab shows. After showing Speakers:
      - rows `["1 speaker can’t be found","Bluetooth access is off","Pair Bluetooth speaker…"]`;
      - the sidebar menu for "den" contains "Forget “Missing speaker”…";
      - `select(.device(id:"den"))` gives detail caption "Can’t be found".
    - Run and paste the failures.
31. **`MixerWindowController`.**
    - `speakerSearch` `didSet` sets `speakersPageViewController.search` and calls `reloadSpeakersPageIfShown()`.
    - Delete `setSpeakerSearchDone`.
    - `SidebarProjection`: replace `isFound` with `isCantBeFound`, keep `isInUse`, add top-level `splitsUnreachable`.
    - `refreshSidebar` and `reloadSidebarIfNeeded` pass `cantBeFoundIDs: speakerSearch?.cantBeFoundIDs ?? []` and `splitsUnreachable: speakerSearch?.isEveryKindKnown ?? true`.
    - `showDetail` and `refreshSpeakers` set `detailViewController.cantBeFoundIDs` before `show`/`refresh`.
    - `requestForget` first intersects ids with `speakerSearch?.cantBeFoundIDs ?? []`.
    - Reword the `firstSpeakerSelection` doc (`:653-664`) to what the code does: "alphabetical, Shown in Mixer before Hidden unless in use". Do not change its behaviour (it is on the Out-of-scope list).
32. **`makeForgetAlert`, the non-refusal branch only.**
    - Order the ids' records as the sidebar does: Shown group, then Hidden, each by `localizedStandardCompare`, then id.
    - n = 1: "It isn’t in any scene. If it turns up again, it comes back to the speaker list." / "It will be removed from 1 scene. If it turns up again, it comes back to the speaker list, but not to that scene." / "It will be removed from m scenes. …, but not to those scenes."
    - n > 1:
      - named = records with `metadataIsKnown`.
      - Subject: "They" when none are named; all named when every one is named and n ≤ 3; otherwise the first two named plus "and (n − shown) more".
      - Names are curly-quoted and joined with ", " and a final " and ".
      - Then " aren’t in any scene. If one turns up again, it comes back to the speaker list." or " will be removed from 1 scene / m scenes. If one turns up again, it comes back to the speaker list, but not to that scene / those scenes."
33. Delete `SpeakersPageViewController.isSearchDone` and its doc. Delete the `SidebarPresenceDotView` class from `SidebarViewController.swift`.
34. **`AppDelegate`.**
    - Replace `:1103` with `speakerSearch.onChange = { [weak self] in self?.mixerWindowController?.refreshSpeakerPresentation() }`.
    - Set `speakerSearch.isBluetoothAccessGranted` to read `permissionProviders.bluetoothReader.currentStatus() == .granted`.
    - Set `isLocalNetworkDenied` to read `permissionAuditModel?.localNetworkStatus == .denied`.
    - Replace `:2422` with `controller.speakerSearch = speakerSearch`.
    - Add `controller.speakersPage.onLocalNetworkAccess`: if `NSWorkspace.shared.open(SystemSettingsPane.localNetwork.url)` returns true, `Analytics.capture("speaker:privacy_settings_opened", ["access": "local_network"])`.
    - In the audit Task, after `isAuditingRequiredPermissions = false`, call `self.mixerWindowController?.refreshSpeakerPresentation()`.
35. `window-harness/main.swift:97-99`: expect `["System Audio", "Speakers", "Shown in Mixer"]`; message "'System Audio', 'Speakers' and 'Shown in Mixer' — scenes left the sidebar".
36. **`DESIGN.md`**, written from the shipped code:
    - Frontmatter: add `speakersAccent: "#41B07A"`.
    - After the Equalizer-Hue Fence's last paragraph (`:339-345`) and before the Instrument Ground Rule (`:347`), add "**The Speakers tab's green.**" with:
      - the token's values and meaning;
      - its four placements (Available label, kind counts above 0, the Pair glyph, the Ready/Connected word);
      - never selection, never a dark fill behind text, never the Mixer or the sidebar;
      - same base values as `equalizer`; not on the accent dial.
    - Typography: add `headingDigits` and `captionDigits`.
    - Rewrite the Speakers page paragraph (`:498-515`) and "Speakers Sidebar and Pages" (`:690-730`) to the shipped behaviour. This includes the 12-pt-taller captioned row, no system green, and the equalizer mark that stays.
    - Change "14.2" to "14.4" at `:642` and `:782`.
37. **`AudioutWindowUI/AGENTS.md`**:
    - `:12` → "- The sidebar shows reachability, never routing; its two groups are the visibility setting."
    - `:18` → "- Gold means live audio; magenta, group identity; green, a reachable speaker. Stock sidebar chrome remains native."
    - Map `:30` → "- `SpeakersPageViewController` → Overview; sanctioned custom shimmer."
    - `wc -w` must stay ≤ 300.
    - Append two lines dated with the commit date to `AudioutWindowUI/AGENTS-HISTORY.md`: one on the dot giving way to reachable-first order, the divider and row moves; one on green and the cool page inks.
38. Run the retired-terms grep, then D verification.

### Out of scope — do not touch
- `SurfaceToolbar*.swift` and the header strip, which stays neutral.
- The Mixer and popover, `DeviceRowView.swift` (`equalizerEngagedMarkImage(in:)` stays public), and `DeviceRowMutedStateTests` (no `speakersAccent` fence test).
- `EqualizerMarkView` and the speaker page's green equalizer mark.
- `EQResponseCurveView` ruler ink, `DiscoverySettleTracker`, `AppSurfaceController`, and `SpeakerLibraryController` / AudioutCore.
- `CompositedTokenContrastTests`: the green token is never composited now that the header seat is dropped.
- `window-snapshot` (must still compile; never regenerate goldens), the iPhone app, and the shared protocol field.
- `mixer:bt_pairing_settings_opened` and the Bluetooth access row's behaviour.
- `speaker:library_counted` (name, nine properties, firing moment) and `SpeakerLibraryCounts` fields.
- The `Tokens.equalizer` stale doc, the accent dial, and a green selection pill.
- FINAL-GREEN's header-seat and mark-removal parts.
- The onboarding card's "No speakers found yet" strings (`AudioutOnboardingUI/SetupCardView.swift:89`, `:116`) and the popover's `speakerNoneFoundText` (`AudioutPopoverUI/PopoverController.swift:2155`).
- `MixerWindowController.firstSpeakerSelection` behaviour (alphabetical; only its doc changes in step 31).
- No cleanup, no abstractions, no error handling for impossible cases, no backwards-compat shims.

### Retired terms
Exclude `.scratch/` from the grep, e.g. `git grep -n -i '<term>' -- ':!.scratch'`.

- `"In the Mixer"` (with the quotes)
- Hidden unless playing
- In the Mixer while it plays
- Keep in Mixer when unavailable
- Speakers, manage speakers
- found so far
- Done looking
- counts.total) speakers found
- 1 speaker found
- Looking for speakers on your network
- Listed while it
- Listed even while
- Listed only while it plays
- SidebarPresenceDotView
- presenceDot
- dotState
- activeMarkerView
- setActiveMarkerVisible
- playingWhileHiddenCaption
- PlateRowView.rowHeight
- setSpeakerSearchDone
- isSearchDone
- test_discoveryShowsSpinner
- test_kinds

### Verification
Each track ends with these commands passing. "All pass" means zero failures.

- **T0:** `bash scripts/run-tests.sh --filter TokenContrastMatrixTests` → all pass.
- **S:** `git -C "/Users/alechenderson/Projects/audiout-shared/worktrees/speakers-privacy-event" diff origin/main --stat` → `docs/analytics-events.md | 1 +`, and a PR URL.
- **A:** `bash scripts/run-tests.sh --filter "SidebarActionsTests|GroupsInkTemperatureTests|MixerWindowControllerTests|IncreaseContrastLiveReconcileTests"` → all pass.
- **B:** `bash scripts/run-tests.sh --filter "SpeakersPageTests|GroupsInkTemperatureTests|MixerWindowControllerTests"` → all pass.
- **C:** `bash scripts/run-tests.sh --filter "DeviceDetailViewTests|MixerWindowControllerTests"` → all pass.
- **D:**
  - `bash scripts/build.sh` → succeeds (covers `AppDelegate`, window-harness and window-snapshot).
  - `bash scripts/run-tests.sh --filter "MixerWindowControllerTests|SpeakersPageTests|SidebarActionsTests|DeviceDetailViewTests|GroupsInkTemperatureTests|AppSurfaceControllerTests|IncreaseContrastLiveReconcileTests"` → all pass.
  - `wc -w AudioutCore/Sources/AudioutWindowUI/AGENTS.md` → ≤ 300.

Test seams, with the defect each new test catches:
- `TokenContrastMatrixTests:152` (FINAL test 3 plus the green row): a retune drops a token under its floor. It compile-fails first; the sidebar-ground rows pass before the change by design.
- `SidebarActionsTests` (FINAL tests 1, 7, 8, 9, 10):
  - 1: an update falls back to `reloadData` and collapses the selection.
  - 7: Forget is offered outside the list.
  - 8: Command-Delete stops reaching the sidebar or loses the filter.
  - 9: the split runs from the first frame.
  - 10: `shouldSelectItem` falls back to `!isGroupItem`.
- `GroupsInkTemperatureTests` (FINAL test 2, both halves): brown or warm grey returns to the sidebar or Overview.
- `SpeakersPageTests` (FINAL tests 4, 5, 6, 11):
  - 4: AirPlay settles on 0.5 s.
  - 5: the event moves onto the page's rule. It pins kept behaviour, so it passes first.
  - 6: Forget is offered for slow or unreachable speakers.
  - 11: `reload()` rebuilds rows.
- `DeviceDetailViewTests:82`: "Can't be found" shows before the list holds the speaker.
- `MixerWindowControllerTests:1443`, plus the new naming test and the rewritten `:235` test: the sheet names wrongly, or the controller stops handing the list to the page, sidebar or speaker page.

Live checks owed (`APP_NAME="Audiout Dev" BUNDLE_ID="com.audiout.Audiout.dev" bash scripts/make-app.sh` with the live-test slot held, plus `scripts/run-on-vm.sh` for macOS 14):
- the selected-row inks on both pills;
- the geometry in Cross-area questions;
- the shimmer, and Reduce Motion.

### Execution plan
**Branch layout.**
1. T0 runs in `.claude/worktrees/speakers-tab-m` on `claude/speakers-tab-m` (at `f21fe1b9`, from `main`).
2. Create `.claude/worktrees/spk-a`, `spk-b` and `spk-c` (branches `claude/spk-a`, `claude/spk-b`, `claude/spk-c`, all from `f21fe1b9`). Apply T0's uncommitted patch in each, then run `git add -A` there and in `speakers-tab-m` (stage, don't commit), so T0's edits sit in the index everywhere.
3. Each of A, B and C hands back `git diff --binary` (its unstaged changes only, without T0's). Fold each into `speakers-tab-m` with `git apply --3way`; D runs serially there on the result.
4. PR: `gh pr create --base main`.

A, B and C depend on T0's uncommitted patch, which step 2 above applies. The briefs are untracked in speakers-nav, so read them by absolute path. Every file is outside `is_risk_path`.

| Track | Model / effort | Runs | Files |
|---|---|---|---|
| T0 tokens (steps 1–4) | sonnet, low | **Serial, first**: A, B and C consume `speakersAccent`, `headingDigits` and `captionDigits`, and B's Overview ink test needs the `ListRowView` caption change | `Tokens.swift`, `TokenContrastMatrixTests.swift`, `ListRowView.swift` |
| S shared row (step 5) | haiku, low | Parallel with anything; must merge in audiout-shared before the Mac PR merges | audiout-shared `docs/analytics-events.md` |
| A sidebar (6–16) | opus, high | Parallel after T0 | `SidebarViewController.swift`, `SidebarActionsTests.swift`, `GroupsInkTemperatureTests.swift` (suite doc `:18-21`, `:269` mark and the `:271` test), `MixerWindowControllerTests.swift` (`:46`, `:262`, `:286`, `:326`, `:553-575`, `:1304-1320`) |
| B Overview (17–24) | opus, high | Parallel after T0 | `SpeakersPageViewController.swift`, `SpeakersPageTests.swift`, `GroupsInkTemperatureTests.swift` (appended test), `MixerWindowControllerTests.swift` (`:235-258`) |
| C pages (25–29) | sonnet, medium | Parallel after T0 | `DeviceDetailViewController.swift`, `MainOutDetailViewController.swift`, `EQEditorView.swift`, `DeviceDetailViewTests.swift`, `MixerWindowControllerTests.swift` (`:49`) |
| D integration (30–38) | opus, medium | **Serial after the A+B+C merge**: it calls A's `reload(…cantBeFoundIDs:splitsUnreachable:)`, B's `SpeakerSearch` API and C's `cantBeFoundIDs`, and deletes symbols A and B leave behind | `MixerWindowController.swift`, `AppDelegate.swift`, `SpeakersPageViewController.swift`, `SidebarViewController.swift`, `window-harness/main.swift`, `MixerWindowControllerTests.swift`, `DESIGN.md`, `AudioutWindowUI/AGENTS.md`, `AGENTS-HISTORY.md` |

- A, B and C overlap only in test files, in separate regions. D's run is the combined check.
- The Forget/Command-Delete work is split: Command-Delete lives in the sidebar file, so it is in A; the sheet lives in `MixerWindowController`, so it is in D. A separate Forget track would collide with both.

### Executor rules (copy verbatim into the handoff prompt)
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
- [AppKit source list, live rendering] Once the dot slot is gone, does a level-1 cell start at sidebar x 16, so icons span x 16–38 and names start at x 46, and does AppKit add the measured 13 pt above each group row? FINAL §1.1 assumes both and neither can be seen headlessly. (affects steps 10, 11, 12, 15)
- [AppKit, macOS 14.4 and 27] Does the outline set each row view's `isEmphasized` when it gains or loses first responder, so the selected-row re-ink follows focus? FINAL asks for a macOS 14 check with `scripts/run-on-vm.sh`. (affects step 11)