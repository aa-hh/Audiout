# AudioutWindowUI

## Purpose

The Groups SCREEN's content: a configuration-only tree for viewing/editing
saved groups and tuning speakers, hosted by the one surface
(`AppSurfaceController`). `MixerWindowController` owns no window and vends
`contentController`; all group logic goes through `GroupController`.

## Rules

- **Configuration-only: sidebar selection ≠ activation.** Selecting a group
  opens its editor, a device opens its detail pane, "Main Audio" opens the
  whole-mix page — nothing here ever calls `activateGroup`.
- **`setHostVisible(_:)` gates rebuilds, not `update(devices:)`** — snapshots
  always land, but the UI only rebuilds while the host says the screen is
  visible, catching up on the next visible flip (`test_isVisibleOverride`).
- **The sidebar split item must never end up collapsed — a ONE-WAY DOOR**,
  since this controller is built once for the process lifetime and a
  collapse strands the user on one editor for good. `canCollapse = false`
  refuses a divider drag; `refreshAll()` re-asserts `isCollapsed = false`
  because AppKit's own auto-collapse at narrower layouts ignores that flag.
- **The footer caption is content, not chrome** — it ships wherever
  `contentController` is hosted (`test_footerText`).
- **The create sheet gates on the split VC's own host window**, never this
  controller's — headless runs drive it via `test_createSheet`/
  `test_commit()`/`test_cancel()`.
- **The editor pane has no scroll view**, so grow the floor in
  `AppSurfaceController.minimumContentSize` — never let the editor overflow.
- **The split's fitting width is derived entirely from `SurfaceLayout`** —
  raising any component asks AppKit to widen a window that must not widen.
- **Header parity is geometric, lives in `GroupsPaneLayout`, shared, never
  hand-copied** (`GroupsHeaderParityTests`). TRAP: some numbers are half
  points, and auto layout's rounding-grid pitch varies BETWEEN RUNS of the
  same binary, so a 0.5pt failure there is the run's grid, not a bug.
- **The content column is elastic; the rail overlay and "Delete Group…"
  anchor to the column**, not the container, or they drift by the margin.
- **`SidebarViewController.viewDidAppear()` seeds Tab traversal for the
  whole window** — invisible to headless coverage, so don't remove it as
  dead code; `ContentPaneHostViewController.setContent(_:)` re-seeds it
  after every pane swap.
- **Gold means LIVE end to end.** The active Main Out group's editor draws
  its spine in gold (others in the quiet `ember` tone); the sidebar mirrors
  it with the only sanctioned gold elsewhere, a "Playing now" marker.
- **On `.warmPane` the whole membership row is the toggle.** TRAP: the
  editor's fitting height has ZERO headroom at a 7-device fleet, so new
  bands need budget first.
- **Persistence failures are reported, never swallowed** —
  `saveOrReport(_:)`/`performDelete(id:)` re-render from the model and
  alert in plain words on a throw (`test_saveFailureReported`).
- **The three pages are four slots in one housing** (Identity, Controls,
  Groups, About), earned by a different instrument, never by length; This
  Mac omits Controls.
- **The two detail panes scroll; the editor does not**, since the surface
  frame is fixed for every screen. The `mixer-4-device-detail` goldens are
  unreproducible on macOS 27 — never regenerate.
- **Edit-affordance vocabulary: bordered + pencil = editable, bare =
  read-only** (`PopoverColumnGrid.editAffordanceRestAlpha`/`HoverAlpha`).
- **The rename field is a real `NSTextField`; only its drawing is ours**
  (`GroupRenameFieldTests`: Return/focus-loss commit, Escape reverts,
  emptying restores the name, first focus selects all).
- **`GroupsWindowTextColorLockTests` reaches the drawn fill through the
  property named `membershipWell`** — renaming it breaks the test.
- **Text colors are frozen** (stock semantic labels); contrast lifts from
  surfaces, never hue — don't "fix" it without re-confirming.
- **The icon-edit badge (`DeviceIconWellView`) is the one approved
  custom-drawn element** — being a bare `NSView` it hand-rolls
  `acceptsFirstResponder`/Space/Return/`accessibilityPerformPress()`.
- **`DeviceIcon.resolve(_:default:)` is the single resolution point** for a
  device/group's SF Symbol, so a stale override falls back to the default.
- **No synthesized clicks in headless runs** — every user-facing action
  gets a `test_*` mirror or it is untestable outside a live window.
- **`HairlineView`/`WarmPreviewTileView` hand-draw rather than stamp a
  layer color** so their `Tokens` fills re-resolve live per appearance
  flip and Increase Contrast.

## Map

| Type | Role |
|---|---|
| `MixerWindowController` | Screen-content controller: owns the split view, sheet flow, auto-select rule; vends `contentController`; visibility via `setHostVisible(_:)`. |
| `ContentPaneHostViewController` | Swapped editor/detail/empty pane + the persistent footer caption. |
| `GroupsEmptyStateViewController` | Empty pane: "Group your speakers" + §5.9 teaching subtitle + New Group… |
| `SidebarViewController` | Source-list (System Audio + Groups + Speakers), all three FLAT; selection drives the content pane. |
| `GroupEditorViewController` | Edit-only pane: rename, membership toggles, delete. |
| `GroupCreationSheetController` | Standard macOS sheet for new groups; never activates. |
| `DeviceDetailViewController` | Device pane: identity → Equalizer card → Groups → About; icon-edit badge. |
| `MainOutDetailViewController` | Main Audio page: identity → Equalizer card → caption; non-editable well. |
| `IconPickerViewController` | Curated SF Symbol grid + validated search; reports via `onPick`. |
| `MembershipRowView` | Checkbox/node row shared by creation sheet and editor. |
| `DeviceIconWellView` | Large icon + at-rest edit badge (the one approved custom element). |
| `GroupsPaneLayout` | The panes' shared grid constants — the single parity source. |
| `GroupedSectionView` | The one container: `.card` (raised + hairline edge) or `.bare` (inset dividers only). |
| `SidebarSelection` | Enum: `.mainOut`, `.group(id:)` or `.device(id:)`. |
