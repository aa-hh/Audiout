# AudiouterWindowUI

## Purpose

The Groups SCREEN's content — a CONFIGURATION-ONLY tree for viewing and
editing saved groups, hosted by the one surface (`AppSurfaceController` in
`AudiouterPopoverUI`). `MixerWindowController` owns NO window (the standalone
Groups window and the `AIRPLAY_CONTROL_PANEL` flag were retired in U6, plan
032); it is a screen-content controller vending `contentController` (a split
view: source-list sidebar + a swapped content pane) to whoever hosts it.
Viewing or editing a group here never activates it or moves audio — activation
lives in the Mixer screen. All group logic goes through the shared
`GroupController`; this module never computes volumes or talks to a backend.

## Rules

- **Configuration-only: sidebar selection ≠ activation.** Selecting a group
  opens its editor; selecting a device opens its read-only detail pane; with
  nothing selected the screen AUTO-SELECTS the first saved group (or shows the
  empty pane). Nothing here ever calls `activateGroup`.
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
- **Header parity is GEOMETRIC and lives in `GroupsPaneLayout`.** Editor and
  detail pane swap behind one sidebar; every shared number is read from that
  one enum — hand-copied literals once drifted ~22.5pt and made the header
  jump. `GroupsHeaderParityTests` asserts real laid-out frames.
- **The content column is ELASTIC, with two anchoring traps:** the rail
  overlay and the "Delete Group…" button anchor to the COLUMN, not the
  container, or they drift by exactly the column margin.
- **`SidebarViewController.viewDidAppear()` seeds Tab traversal for the whole
  hosting window** (A11Y-GROUPS) — nothing else ever calls
  `makeFirstResponder`. It only fires on a genuine on-screen appearance, so
  it is invisible to headless coverage; don't remove it as dead code.
- **Both sidebar sections are FLAT** — no expand/collapse, no nested rows;
  the Speakers section lists EVERY device (membership is previewed in the
  editor, not by expansion).
- **Edit-affordance vocabulary: bordered + pencil = editable, bare =
  read-only.** The group name wears `WarmNameFieldCell`; a device name is a
  plain label at identical geometry. Both edit cues share
  `PopoverColumnGrid.editAffordanceRestAlpha`/`HoverAlpha`.
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
- **Three small `draw(_:)` overrides are token-resolution, not new chrome:**
  `WarmPanelView` and `HairlineView` (`MixerWindowController.swift`) and
  `WarmPreviewTileView` (`IconPickerViewController.swift`) draw rather than
  stamp a layer color so their `Tokens` fills (`panel`, `hairline`, `canvas`)
  re-resolve live per appearance flip and Increase Contrast on every paint —
  the `WarmCanvasView` pattern; `HairlineView` is click-through pure chrome.

## Map

| Type | Role |
|---|---|
| `MixerWindowController` | Screen-content controller: owns the split view, sheet flow, auto-select rule; vends `contentController`; visibility via `setHostVisible(_:)`. |
| `ContentPaneHostViewController` | Swapped editor/detail/empty pane + the persistent footer caption. |
| `GroupsEmptyStateViewController` | "No groups yet" pane: message + §5.9 teaching subtitle + New Group… |
| `SidebarViewController` | Source-list (Groups + Speakers), both FLAT; selection drives the content pane. |
| `GroupEditorViewController` | Edit-only pane: rename, membership toggles, delete. |
| `GroupCreationSheetController` | Standard macOS sheet for new groups; never activates. |
| `DeviceDetailViewController` | Read-only device detail pane; hosts the icon-edit badge. |
| `IconPickerViewController` | Curated SF Symbol grid + validated search; reports via `onPick`. |
| `MembershipRowView` | Checkbox/node row shared by creation sheet and editor. |
| `DeviceIconWellView` | Large icon + at-rest edit badge (the one approved custom element). |
| `GroupsPaneLayout` | The panes' shared grid constants — the single parity source. |
| `GroupedSectionView` | The one grouped-section container (well fill, hairline, inset dividers). |
| `SidebarSelection` | Enum: `.group(id:)` or `.device(id:)`. |
