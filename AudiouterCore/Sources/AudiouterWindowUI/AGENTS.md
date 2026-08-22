# AudiouterWindowUI

## Purpose

The Groups SCREEN's content — a CONFIGURATION-ONLY tree for viewing and
editing saved groups, and for describing and tuning speakers, hosted by the
one surface (`AppSurfaceController` in `AudiouterPopoverUI`). `MixerWindowController` owns NO window (the standalone
Groups window and the `AIRPLAY_CONTROL_PANEL` flag were retired in U6, plan
032); it is a screen-content controller vending `contentController` (a split
view: source-list sidebar + a swapped content pane) to whoever hosts it.
Viewing or editing a group here never activates it or moves audio — activation
lives in the Mixer screen. All group logic goes through the shared
`GroupController`; this module never computes volumes or talks to a backend.

## Rules

- **Configuration-only: sidebar selection ≠ activation.** Selecting a group
  opens its editor; selecting a device opens its detail pane (which describes
  the speaker and hosts its Equalizer — configuration, not playback);
  selecting "Main Audio" opens the whole-mix page; with nothing selected the
  screen AUTO-SELECTS the first saved group (or shows the empty pane). Nothing
  here ever calls `activateGroup`.
- **Hosts drive visibility through `setHostVisible(_:)`.** `update(devices:)`
  stores every snapshot but only rebuilds the UI while the host says the
  screen is visible (B8 — backend events fire for the whole app lifetime).
  Turning visibility on catches up from the stored snapshot. Test seam:
  `test_isVisibleOverride` (mirrors `PopoverController.test_isShownOverride`).
- **The sidebar split item must never end up collapsed.** It is the only way
  to change selection, and a collapse here is a ONE-WAY DOOR: the surface has
  no toolbar sidebar toggle and no View menu, and this controller is built once
  and reused for the process lifetime, so a collapsed sidebar strands the user
  on one group's editor for the rest of the session. `canCollapse = false`
  refuses the user's divider drag; `refreshAll()` re-asserts `isCollapsed =
  false` because that flag does NOT stop AppKit's own auto-collapse when the
  split is laid out narrower than its items' minimums. Keep both.
- **The content pane is swapped, not toggled.** `ContentPaneHostViewController
  .setContent(_:)` re-parents the child; the content `NSSplitViewItem` itself
  is never removed (that used to drag the footer along with it).
- **Persistent footer caption, scoped to the content pane.** It is content,
  not chrome — it ships wherever `contentController` is hosted. The sidebar
  split item runs the full split-view height, untouched by the footer.
  Hook: `test_footerText`.
- **The create sheet gates on the split VC's OWN host window**
  (`splitViewController.view.window?.isVisible`), never a window of this
  controller's (there is none). Headless runs keep the sheet reference and
  drive it via `test_createSheet`/`test_commit()`/`test_cancel()`.
- **The editor pane has NO scroll view, so its fitting height is a hard
  budget** — the Groups screen's content area
  (`AppSurfaceController.groupsDefaultContentSize` minus the surface header
  strip) minus the footer strip (`test_contentPaneChromeHeight`). The
  surface's default height is DERIVED from this budget; grow it there, never
  by letting the editor overflow (`MembershipRailTests`).
- **The screen's WIDTH is not the surface's to choose either — this pane's
  numbers set it.** AppKit widens the Groups window to the split view's
  fitting width, which is the sidebar's thickness + `GroupsPaneLayout
  .contentMaxWidth` + both column margins; the size
  `AppSurfaceController.groupsDefaultContentSize` asks for only holds while it
  matches. That is why the sidebar is PINNED at 210 (min == max: its own
  fitting width is ≥260, and every point past 210 was being charged to the
  window, which mounted 707 pt wide against the Mixer's 623) and why the
  column cap is 385. Raising either widens the whole screen.
- **Header parity is GEOMETRIC and lives in `GroupsPaneLayout`.** Editor and
  detail pane swap behind one sidebar; every shared number is read from that
  one enum — hand-copied literals once drifted ~22.5pt and made the header
  jump. `GroupsHeaderParityTests` asserts real laid-out frames. The VERTICAL
  cadence is shared the same way (`sectionGap`, `labelToSectionGap`,
  `actionBandGap`, `paneBottomInset` — tighter within a group of things than
  between them); both panes must breathe identically, so a gap that only one
  of them changes is a bug. TRAP: some of
  those numbers are HALF POINTS (`GroupsPaneLayout.contentLeadingInset` is
  38.5), and auto layout snaps every frame onto a rounding grid whose pitch
  varies BETWEEN RUNS of the same binary — so a 0.5pt failure there is the
  run's grid, not a broken layout. Those assertions measure that grid and
  allow exactly it; nothing else may.
- **The content column is ELASTIC, with two anchoring traps:** the rail
  overlay and the "Delete Group…" button anchor to the COLUMN, not the
  container, or they drift by exactly the column margin.
- **`SidebarViewController.viewDidAppear()` seeds Tab traversal for the whole
  hosting window** (A11Y-GROUPS) — nothing else ever calls
  `makeFirstResponder`. It only fires on a genuine on-screen appearance, so
  it is invisible to headless coverage; don't remove it as dead code.
  `ContentPaneHostViewController.setContent(_:)` re-seeds the key-view loop
  after every pane swap (re-parenting invalidates it) — keep both halves.
- **Gold means LIVE, so the editor's rail is armed/idle end to end.** The
  active Main Out group's editor draws its spine — hook, wire, member discs,
  hover ring — in gold; any other group's draws the whole spine in the quiet
  `ember` idle tone (`MembershipRowView.railArmed` →
  `MembershipBusView.apply(armed:)`, same truth as `railHookAnchor`'s `gold`).
  The sidebar mirrors it: the active group's row carries the small gold
  `speaker.wave.2.fill` "Playing now" marker (`IconLabelCellView`), the
  sidebar's ONE sanctioned use of gold.
- **Persistence failures are reported, never swallowed.** Every editor write
  goes through `saveOrReport(_:)` / `performDelete(id:)`: on a throw the pane
  re-renders from the model (no control may claim a state that never saved)
  and a plain-words alert names the problem. Seam: `test_saveFailureReported`.
- **The bottom add bar says what "+" will do.** With ≥2 speakers
  multi-selected it retitles live to "New Group from N Speakers…"; the create
  sheet then prefills its name from the selection ("Office + Sonos Move") and
  auto-focuses the field with the text selected.
- **Power paths live in the sidebar:** right-click context menu (group row →
  "Rename…"/"Delete Group…", speaker row → "New Group from Selection…" with
  clicked-vs-selected arbitration), Cmd-N (view-local key equivalent), and
  double-click-to-rename. The menu fires `onRequestRename`/`onRequestDelete`;
  `MixerWindowController` wires them to `focusRenameField()`/`requestDelete()`.
- **On `.warmPane` the WHOLE membership row is the toggle** (hitTest collapses
  non-checkbox hits onto the row; drag-off cancels; disabled row refuses), and
  hovering the row shows the node's ring. The active group's editor carries a
  "Playing now" badge in the header band and a reassurance caption beside
  "Delete Group…" — beside, not below: the editor pane's fitting height has
  ZERO headroom at a 7-device fleet, so new bands need surface-height budget
  first (`theActiveGroupsMarkersAddNoHeightToTheEditorPane`).
- **The two detail panes (device, Main Audio) SCROLL; the editor does not.**
  They host the Equalizer, whose Advanced fold exceeds the screen's budget,
  and the Groups screen is user-resizable with drag memory, so growing the
  window was rejected (roadmap 039 stays open for the editor). `FlippedView`
  documents, overlay scrollers, transparent. The `mixer-4-device-detail`
  goldens predate the Equalizer section and are unreproducible on macOS 27 —
  never regenerate.
- **All three sidebar sections are FLAT** (System Audio, Groups, Speakers) —
  no expand/collapse, no nested rows; the Speakers section lists EVERY device
  (membership is previewed in the editor, not by expansion).
- **Edit-affordance vocabulary: bordered + pencil = editable, bare =
  read-only.** The group name wears `WarmNameFieldCell`; a device name is a
  plain label at identical geometry. Both edit cues share
  `PopoverColumnGrid.editAffordanceRestAlpha`/`HoverAlpha`. A well with
  `isEditable == false` shows no badge (and refuses hover, click, Tab focus,
  Space/Return and VoiceOver press) — the Main Audio page's icon.
- **The rename field is a REAL `NSTextField`; only its drawing is ours.**
  Contract in `GroupRenameFieldTests`: Return/focus-loss commit, Escape
  reverts, emptying restores the name, first focus selects all, hover never
  moves geometry. Its width is three constraints (required ≥140 floor,
  below-`.defaultLow` measured hug, 999 cap at the section edge) — a bare cap
  collapses it to zero, a strong hug widens the whole pane.
- **`GroupsWindowTextColorLockTests` reaches the editor's drawn fill through
  the stored property named `membershipWell`** — renaming it breaks the test.
- **Text colors are frozen** (stock `.secondaryLabel`/`.tertiaryLabel`
  everywhere); contrast lifts from surfaces, never hue — a locked tradeoff.
  Don't "fix" it to warm text without re-confirming.
- **The icon-edit badge is the one approved custom-drawn element**
  (`DeviceIconWellView`): a persistent corner pencil badge that steps up on
  hover; the whole well is the click target. Being a bare `NSView` it
  hand-rolls `acceptsFirstResponder`, Space/Return, and
  `accessibilityPerformPress()` — preserve all three.
- **`DeviceIcon` is the single resolution point for a device/group's SF
  Symbol** — `DeviceIcon.resolve(_:default:)` everywhere, so a stale override
  falls back to the kind/group default rather than a blank glyph.
- **No synthesized clicks in headless runs.** Every user-facing action gets a
  `test_*` mirror or it is untestable outside a live window.
- **Depends on the model, never the reverse.** No backend types; everything
  arrives via `GroupController` or `update(devices:)`.
- **Two small `draw(_:)` overrides are token-resolution, not new chrome:**
  `HairlineView` (`MixerWindowController.swift`) and `WarmPreviewTileView`
  (`IconPickerViewController.swift`) draw rather than stamp a layer color so
  their `Tokens` fills (`hairline`, `canvas`) re-resolve live per appearance
  flip and Increase Contrast on every paint; `HairlineView` is click-through
  pure chrome. The content pane's `panel` fill is `AudiouterSharedUI`'s
  `WarmPanelView` — it moved there when the owner made it the ONE canvas
  every surface screen sits on (2026-08-07).

## Map

| Type | Role |
|---|---|
| `MixerWindowController` | Screen-content controller: owns the split view, sheet flow, auto-select rule; vends `contentController`; visibility via `setHostVisible(_:)`. |
| `ContentPaneHostViewController` | Swapped editor/detail/empty pane + the persistent footer caption. |
| `GroupsEmptyStateViewController` | Empty pane: "Group your speakers" + §5.9 teaching subtitle + New Group… |
| `SidebarViewController` | Source-list (System Audio + Groups + Speakers), all three FLAT; selection drives the content pane. |
| `GroupEditorViewController` | Edit-only pane: rename, membership toggles, delete. |
| `GroupCreationSheetController` | Standard macOS sheet for new groups; never activates. |
| `DeviceDetailViewController` | Device detail pane: describes the speaker + Equalizer section; icon-edit badge. |
| `MainOutDetailViewController` | Main Audio page: non-editable well + Equalizer + one note. |
| `IconPickerViewController` | Curated SF Symbol grid + validated search; reports via `onPick`. |
| `MembershipRowView` | Checkbox/node row shared by creation sheet and editor. |
| `DeviceIconWellView` | Large icon + at-rest edit badge (the one approved custom element). |
| `GroupsPaneLayout` | The panes' shared grid constants — the single parity source. |
| `GroupedSectionView` | The one grouped-section container (well fill, hairline, inset dividers). |
| `SidebarSelection` | Enum: `.mainOut`, `.group(id:)` or `.device(id:)`. |
