# Work order: Scenes tab, direction F2

## Blocking question (answer before launch; the order below assumes the recommended default)

The F2 brief's toggle animation ("the ring fills from its centre to the disc, or drains back, over 0.15 s") can only be drawn by `MembershipBusView`, which lives in `AudioutCore/Sources/AudioutSharedUI/MembershipBusView.swift` (outside the fence) and is the same node the Mixer's rows draw, so the Mixer would gain the fill tween too. Options:

1. **Recommended default (scoped below):** no fill tween. The node lands on its new state at once, as it does today; the existing hover grow (0.12 s) stays. One sentence narrower than the brief; `MembershipBusView` and the Mixer untouched.
2. Widen the fence to `MembershipBusView` and give every node (Mixer included) the fill tween. Needs its own scoping pass for the Mixer's snapshot determinism and `MembershipBusTests`.

The count roll ("the one touch") is in scope and built below.

## Goal

Rebuild the Scenes tab as the Speakers tab's sibling: a 210 pt sidebar listing the saved scenes (name order, caption = "N speakers"), and the page beside it is the scene's editor (icon well, rename field, one card of membership rows, Delete band). The card grid, dashed tile, member chips, the in-pane push and every playing-state mark leave this tab. Membership rows keep the app's own node (gold disc = in, dormant ring = not in, dimmed node + "Unavailable" = in but unreachable) with no rail. Magenta identity glow sits behind every scene glyph. With no scenes, the page is a header plus one card row with a gold "Add scene…" button. A membership toggle ticks the count on the page caption and on the selected sidebar row together, digits rolling over 0.15 s. Nothing on the tab activates a scene. For: a Mac user with 2–12 speakers who comes here briefly to see and change what a scene contains, using the layout Speakers already taught them.

Read first, in this order: `AGENTS.md`, `AudioutCore/AGENTS.md`, `AudioutCore/Sources/AudioutWindowUI/AGENTS.md`, then the brief files by absolute path (they are untracked in this worktree only):
- `/Users/alechenderson/Projects/AirPlay Controller/.claude/worktrees/touchbar-play-button-status-05e2b1/.scratch/scenes-redesign/direction-f2/brief.md` and `changes.md`
- `…/.scratch/scenes-redesign/direction-f/brief.md` and `changes.md`
- `…/.scratch/scenes-redesign/direction-f2/mock.png`, `…/direction-f/mock.png`, `…/.scratch/scenes-redesign/SHARED-BRIEF.md`

Owner rulings (do not reopen): Speakers-tab topology, no push, no Done; no status words or marks on this tab; membership = `MembershipBusView` node over the invisible `NSButton`, no rail overlay; magenta `GroupIdentityGlowView` behind every scene glyph in the sidebar and the header well; gold `ProminentButton` on the empty page; toggle ticks both counts; creation sheet stays behind "Add scene" and ⌘N; icon picker stays behind the well's badge; sidebar in name order; sidebar caption is the count only; the Speakers tab's own sidebar is unchanged in behaviour; the empty page's card has only the "Add scene…" row (the "Or start from the Mixer" row is dropped).

## Verified facts

Folder rules that bind (cite in your head while editing):
- Tests must stay invisible and silent; every `show*()` gates on `HeadlessRuntime.isActive` (`AudioutCore/AGENTS.md:9-13`). A titled `NSWindow` with `defer: true` and no `orderFront` is how existing editor tests host views (`AudioutCore/Tests/AudioutCoreTests/GroupRenameFieldTests.swift:334-337`).
- "Never let the sidebar collapse"; "Panes fit the shared surface geometry; never widen the shell"; "Every editor exit … uses the host's dismissal path" (`AudioutCore/Sources/AudioutWindowUI/AGENTS.md:9-18`). The last rule is retired by this order (step 55).
- Trap: a split item built with `.sidebar(withViewController:)` makes AppKit reserve the toolbar's leading region; the Speakers split uses a plain `NSSplitViewItem` pinned min == max to `SurfaceLayout.sidebarWidth` with `canCollapse = false`, re-asserted in `refreshAll` (`MixerWindowController.swift:157-200, 786`).
- Trap: `showEditor(for:)` calls `show(groupID:devices:)` before the editor's view may be loaded, so state set in `show` must survive a later `loadView` (`GroupEditorViewController.swift:158-167, 303-315`).
- Trap: a `.sourceList` outline view's selection pill cannot be suppressed; plates and the pill take turns (`SidebarViewController.swift:1444-1453`).
- Guard 11: every new or moved `@Test` needs a sentence in the comment block directly above it naming the change that turns it red; a new test file needs more than one `@Test`; no real-time waits (`.githooks/guard-test-discipline.sh:9-20`). Guard 7 rejects slop comments.
- New suite files need no shard edit: unlisted suites run in the last shard (`scripts/lib/suite-shards.sh:9-13`); none of the suites touched here is in lists 1 or 2.

Code facts:
- `GroupsOverviewViewController.swift` (1181 lines) holds `GroupsOverviewViewController`, `GroupsOverviewLayout`, `CardPlan`, `GridCollectionView`, `GroupCardItem`, `GroupCardView`, `IconSeatView`, `MemberChipView`, `NewGroupTileItem`, `NewGroupTileView`. Its only production users are `MixerWindowController.swift:78,139,144,154-155,204,268-290,299,311,505-506,813-818,935,965` and `PopoverColumnGrid.swift:540` (a doc comment).
- `SidebarSelection` has cases `.mainOut, .groupsOverview, .speakersOverview, .group(id:), .device(id:)` (`SidebarViewController.swift:10-22`). `.groupsOverview` users: `MixerWindowController.swift:460,481,553`, `window-snapshot/main.swift:662,882`, `MixerWindowControllerTests.swift:368`, `SidebarActionsTests.swift:229`.
- `SidebarViewController.select(_:notify:)` clears the highlight when no row matches the target (`SidebarViewController.swift:937-952`); `onSelect` reports the primary selection (`:73`).
- Reusable sidebar parts: `IconLabelCellView` (`:1239-1324`, `final`; `statusLabel: NSTextField` at `:1269-1279`; `applySelectionInks` at `:1317-1323`), `SidebarHeaderCellView` (`:1334-1358`, init takes identifier + font; section titles use `Tokens.Font.captionEmphasized` at `:1780`), `SidebarRowView` (`:1423-1433`, `reink()` casts to `IconLabelCellView`), `SidebarContainerView` (`private`, ⌘N → `onCommandN`, `:1512-1533`), `SidebarOutlineView` (`private`, ⌘⌫ → `onCommandDelete`, `:1538-1549`), `newCell(identifier:isSpeakerRow:)` (`private static`, `:1927-1965`), `headerHeight = 19` (`private static`, `:1713`), captioned device row height = `outlineView.rowHeight + 12` (`:1733`), the add bar construction (`:246-297`), `refreshCells()` reconfigures cells in place through `view(atColumn:row:makeIfNecessary:false)` (`:902-915`), `selectionIndexesForProposedSelection` (`:1680-1693`), `outlineView.rowSizeStyle = .medium`, `style = .sourceList` (`:199-207`).
- `MembershipRowView` surfaces are `.warmPane` and `.systemSheet` (`MembershipRowView.swift:40-46`). **The brief's `.editor` host means `.warmPane`.** `railArmed` (`:54-60`) feeds `applyInk()` (`:272-290`: warm-pane name is `label` only when `railArmed && checked`) and `updateBus()` (`:300-308`). `railArmed` users outside the file: `GroupEditorViewController.swift:795,829,888,925`, `GroupsInkTemperatureTests.swift:215-231`. The row's `draw` paints only the glyph tile (`:415-429`); no hover wash exists. Hover is tracked by `hoverTracker` and pushed to the node in `applyHoverToNode()` (`:503-506`). `RailNodeProviding` conformance at `:605-610`; `railNode` is read by the editor's `test_railNodes` (`GroupEditorViewController.swift:1562-1564`) and `BusRailOverlayView.deviceRows` only.
- `MembershipBusView.apply(node:dimmed:armed:)` (`MembershipBusView.swift:159-164`); `.member` draws the filled disc, rim gold while armed; dimmed fills `socket`; `emphasizesDimmedMemberRim` is set by `MembershipRowView` (`:106`).
- `PopoverColumnGrid.fillRowWash(in:alpha:)` and `rowHoverWashAlpha = 0.10` (`PopoverColumnGrid.swift:535,552-558`); `railGutterCenterX = 20`, `firstElementLeading(indented:false)` = `GroupsPaneLayout.contentLeadingInset` (38.5), `busNodeHoverGrowDuration = 0.12`.
- `GroupEditorViewController` (1814 lines): `railOverlay` (`:68`), `onBack` (`:86`), `isActiveGroup` (`:100`), `backButton`/`BackButton` (`:113, 1749-1764`), `playingBadge` (`:163-167`), `reassuranceLabel` (`:183-195`), `savedAsYouGoActive` (`:211-212`), `doneTitle`/`saveTitle` (`:217-220`), `topBandTopInset`/`topBandControlGap` (`:239-242`), `header = PageHeaderView(… caption: playingBadge, leadingInset: .rail)` (`:122-123`), `membershipWell` (private, **name is load-bearing**: `GroupsInkTemperatureTests.swift:141-149` reads it by reflection), `render()` sets `isActiveGroup`, `iconWell.isActiveGroup`, badge, reassurance, rail (`:764-776`), `EditorProjection.Row.railArmed` (`:795,829`), `railArmed(for:memberSet:isActiveGroup:)` (`:846-850`), `updateRail()` (`:955-960`), `hasPendingRename`/`refreshPrimaryTitle` (`:974-987`), `cancelRename()` focuses `backButton` (`:1111-1115`), `doneTapped`/`backTapped` (`:1233-1243`), test seams at `:1291-1650`, `RailHookProviding` extension (`:1655-1689`), `RailRepaintingView` (`:1695-1736`, also `onBack`, ⌘[ and Escape), `RailRepaintingStackView` (`:1771-1779`, used only in this file), the "Speakers" label never calls `setAccessibilityHeading()` (grep: no hit in the file). `iconGlowSide = DeviceIconWellView.size + 16` = 64 (`:206`).
- `PageHeaderView(iconWell:title:caption:leadingInset:)` with `LeadingInset { railFree, rail }` (`PageHeaderView.swift:18-32`); `.rail` is used only by the editor; `.railFree` by `DeviceDetailViewController.swift:73-74`, `MainOutDetailViewController.swift:45-46`, `SpeakersPageViewController.swift:239-240`.
- `GroupsPaneLayout` docs mention the editor's rail and top band at `GroupsPaneLayout.swift:18-21, 42-45, 67-80`. `railFreeContentLeadingInset = 14`, `contentLeadingInset = 38.5`, `columnTopInset = 28`, `sectionGap = 20`, `labelToSectionGap = 6`, `actionBandGap = 22`, `contentMaxWidth = 475`.
- `ListRowView(glyph:title:caption:accessory:)` (`ListRowView.swift:55`); `GroupedSectionView.style`, `radiusOverride`, `contentLeadingInset`, `contentTrailingInset`, `rows` (`GroupedSectionView.swift:84-117`). The Speakers page's header + card + column layout is the pattern to copy for the empty page (`SpeakersPageViewController.swift:233-360`, `iconWell.isEditable = false` at `:304`).
- `ProminentButton(title:target:action:titleFont:)` (`AudioutSharedUI/ProminentButton.swift:64-65`). `GroupIdentityGlowView.side = 60`; the Main Audio row mounts it at `side` centred on its 26 pt icon, clipped by the row (`MainOutRowView.swift:508-513`). `Group.defaultIconSymbolName = "rectangle.3.group"` (`GroupStore.swift:27`). `DeviceIcon.resolve(_:default:)` and `DeviceIcon.image(_:)` exist (used at `GroupsOverviewViewController.swift:255,811`, `SidebarViewController.swift:1889`).
- `MixerWindowController`: `scenesHost = ContentPaneHostViewController(footerText: "Set up scenes here, then switch to the Mixer to play")` (`:109-110`), `scenesContentController` returns `scenesHost` (`:401-404`), `dismissEditor()` (`:496-500`) is called from `AppDelegate.swift:1440-1442` (`surface.groupsCancelHandler`), `AppSurfaceController.groupsCancelHandler` (`AppSurfaceController.swift:146-150`) tolerates nil; `groupsContent` is `() -> NSViewController` (`:257`). `orderedDevices()` = library records' order: available first, then by name (`:917-919`; `SpeakerLibraryController.swift:322-323`). `refreshAll`/`refreshScenes` (`:781-819`), `onDidEditGroup` wiring (`:308-312`), `presentCreateSheet` picks the presenter by which root's window is visible (`:743-746`).
- `MockBackend.demoFleet` has `id: "local-mac"`, `isLocalDevice: true` (`MockBackend.swift:689-690`); `MixerWindowControllerTests.makeWindow()` uses it (`:109-122`).
- `FoldAnimator` tweens an `NSLayoutConstraint.constant` only (`FoldAnimator.swift:112-135`); its ease is quadratic in-out (`:195`); `Tokens.Motion.collapseRevealDuration = 0.15` (`Tokens.swift:1515-1527`); `MembershipBusView` runs its own `NSView.displayLink` tween with `test_reduceMotionOverride` and instant settle off-window (`MembershipBusView.swift:174-227`) — the pattern the count roll copies.
- `window-snapshot/main.swift` selects `.groupsOverview` at `:662` ("scene-cards") and `:882` (state 8); header comment lines `:24-55` describe states 1 and 8 as the card overview.
- Tests that touch the card grid, the push or the rail (rewrite or delete as stepped): `GroupsOverviewViewControllerTests.swift` (whole file), `MixerWindowControllerTests.swift:311-464, 499-534, 879-896`, `MembershipRailTests.swift:257-465, 467-557, 567-579`, `GroupsInkTemperatureTests.swift:167-209, 213-236`, `GroupsHeaderParityTests.swift:167-189, 285-297, 310-357`, `GroupRenameFieldTests.swift:187-204, 331-349, 473-550`, `IncreaseContrastLiveReconcileTests.swift:148-165`, `CompositedTokenContrastTests.swift:118-123, 286-304`, `SidebarActionsTests.swift:229, 536-539`.
- `AppSurfaceControllerTests.swift:364,408` set `groupsCancelHandler` on the surface directly; unaffected.
- The `DESIGN.md` passages that describe the Scenes screen: `:527-528` (Scenes overview empty-state subtitle), `:636-649` (Layout: "card-grid scene overview… no sidebar", "Scenes overview scrolls a collection view"), `:769-770` (editor checklist radius `panel`), `:1066` (Escape order names the Scenes editor), `:1219-1225` (editor starts its well at the rail inset), `:1259-1260` (scene cards count unavailable members beside Playing/Feeding), `:1288` (card table row), `:1309-1310` (well fronting the active scene draws a gold edge), `:1323-1350` (ink temperature C5 on the Groups screen; editor sets `unarmedLineTone`), `:1391-1392` (Groups editor's rail passes no sections), `:1433` (collapseRevealDuration users).
- `AudioutWindowUI/AGENTS.md` map rows at `:28-40`; rule lines `:9-18`. `AGENTS-HISTORY.md` is append-only.

## Steps

Build checkpoint after step 34 and after step 48: `bash scripts/build.sh` must pass. Tests compile as one target, so no suite can run until step 60.

### A. The count that rolls

1. New file `AudioutCore/Sources/AudioutWindowUI/RollingCountLabel.swift`: `final class RollingCountLabel: NSTextField`. Declare no initialisers (so `RollingCountLabel(labelWithString:)` is inherited; if the compiler refuses, add `override init(frame:)` and `required init?(coder:)` that call super and nothing else). One method `func roll(to text: String)`: if `text == stringValue` return; remember the outgoing string, set `stringValue = text` at once (the model is always the target; `stringValue` never lags); if `window == nil` or Reduce Motion (`test_reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`) just `needsDisplay = true` and return; otherwise start a per-view `displayLink(target:selector:)` added to `.main` for `.common` (copy `MembershipBusView.startGrowthClock`'s shape, `MembershipBusView.swift:193-200`) that advances a `progress` 0→1 over `Tokens.Motion.collapseRevealDuration` with FoldAnimator's quadratic ease-in-out (`FoldAnimator.swift:195`), invalidating the link on arrival. Override `draw(_:)`: while rolling, clip to `bounds`, draw the outgoing text at its normal rect shifted up by `progress × bounds.height` and the incoming (`stringValue`) shifted down by `(1 − progress) × bounds.height` (the view is flipped; "up" is −y), both as attributed strings using the current `font` and `textColor` at the cell's `titleRect(forBounds:)` origin; when not rolling call `super.draw`. `viewDidMoveToWindow` with `window == nil` settles instantly. Seams: `var test_reduceMotionOverride: Bool?`, `var test_isRolling: Bool`, `func test_settleNow()` (progress = 1, link invalidated, redisplay). Doc comment: two sentences, no dates.

2. `SidebarViewController.swift:1269`: change `let statusLabel: NSTextField` to `let statusLabel: RollingCountLabel`, built with `RollingCountLabel(labelWithString: "")`. Nothing else in the cell changes; the Speakers sidebar keeps setting `stringValue` (instant).

### B. Share the sidebar's parts

3. `SidebarViewController.swift`: make `IconLabelCellView` (`:1239`) non-`final`; make `newCell(identifier:isSpeakerRow:)` (`:1927`) `static` instead of `private static`; make `SidebarContainerView` (`:1512`) and `SidebarOutlineView` (`:1538`) `final class` (internal) instead of `private final class`; make `headerHeight` (`:1713`) `static let` (internal). No other edit to the Speakers sidebar's behaviour.

4. `SidebarViewController.swift:251-272`: move the `addButton` configuration (bezel `.recessed`, `isBordered = false`, the 26 × 22 `plus` image, `imagePosition`, title "Add scene", `Tokens.Font.body`, tooltip, `.momentaryPushIn`) into `static func makeAddSceneButton(target: AnyObject, action: Selector) -> NSButton` on `SidebarViewController`; `loadView` calls it and keeps the add bar container and constraints (`:274-297`) inline as they are.

### C. The Scenes sidebar

5. New file `AudioutCore/Sources/AudioutWindowUI/ScenesSidebarViewController.swift`, `public final class ScenesSidebarViewController: NSViewController`, an `NSOutlineView` source list built exactly like `SidebarViewController.loadView` (`:189-300`): one column, `headerView = nil`, `style = .sourceList`, `floatsGroupRows = false`, `rowSizeStyle = .medium`, `allowsExpansionToolTips = true`, `allowsMultipleSelection = false`, the context `NSMenu` with `delegate = self`, the `SidebarOutlineView` with `onCommandDelete` wired to "request delete of the selected scene" (returns `false` with no selection), a `SidebarContainerView` with `onCommandN` wired to `onAddScene`, the scroll view, and the bottom add bar (`addBar` height = `outlineView.rowHeight`, button from `SidebarViewController.makeAddSceneButton`, leading 16, height 24, as `:289-297`). Also copy the `viewDidAppear` first-responder seeding (`:180-187`).

6. Model, in the same file: `public struct SceneRow: Equatable { let id: String; let name: String; let symbolName: String; let memberCount: Int }`. The tree is one `Node` class (payload `.header`, `.scene(SceneRow)`, `.placeholder`) with the "Scenes" header root kept for the controller's lifetime and one node per scene id kept across reloads (the `deviceNodes` pattern, `:132-133`). `public func reload(scenes: [SceneRow])`: sort by `name.localizedStandardCompare`, ties by `id`; when the id sequence equals the current one, update each node's payload and reconfigure the existing cells in place through `view(atColumn: 0, row:, makeIfNecessary: false)` (the `refreshCells` pattern, `:902-915`) — this is what lets a count roll instead of the cell being rebuilt; otherwise rebuild `header.children` (a `.placeholder` child when `scenes` is empty), `reloadData()`, `expandItem(header)`, and re-select the previously selected id if it still exists (callback suppressed).

7. Delegate/data source, same file: `isGroupItem` true for the header; `heightOfRowByItem`: header = `SidebarViewController.headerHeight`, scene = `outlineView.rowHeight + 12`, placeholder = `outlineView.rowHeight`; `rowViewForItem`: a `SidebarRowView` for scene rows, nil otherwise; `didAdd rowView` calls `reink()`; `selectionIndexesForProposedSelection`: header and placeholder rows are never selected, and an empty proposal returns the current selection while any scene row exists (the sidebar never shows "nothing selected" with scenes present); `viewFor`: header → `SidebarHeaderCellView(identifier:font: Tokens.Font.captionEmphasized)` with `label.stringValue = "Scenes"`; placeholder → a `SidebarHeaderCellView` reused with identifier `"scenesPlaceholder"` and `Tokens.Font.caption`, text "No scenes yet", `label.setAccessibilityElement(true)` and no heading role (call `setAccessibilityRole(.staticText)` on the label); scene → `SidebarViewController.newCell(identifier: "scene", isSpeakerRow: true)`.

8. Scene cell configuration, same file: `cell.imageView?.image = DeviceIcon.image(row.symbolName)`; `cell.nameLabel.stringValue = row.name`; caption text = `"1 speaker"` or `"\(n) speakers"`; on a fresh cell `cell.statusLabel.stringValue = caption`, on an in-place update `cell.statusLabel.roll(to: caption)`; `cell.statusLabel.isHidden = false`; `cell.statusLabel.font = Tokens.Font.captionDigits` (tabular digits keep the width steady while rolling; same 11 pt face); `cell.setDisclosureVisible(false)`; `cell.setRestingInks(name: Tokens.Color.label, icon: Tokens.Color.label)`; `cell.nameLabel.setAccessibilityLabel("\(row.name), \(caption)")`; then `cell.applySelectionInks(selected:emphasized:)` from its row view as `applyRowInks` does (`:1914-1917`). On a fresh cell also mount one `GroupIdentityGlowView` behind the glyph: `cell.addSubview(glow, positioned: .below, relativeTo: cell.imageView)`, width and height `GroupIdentityGlowView.side`, centred on `cell.imageView`, and `cell.wantsLayer = true; cell.layer?.masksToBounds = true` so the glow clips to the row as the Main Audio row clips it. Keep the glow as a stored reference on the cell by tagging: store it in a `[ObjectIdentifier: GroupIdentityGlowView]` dictionary keyed by cell, or check `cell.subviews.contains(where: { $0 is GroupIdentityGlowView })` before mounting — pick the latter.

9. Selection and callbacks, same file: `public var onSelect: ((String) -> Void)?` fired from `outlineViewSelectionDidChange` when not suppressed and a scene row is selected; `public var selectedSceneID: String?`; `public func select(sceneID: String, notify: Bool)` mirroring `SidebarViewController.select(_:notify:)` (`:937-952`); `public var onAddScene: (() -> Void)?`; `public var onRequestRename: ((String) -> Void)?`; `public var onRequestDelete: ((String) -> Void)?`. Context menu (`menuNeedsUpdate`, `autoenablesItems = false`): on a scene row, exactly the two items "Rename…" and "Delete scene…" acting on the clicked row (`clickedRow`), nothing on the header or placeholder. ⌘⌫ requests delete of `selectedSceneID`.

10. Test seams, same file: `test_rowIDs: [String]` (scene order), `test_rowCaption(id:) -> String?` (reads `statusLabel.stringValue`), `test_rowCell(id:) -> IconLabelCellView?`, `test_rowView(id:) -> NSTableRowView?`, `test_select(sceneID:)` (through the outline view's selection so `onSelect` fires), `test_contextMenuItems(for id: String) -> [String]`, `test_clickContextMenuItem(_ title: String, for id: String) -> Bool` (performs the item's action on its target, as `SidebarViewController.swift:1189` does), `test_tapAdd()`, `test_performCmdN() -> Bool` (build the ⌘N `NSEvent` as `SidebarViewController.test_performCmdN` at `:1199` does and send it to `view.performKeyEquivalent`), `test_pressCommandDelete()` (as `:1053`), `test_hasPlaceholderRow: Bool`, `test_glowIsBehindGlyph(id:) -> Bool` (glow index < imageView index in the cell's subviews), `test_filteredSelection(ofRows rows: IndexSet) -> IndexSet` (calls the delegate's proposal filter).

### D. The empty page

11. New file `AudioutCore/Sources/AudioutWindowUI/ScenesEmptyPageViewController.swift`, `public final class ScenesEmptyPageViewController: NSViewController`, laid out as `SpeakersPageViewController.loadView` lays out its column (`SpeakersPageViewController.swift:296-357`): `WarmPanelView` root, a column at `GroupsPaneLayout.columnTopInset` / `columnInset` / `columnTrailingInset` / `contentMaxWidth` with the same `columnFill` priority; `PageHeaderView(iconWell:title:caption:)` where the well has `isEditable = false`, image `DeviceIcon.image(Group.defaultIconSymbolName)`, accessibility label "Scenes"; title = `NSTextField(labelWithString: "Scenes")` in `Tokens.Font.heading`, `setAccessibilityHeading()`; caption = `NSTextField(labelWithString: "No scenes yet")` in `Tokens.Font.caption` / `Tokens.Color.labelCool`. Below it at `GroupsPaneLayout.sectionGap`, one `GroupedSectionView` (`.card`, `radiusOverride = Tokens.Layout.Radius.row`, `contentLeadingInset = ListRowView.leadingInset`, `contentTrailingInset = ListRowView.trailingInset`) behind a vertical stack holding exactly one `ListRowView(title: "Add scene…", caption: "Pick the speakers that play together. You switch to a scene from Main Audio in the Mixer.", accessory: button)` where `button = ProminentButton(title: "Add scene…", target: self, action: #selector(addTapped(_:)))`; `listWell.rows = [row]`. The row's width is pinned to the stack's width. `public var onAddScene: (() -> Void)?` fired by the button. Seams: `test_tapAddScene()` (performs the button's click), `test_addButtonIsProminent: Bool` (`accessory is ProminentButton`), `test_rowTitles: [String]`, `test_headerFrames` (as `SpeakersPageViewController.swift:645-648`).

### E. The membership row without its rail

12. `MembershipRowView.swift`: delete `railArmed` (`:48-60`) and its reads; `applyInk()` on `.warmPane` becomes: unavailable → name `labelCool`, glyph `labelCool2`, "Unavailable" word `labelCool2`; available → name `Tokens.Color.label`, glyph `Tokens.Color.label2`, "Unavailable" word `labelCool2` (no `checked` dependency). `updateBus()` calls `busView.apply(node: checked ? .member : .nonMember, dimmed: !isAvailable, armed: true)`. Rewrite the `Surface` and class doc comments (`:7-46, 292-299`) so they describe a node with no rail; drop the words rail, armed, LIVE and ember from them.

13. `MembershipRowView.swift`: delete the `RailNodeProviding` extension (`:599-610`). Rename `test_railArmed` to `test_nodeArmed` (reads `busView.test_armed` on `.warmPane`, `true` otherwise). Keep every other seam.

14. `MembershipRowView.swift`: hover wash. In `draw(_:)` on `.warmPane`, before the glyph tile, when `hoverTracker.isHovered && checkbox.isEnabled` call `PopoverColumnGrid.fillRowWash(in: bounds, alpha: PopoverColumnGrid.rowHoverWashAlpha)`. In `applyHoverToNode()` add `needsDisplay = true`. Add seam `test_drawsHoverWash: Bool` returning that same condition.

### F. The editor becomes the page

15. `PageHeaderView.swift`: delete the `LeadingInset` enum and the `leadingInset:` parameter; the well's leading constant is always `GroupsPaneLayout.railFreeContentLeadingInset`. Update the doc comment (`:6-14`). Drop the `leadingInset: .railFree` argument at `DeviceDetailViewController.swift:74`, `MainOutDetailViewController.swift:46`, `SpeakersPageViewController.swift:240`.

16. `GroupEditorViewController.swift`: delete `railOverlay` (`:57-68`), `onBack` (`:83-86`), `isActiveGroup` (`:91-100`), `backButton` and the `BackButton` class (`:102-113, 1738-1764`), `doneButton` (`:125-143`), `playingBadge` and `buildPlayingBadge()` (`:149-167, 669-696`), `savedAsYouGoActive`, `doneTitle`, `saveTitle` (`:211-220`), `topBandTopInset`, `topBandControlGap` (`:221-242`), `hasPendingRename`/`refreshPrimaryTitle` and every call (`:968-987, 778, 1030, 1098, 1796`), `doneTapped`/`backTapped` (`:1233-1243`), `railArmed(for:memberSet:isActiveGroup:)` (`:835-850`), `EditorProjection.Row.railArmed` and `EditorProjection.isActive` (`:795, 802, 820, 829-830`), `updateRail()` and its calls (`:902, 944, 955-960`), the `RailHookProviding` extension (`:1653-1689`), and these seams: `test_railPlan`, `test_isRailArmed(for:)`, `test_railNodes`, `test_nodeCenterXInOverlaySpace(for:)`, `test_playingBadgeVisible`, `test_doneButtonTitle`, `test_doneButtonAccessibilityLabel`, `test_done`, `test_doneButtonFrame`, `test_backControlFrame`, `test_backControlAccessibilityLabel`, `test_backControlToolTip`, `test_backControlAcceptsFocus`, `test_backButton`, `test_goBack`, `test_performBackKeyEquivalent`, `test_typeIntoNameField`.

17. `GroupEditorViewController.swift`: add `private let countLabel = RollingCountLabel(labelWithString: "")` configured at declaration (`Tokens.Font.captionDigits`, `Tokens.Color.labelCool`, `lineBreakMode = .byTruncatingTail`, compression resistance `.defaultLow` horizontal) and build `header = PageHeaderView(iconWell: iconWell, title: nameField, caption: countLabel)`. A helper `private static func speakerCount(_ n: Int) -> String` returns `"1 speaker"` / `"\(n) speakers"`. In `render(group:devices:)` set `countLabel.stringValue = Self.speakerCount(group.memberIDs.count)` (instant); in `membershipToggled` after `saveOrReport` succeeds and before `onDidEditGroup?()`, call `countLabel.roll(to: Self.speakerCount(group.memberIDs.count))`. Seam: `test_captionText: String { countLabel.stringValue }`, `test_captionIsRolling: Bool`.

18. `GroupEditorViewController.swift`: `loadView` no longer sets `iconWell.isRailOrigin`; `render` no longer sets `iconWell.isActiveGroup` or its accessibility value, and `reassuranceLabel.stringValue` stays `savedAsYouGo` (set once at declaration; delete the per-render assignment). `speakersLabel` gets `setAccessibilityHeading()` and its leading constant becomes `GroupsPaneLayout.railFreeContentLeadingInset`. `deleteButton.leadingAnchor` constant becomes `GroupsPaneLayout.railFreeContentLeadingInset` (it lines up with the well). `membershipWell.radiusOverride = Tokens.Layout.Radius.row`; `membershipWell.contentLeadingInset` stays `GroupsPaneLayout.contentLeadingInset` (dividers start at the row's glyph). The document's subviews are `[column, deleteButton, reassuranceLabel]`; remove the back/done/rail constraints (`:529-540, 654-663`) and the `railOverlay` lines in `loadView`. `railOverlay.unarmedLineTone` line goes.

19. `GroupEditorViewController.swift`: rename `RailRepaintingView` → `WellRepaintingView` and `RailRepaintingStackView` → `WellRepaintingStackView`; each keeps only the `membershipWell` weak reference and the `layout()` override that sets `membershipWell?.needsDisplay = true`. Delete `onBack`, `performKeyEquivalent` and `cancelOperation` from the container view (`:1699-1735`).

20. `GroupEditorViewController.swift`: `cancelRename()` makes `iconWell` first responder instead of `backButton`. Add seam `test_iconWell: NSView { iconWell }`.

21. `GroupEditorViewController.swift`: in `rebuildCandidates` and `buildRows`, delete the `row.railArmed = …` lines. In `show(groupID:devices:)`, after `let devices = records.map(\.renderingDevice)`, stable-partition so devices with `isLocalDevice == true` come first (the rest keep the library's order: available by name, then unavailable by name). Keep everything else (`EditorProjection` gate, row reuse, sole-member pin, `saveOrReport`, delete alert copy, Analytics calls at `:1027, 1178, 1509`).

22. `GroupEditorViewController.swift`: rewrite the class doc comment (`:7-54`) from the shipped page: header (well + glow + rename field + count caption), "Speakers" title, one card of membership rows, Delete band; writes through `GroupController`; no exit controls. No dates, no decision ids.

23. `GroupsPaneLayout.swift`: fix the doc comments at `:18-21` (every page starts its icon at `railFreeContentLeadingInset`), `:42-45` (drop the top-band sentence), `:67-80` (`contentLeadingInset` is where a membership row's glyph starts and the card's dividers begin; `railFreeContentLeadingInset` is where every page's header icon, headings and list text start).

### G. The window controller and the Scenes root

24. Delete `AudioutCore/Sources/AudioutWindowUI/GroupsOverviewViewController.swift`. Delete `AudioutCore/Tests/AudioutCoreTests/GroupsOverviewViewControllerTests.swift`. Fix the doc comment at `PopoverColumnGrid.swift:540` to drop the `GroupsOverviewViewController` mention (name the remaining user only).

25. `SidebarViewController.swift:10-22`: delete `case groupsOverview` and its comment; update the `SidebarSelection` and `.group` doc comments (a `.group` target is the Scenes tab's selection; the Speakers sidebar has no row for it and clears its highlight).

26. `MixerWindowController.swift`: replace `overviewViewController` with `private let scenesSidebarViewController = ScenesSidebarViewController()`, `private let emptyPageViewController = ScenesEmptyPageViewController()`, `private let scenesSplitViewController = NSSplitViewController()`, `private let scenesSidebarSplitItem: NSSplitViewItem`. In `init`, build the scenes split exactly as the speakers split (`:177-209`): plain `NSSplitViewItem(viewController: scenesSidebarViewController)` with `minimumThickness = maximumThickness = SurfaceLayout.sidebarWidth`, `canCollapse = false`; content item wraps `scenesHost`; `loadViewIfNeeded()`; `emptyPageViewController` joins the pre-load loop at `:322-331`. `scenesContentController` returns `scenesSplitViewController`. `refreshAll` re-asserts `scenesSidebarSplitItem.isCollapsed = false` beside the speakers one.

27. `MixerWindowController.swift` wiring, replacing `:267-312`: `scenesSidebarViewController.onSelect = { id in showEditor(for: id) }`; `onAddScene = { presentCreateSheet(preselected: []) }`; `onRequestRename = { id in showEditor(for: id); editorViewController.focusRenameField() }`; `onRequestDelete = { id in showEditor(for: id); editorViewController.requestDelete() }`; `emptyPageViewController.onAddScene = { presentCreateSheet(preselected: []) }`; `editorViewController.onDidDeleteGroup = { refreshAll() }`; `editorViewController.onDidEditGroup = { refreshSidebar(); reloadScenesSidebar() }`. Delete the `onBack` wiring and `dismissEditor()`.

28. `MixerWindowController.swift`: `showEditor(for:)` additionally calls `scenesSidebarViewController.select(sceneID: groupID, notify: false)` before `editorViewController.show(…)`. `showEmptyPage()` swaps `scenesHost` to `emptyPageViewController`. `handleSidebarSelection`: delete the `.groupsOverview` case; `.group(let id)` → `showEditor(for: id)`. `showDefaultSpeakersContent()` loses its `select(.groupsOverview…)` line (every path reaching it already has the Speakers sidebar's highlight cleared). `select(_:)`: `case .group: break` only.

29. `MixerWindowController.swift`: `private func sceneRows() -> [ScenesSidebarViewController.SceneRow]` from `groupController.groups` (`symbolName = DeviceIcon.resolve(group.iconSymbolName, default: Group.defaultIconSymbolName)`, `memberCount = memberIDs.count`). `private var lastSceneRows: [SceneRow]?`; `reloadScenesSidebar()` reloads only when the rows differ from `lastSceneRows` (and records them). `refreshScenes(devices:)` becomes: `reloadScenesSidebar()`; then if `editorViewController.editingGroupID` names an existing group → `editorViewController.show(groupID:devices:)` + swap to editor + `select(sceneID:notify:false)`; else if `scenesSidebarViewController.selectedSceneID` names an existing group → `showEditor(for:)`; else if the sorted rows are non-empty → `showEditor(for: firstRow.id)` (name order, the sidebar's own sort); else `showEmptyPage()`. The scene sheet's `onComplete` keeps `showEditor(for: result.group.id)` (now also selecting the row).

30. `MixerWindowController.swift` seams: delete `test_overview`, `test_isShowingScenesOverview`; add `test_scenesSidebar: ScenesSidebarViewController`, `test_emptyPage: ScenesEmptyPageViewController`, `test_isShowingScenesEmptyPage: Bool`. Rewrite the class doc comment (`:7-48`) and the `scenesHost` comment (`:107-110`): the Scenes root is a split of the scenes sidebar and the footer-bearing host that swaps between the scene page and the empty page. Update the `ContentPaneHostViewController` doc (`:1032-1036`) to drop the overview mention.

31. `AppDelegate.swift:1438-1442`: delete the `surface.groupsCancelHandler = …` assignment and its comment (Escape now closes the surface; `AppSurfaceController` is untouched).

32. `window-snapshot/main.swift`: at `:662-664` delete the "scene-cards" snapshot; at `:871-885` replace `test_select(.groupsOverview)` with selecting the "Party" scene (keep the id from `createGroup`'s result) and label the state `"8-three-scenes"`; rewrite the header comment lines `:24-26` (state 1 is the empty page: sidebar "No scenes yet" + the header and one-row card) and `:53-56` (state 8 is three scenes in the sidebar with Party's page).

33. `AudioutWindowUI/AGENTS-HISTORY.md`: append one line (date 2026-10-07) recording that the Scenes tab became a sidebar split of scenes beside the scene page, the card grid and push went, and the membership node lost its rail. Append only.

34. Checkpoint: `bash scripts/build.sh` passes.

### H. Tests

35. `MixerWindowControllerTests.swift`: rewrite `:311-325` as two tests: zero scenes → `test_isShowingScenesEmptyPage` and `test_scenesSidebar.test_hasPlaceholderRow`; `test_emptyPage.test_tapAddScene()` → `test_isPresentingCreateSheet` (cancel after) and `test_emptyPage.test_addButtonIsProminent`.

36. `MixerWindowControllerTests.swift:327-353`: rewrite as: with one saved scene and no selection, the Scenes root shows that scene's page with its row selected (`test_isShowingEditor`, `test_editor.editingGroupID == saved.id`, `test_scenesSidebar.selectedSceneID == saved.id`), the Speakers host still shows the Speakers page, `test_sidebar.currentSelection == nil`, `activeGroupID == nil`; and saving a scene adds its row (`test_scenesSidebar.test_rowIDs == [saved.id]`, `test_rowCaption(id:) == "2 speakers"`).

37. `MixerWindowControllerTests.swift:355-464`: delete `theEditorsBackBandReturnsToTheOverview`, `dismissEditorPopsAnOpenEditorAndRefusesWhenNoneIsOpen`, `doneAndCommandBracketBothReturnToTheOverview`. Rewrite `selectingTheGroupsRowShowsTheOverview` as "the two hosts are independent": select `.device(id: "office")`, `test_scenesSidebar.test_select(sceneID:)`, both `test_isShowingDetail` and `test_isShowingEditor` hold and `test_sidebar.currentSelection == .device(id: "office")`. Rewrite `openingACardPushesTheEditorAndLeavesTheSidebarAlone` to select through the scenes sidebar. Rewrite `removingAMemberUpdatesTheOverviewCardImmediately` as the one-touch test: after `test_editor.test_setMembership(false, for: "office")`, `test_editor.test_captionText == "1 speaker"` and `test_scenesSidebar.test_rowCaption(id: saved.id) == "1 speaker"` in the same turn (no settle needed: `stringValue` is the target). Add one test: three scenes "Kitchen", "Attic", "Zoo" → `test_rowIDs` follows name order (Attic, Kitchen, Zoo), and the auto-selected page is Attic's.

38. `MixerWindowControllerTests.swift:499-534`: rewrite the two card-menu tests to use `test_scenesSidebar.test_contextMenuItems(for:) == ["Rename…", "Delete scene…"]` and `test_clickContextMenuItem`; the delete flow then asserts `test_isShowingScenesEmptyPage` after `test_confirmDelete()`. `:879-896`: assert `test_isShowingScenesEmptyPage` after deleting the last scene. Add one test: with two scenes, deleting the selected one lands on the other's page with its row selected. Add one test: `test_editor.test_candidateDeviceIDs.first == "local-mac"` (This Mac leads the page's list).

39. `MixerWindowControllerTests.swift:368`: the `.groupsOverview` line is gone with step 37. Update the suite's doc comment (`:10-24`) to name the Scenes root as a sidebar split.

40. New file `AudioutCore/Tests/AudioutCoreTests/ScenesSidebarViewControllerTests.swift` (`@MainActor @Suite final class … : IsolatedSuite`, load the view and give it a 210 × 400 frame as `GroupsInkTemperatureTests.swift:304-307` does), at least these tests: rows sort by name with captions "1 speaker"/"N speakers"; an empty reload shows the placeholder row and no scene rows; `test_select(sceneID:)` fires `onSelect` once with the id; the proposal filter keeps the current selection for an empty proposal and never admits the header row; the context menu on a scene row is exactly `["Rename…", "Delete scene…"]` and the header has none; `test_performCmdN()` fires `onAddScene`; `test_pressCommandDelete()` fires `onRequestDelete` with the selected id; a selected row's name, icon and caption follow the pill (copy `SidebarActionsTests.swift:216-232`'s shape); `test_glowIsBehindGlyph(id:)` is true; a reload with the same ids and a changed count keeps the same cell instance (`test_rowCell(id:)` identity) and its caption reads the new count.

41. New file `AudioutCore/Tests/AudioutCoreTests/RollingCountLabelTests.swift`: under `test_reduceMotionOverride = true`, `roll(to:)` sets `stringValue` and `test_isRolling == false`; with no window and override `false`, the same; hosted in a titled `NSWindow(… defer: true)` never ordered front, override `false`: `test_isRolling == true` after `roll(to:)`, `stringValue` already equals the target, and `test_settleNow()` ends the roll; `roll(to:)` with the same text starts nothing.

42. `MembershipRailTests.swift:257-465`: delete `makeEditor`'s rail tests `editorSignalEndsAtTheLowestCheckedRowInAFullBandChannel`, `checkingALowerRowExtendsTheSignalDownToIt`, `editorRailPlanResolvesFromTheIconWellOrigin`, `stopsRunTopToBottomInCandidateOrder`, `theEditorLineIsGoldOnlyWhileTheGroupIsActive`, `aSavedMemberThatIsNotRoutedReadsIdle`, `aRoutedNonMemberReadsArmed`, `everyNodeCentreLandsOnTheOverlaysGutterLine`, and the `routed(_:_:)` helper. Rewrite `editorRowsCarryNodesMatchingMembership` to read each row through `test_membershipRow(for:) as? MembershipRowView` → `test_busNode`. Rewrite `activeGroupDrivesTheNodeToneToo` as "every member node is gold whether or not the scene is active": `test_nodeArmed == true` for every row before and after `activateGroup`. Keep `aRowClickInTheEditorPersistsLikeACheckboxClick`, `hoveringAnEditorRowPreviewsItsClick`, `pinnedSoleMemberExplanationReachesVoiceOver`, `nodeClearsTheIconColumn`, `sevenDeviceFleetFitsTheCreationSheetWithoutScrolling`. Add one test: hovering a row sets `test_drawsHoverWash`, a pinned row never does.

43. `MembershipRailTests.swift:467-557`: delete `thePrimaryLeavesTheEditorTheWayGroupsDoes`, `theWayBackKeepsItsShortcutAndItsVoiceOverName`, `theActiveMarkersNeverMoveTheHeaderBand`, `theActiveGroupsMarkersAddNoHeightToTheEditorPane`. Rewrite `everyEditorSaysEditsAreSavedAndOnlyTheActiveOneSaysPlayingNow` as "the reassurance line never mentions playback": `test_reassuranceText == "Changes are saved as you go."` before and after `activateGroup`. Update the suite doc comment to drop the editor's rail. Also check `:1-256` for any `railArmed` use (none expected).

44. `GroupsInkTemperatureTests.swift`: delete `:167-209` (the four card tests). Rewrite `memberRowInkFollowsArmedMembership` (`:213-226`) as "a member row's ink is warm whether checked or not": name `label`, glyph `label2` for `checked: true` and after `isChecked = false`. In `unavailableMemberRowTakesTheSidebarsInk` delete the `row.railArmed = true` line. Update the suite doc comment (`:10-23`): the Scenes page's only ink temperature is an unavailable member.

45. `GroupsHeaderParityTests.swift`: in `headerContentStartsAtTheSharedContentInset` (`:167-189`) the editor's inset is now `railFreeContentLeadingInset`; in `bothPanesPutTheIconWellAndTitleAtTheSameGeometry` add `#expect(abs(editorIcon.minX - detailIcon.minX) <= slack)`. Delete `everyNodeStillLandsOnTheOverlaysGutterLineAfterTheColumnMovedIn` (`:285-297`), `theWayBackAndThePrimaryShareOneBandAtTheTopOfTheForm` (`:316-333`). Rewrite `theTopBandClearsTheIdentityCardWithoutMovingIt` (`:339-357`) as "the form starts at the shared top inset", keeping only the `columnTopInset` assertion. Fix the suite and `GroupsPaneLayout` references in comments at `:20-22, 26-28`.

46. `GroupRenameFieldTests.swift`: delete `thePlayingBadgeNeverNarrowsALongName` (`:187-204`), `primaryReadsDoneUntilTheFieldHoldsAnUncommittedName`, `paddingTheNameWithSpacesIsNotAnUncommittedChange`, `pressingSaveCommitsTheTypedNameAndThenLeaves`, `saveOnANameAnotherGroupHoldsKeepsTheEditorOpen` and the comment block `:473-479`. Rewrite `escapeLandsKeyboardFocusOnTheBackControl` (`:331-349`) to expect `host.firstResponder === editor.test_iconWell`. Rewrite `escapeRevertsTheNameAndTheTitleWithIt` as `escapeRevertsTheName` without the title assertions.

47. `IncreaseContrastLiveReconcileTests.swift:148-165`: delete `theGroupCardAndEverythingOnItRedraws` and `theGroupsOverviewCanvasRedraws`. `CompositedTokenContrastTests.swift`: delete `liveWash(over:_:)` (`:118-123`) and the three "Groups card" pairs (`:286-304`) with their MARK comment. `SidebarActionsTests.swift:229`: deselect with `sidebar.select(.device(id: "no-such-row"), notify: false)`; `:536-539`: the comment now names `ScenesSidebarViewControllerTests`.

48. Checkpoint: `bash scripts/build.sh` passes.

### I. Docs (written from the shipped code)

49. `DESIGN.md:636-649` (Layout): the Scenes root is a sidebar split like Speakers (210 pt sidebar of scenes, the scene page or the empty page beside it, footer under the page only); delete "The Scenes overview scrolls a collection view"; the scene page is a top-anchored scrolling column like the speaker page.

50. `DESIGN.md:527-528`: drop "and the Scenes overview's empty-state subtitle". `:769-770`: the scene page's card rounds at `row`; only the Speakers page list stays at `panel`. `:1066`: Escape order is "thank-you card, then the bubble closes".

51. `DESIGN.md:1168-1261` (Speakers Sidebar and Pages): after the add-bar paragraph add a "Scenes sidebar" paragraph: title "Scenes" (`captionEmphasized`/`labelCool`, heading), one `IconLabelCellView` row per scene in name order with the glyph over a `GroupIdentityGlowView` clipped to the row, the count caption in `captionDigits`/`labelCool` that rolls on a change, the stock pill, "No scenes yet" when empty, the same add bar and ⌘N, row menu Rename…/Delete scene…, ⌘⌫. Rewrite `:1219-1225` so every page starts its well at the rail-free inset and the scene page passes its editable field as the title and the count as the caption. Replace `:1259-1260` with the scene page's rows (node states, "Unavailable"/"Not connected", last member pinned) and the empty page (well, "Scenes", "No scenes yet", one card row with the gold `ProminentButton` "Add scene…"). `:1288` table row: "the list on the Overview, a speaker's page and the scene page". `:1309-1310`: delete the active-scene gold-edge sentence.

52. `DESIGN.md:1323-1350`: rewrite the paragraph: the glow sits behind every scene glyph in the sidebar and behind the scene page's well; the scene page's rows draw the node with no rail (gold disc = member, `railDormant`-toned ring = non-member, `socket`-filled disc with the heavier rim = unavailable member); names `label`, unavailable `labelCool`, pinned by `GroupsInkTemperatureTests`; delete the `unarmedLineTone`/editor sentences and `:1391-1392`. `:1433`: add the count roll (`RollingCountLabel`) to the users of `collapseRevealDuration`; note the count's digits slide, instant under Reduce Motion.

53. `AudioutWindowUI/AGENTS.md` map: delete the `GroupsOverviewViewController` row; `SidebarViewController` → "Speaker list; its cells and add button serve the scenes sidebar too."; add `ScenesSidebarViewController` → "Scene list beside the scene page."; `GroupEditorViewController` → "Scene page: rename, membership, delete."; add `ScenesEmptyPageViewController` → "No-scenes page with the one add action."; add `RollingCountLabel` → "Count whose digits slide on a change."

54. `AudioutWindowUI/AGENTS.md` rules: replace "Gold means live audio; magenta, group identity; green, a reachable speaker." with "Gold means live audio, and membership on the scene page; magenta, group identity; green, a reachable speaker."; add "Neither sidebar may collapse" wording to the existing collapse rule; keep under 300 words.

55. `AudioutWindowUI/AGENTS.md:15`: delete "Every editor exit, keyboard included, uses the host's dismissal path."

56. Root `AGENTS.md` and `AudioutCore/AGENTS.md`: no change (their map rows stay true).

57. Run the Retired-terms grep (executor rules) and list every remaining hit outside the steps above.

58. Verification (below).

## Out of scope — do not touch

- `MembershipBusView.swift`, `BusRailOverlayView.swift`, `DeviceRowView.swift`, anything in `AudioutPopoverUI` (the Mixer's rail, nodes and Main Audio menu), `AppSurfaceController.swift` (its `groupsCancelHandler` stays, unset).
- `DeviceIconWellView.swift` (`isActiveGroup`/`isRailOrigin` stay as unused inputs), `GroupCreationSheetController.swift` and `IconPickerViewController.swift` (the sheet keeps `.systemSheet` rows), `SpeakersPageViewController.swift` and `DeviceDetailViewController.swift`/`MainOutDetailViewController.swift` beyond the one-argument edit in step 15.
- `Tokens.swift`: no new token, font, duration or colour. No per-scene colour.
- `SpeakerLibraryController.records` order and `MixerWindowController.orderedDevices()` (the sheet shares them); the This-Mac-first sort lives in the editor only.
- The Speakers sidebar's behaviour, its add bar title logic, its reachability rules, its menus.
- No status words or marks on the tab: no "Playing", no "Feeding", no gold well edge, no `label`/`labelCool` split by playback.
- No Done, Save, back control, ⌘[, or Escape handling in the page.
- No new Analytics events; the four `scene:*` captures stay where they are.
- `docs/SPEC.md`, `dev/notes/*`, snapshot PNGs (the renderer is known to produce blank frames; only keep `main.swift` compiling and sensible).
- No cleanup beyond the named deletions, no abstractions, no error handling for impossible cases, no backwards-compat shims (no `.groupsOverview` alias, no `dismissEditor` stub).

## Retired terms

GroupsOverviewViewController
GroupsOverviewLayout
GroupCardView
GroupCardItem
GridCollectionView
NewGroupTileView
NewGroupTileItem
MemberChipView
IconSeatView
CardPlan
groupsOverview
showOverview
dismissEditor
onBack
BackButton
backButton
doneButton
doneTitle
saveTitle
hasPendingRename
refreshPrimaryTitle
playingBadge
buildPlayingBadge
savedAsYouGoActive
railArmed
railOverlay
updateRail
railHookAnchor
RailRepaintingView
RailRepaintingStackView
topBandTopInset
topBandControlGap
LeadingInset
railFree
test_overview
test_isShowingScenesOverview
test_goBack
test_performBackKeyEquivalent
test_done
test_doneButton
test_backControl
test_backButton
test_playingBadgeVisible
test_railPlan (only the editor's; the popover keeps its own)
test_isRailArmed
test_railNodes
test_railArmed
test_nodeCenterXInOverlaySpace
test_typeIntoNameField
test_cardGroupIDs
test_clickCard
test_isShowingEmptyCanvas
test_tapNewGroup
card grid
dashed tile
member chip
scene cards
Back to Scenes
Playing now
Feeding
Set up a scene

## Verification

```
bash scripts/build.sh
bash scripts/run-tests.sh --filter "MixerWindowControllerTests|ScenesSidebarViewControllerTests|RollingCountLabelTests|MembershipRailTests|GroupsInkTemperatureTests|GroupsHeaderParityTests|GroupRenameFieldTests|GroupEditorClickTargetTests|MembershipWellContrastTests|SidebarActionsTests|IncreaseContrastLiveReconcileTests|CompositedTokenContrastTests"
```
Expected: build passes; the filtered run prints `Test run with N tests in 12 suites passed` with zero failures. Then `git grep -n -i` for each Retired term across `AudioutCore/Sources`, `AudioutCore/Tests`, `DESIGN.md` and every `*.md`: the only hits may be in `AGENTS-HISTORY.md` files and `dev/notes/`.

## Execution plan

One track, SERIAL internally, phases A→I as numbered. Model: **opus**, effort: **high**. Every deletion of a seam breaks the single test target until every reference is fixed, so no sub-track can be green on its own; the only additive seam (phase A–D, new files plus the five visibility edits in `SidebarViewController.swift`) could run first as its own track, but nothing can run beside it, so there is no wall-clock gain. Files owned: `AudioutCore/Sources/AudioutWindowUI/{RollingCountLabel,ScenesSidebarViewController,ScenesEmptyPageViewController,SidebarViewController,MembershipRowView,GroupEditorViewController,PageHeaderView,GroupsPaneLayout,MixerWindowController,DeviceDetailViewController,MainOutDetailViewController,SpeakersPageViewController,AGENTS,AGENTS-HISTORY}.*`, `GroupsOverviewViewController.swift` (deleted), `AudioutCore/Sources/AudioutSharedUI/PopoverColumnGrid.swift` (one comment), `AudioutCore/Sources/AudioutApp/AppDelegate.swift` (three lines), `AudioutCore/Sources/window-snapshot/main.swift`, the twelve test files named in Verification plus `GroupsOverviewViewControllerTests.swift` (deleted), `DESIGN.md`. The branch `claude/scenes-tab-redesign-ee9802` has no uncommitted source work; only `.scratch/scenes-redesign/` is untracked, so a sibling worktree forked from HEAD `ccd0ed98` must read the briefs by the absolute paths above. Nobody commits.

## Executor rules (copy verbatim into the handoff prompt)
> - Follow the steps in order. Do not add, merge, reorder, or skip steps.
> - Before editing in any folder, read the nearest AGENTS.md above it (and the root one) if the repo has them — folder rules and traps bind even when the work order doesn't repeat them.
> - If reality contradicts a Verified fact or a step is impossible as written, STOP and report the discrepancy. Do not improvise a workaround.
> - Before reporting progress, audit each claim against a tool result from this session. Only report work you can point to evidence for. If tests fail, say so with the output.
> - "Done" means the Verification commands were run in this session and passed. Paste their output.
> - Touch nothing in the Out-of-scope list.
> - Deliver what was asked, at the scope intended. If the spec seems mistaken or a better approach exists, say so in a sentence and continue as specified rather than quietly narrowing, widening, or transforming it.
> - If a step changes code that another screen, window or surface also draws or calls and the work order does not name that surface, STOP and report it as a discrepancy before editing. Flagging it and continuing is not enough; the owner decides whether the change applies there.
> - When the work order lists Retired terms, after the last step run `git grep -n -i` for each term across `AudioutCore/Sources`, `AudioutCore/Tests`, `DESIGN.md` and every `*.md`, fix the hits a step covers, and list every other hit with file:line in your report. A new or moved test carries one comment sentence naming the code change that turns it red.
> - A test you add or move carries one comment sentence naming the code change that turns it red; a new test extends an existing suite before it starts a new file; folder AGENTS.md lines carry no dates, rulings or decision ids, and AGENTS-HISTORY.md is only appended to; DESIGN.md sections are rewritten from the shipped code, never from the plan.