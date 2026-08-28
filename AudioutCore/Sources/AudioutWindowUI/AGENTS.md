# AudioutWindowUI

## Purpose

The Groups SCREEN's content — a CONFIGURATION-ONLY tree for viewing and
editing saved groups, and for describing and tuning speakers, hosted by the
one surface (`AppSurfaceController` in `AudioutPopoverUI`). `MixerWindowController` owns NO window;
it is a screen-content controller vending `contentController` (a split
view: source-list sidebar + a swapped content pane) to whoever hosts it.
All group logic goes through the shared
`GroupController`; this module never computes volumes or talks to a backend.

## Rules

- **Configuration-only: selection ≠ activation.** Selecting the pinned Groups
  row opens the saved-group card overview, and a card pushes that group's
  editor in place; selecting a device opens its detail pane (which describes
  and hosts its Equalizer — configuration, not playback);
  selecting "Main Audio" opens the whole-mix page; with nothing selected the
  screen AUTO-SELECTS the **Groups row and its overview** — never one group's
  editor, and never a separate empty pane (the overview draws its own
  zero-groups canvas). Nothing here ever calls `activateGroup`.
- **Hosts drive visibility through `setHostVisible(_:)`.** `update(devices:)`
  stores every snapshot but only rebuilds the UI while the host says the
  screen is visible (backend events fire for the whole app lifetime).
  Turning visibility on catches up from the stored snapshot. Test seam:
  `test_isVisibleOverride` (mirrors `PopoverController.test_isShownOverride`).
- **The sidebar split item must never end up collapsed.** It is the only way
  to change selection, and a collapse here is a ONE-WAY DOOR: the surface has
  no toolbar sidebar toggle and no View menu, and this controller is built once
  and reused for the process lifetime, so a collapsed sidebar strands the user
  on one group's editor for good. `canCollapse = false`
  refuses the user's divider drag; `refreshAll()` re-asserts `isCollapsed =
  false` because that flag does NOT stop AppKit's own auto-collapse when the
  split is laid out narrower than its items' minimums. Keep both.
- **The content pane is swapped, not toggled.** `ContentPaneHostViewController
  .setContent(_:)` re-parents the child; the content `NSSplitViewItem` itself
  is never removed.
- **Persistent footer caption, scoped to the content pane.** It is content,
  not chrome — it ships wherever `contentController` is hosted. The sidebar
  split item runs the full split-view height, untouched by the footer.
  Hook: `test_footerText`.
- **The create sheet gates on the split VC's OWN host window**
  (`splitViewController.view.window?.isVisible`), never this
  controller's window. Headless runs keep the sheet reference and
  drive it via `test_createSheet`/`test_commit()`/`test_cancel()`.
- **All three panes SCROLL — the editor included (roadmap 039).** The surface
  frame is FIXED, so a fleet the editor cannot fit used to have to be paid for
  by raising `AppSurfaceController.minimumContentSize`; it overflows into its
  own scroller now. Same recipe in all three: a `FlippedView` document (so the
  form starts at the TOP rather than bottom-gravitating), overlay scrollers, no
  background, and the document HUGS its content — which is why the editor's
  "Delete Group…" bottom pin is an EQUALITY against the document (a `<=`
  against the pane made the whole chain above it stretch to reach). Seams:
  `test_hasScrollView`, `test_scrollDocumentHeight`; guarded by
  `AppSurfaceControllerTests.theSevenDeviceEditorScrollsInsideTheMinimumFrame`.
  The `mixer-4-device-detail` goldens are unreproducible on macOS 27 — never
  regenerate.
- **The split's fitting width is `SurfaceLayout.sidebarWidth` +
  `GroupsPaneLayout.contentMaxWidth` + both margins = `SurfaceLayout.width`**,
  all derived from `SurfaceLayout` — guarded by
  `AppSurfaceControllerTests.noGroupsPaneAsksForMoreThanTheFrameWidth`.
  Raising any of them asks AppKit to widen a window that must not widen.
- **Header parity is GEOMETRIC and lives in `GroupsPaneLayout`.** Editor and
  detail pane swap behind one sidebar; every shared number is read from that
  one enum, never hand-copied. `GroupsHeaderParityTests` asserts real laid-out
  frames. The VERTICAL
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
  **This module names `Tokens.Color.gold` in exactly seven places, and six of
  them say LIVE:** the sidebar Groups row's `speaker.wave.2.fill` marker
  (`SidebarViewController`'s `IconLabelCellView`, the sidebar's only gold); on
  the live card, its wave glyph, the "Playing now" half of its meta line, and
  its border (`GroupsOverviewViewController`'s `GroupCardView` — three sites,
  not one); the editor header's "Playing now" badge GLYPH
  (`GroupEditorViewController.buildPlayingBadge` — glyph only, the caption
  beside it stays stock `.secondaryLabel`); and the icon well's edge while the
  edited group is the active Main Out (`DeviceIconWellView.isActiveGroup`; an
  idle rail origin gets the quiet `ember` instead). The rail above is a
  SEVENTH live meaning but not a seventh site here — it is armed from this
  module and drawn in `AudioutSharedUI` (`MembershipBusView`). The one site
  that does NOT mean live is the icon picker's ring around the
  currently-chosen symbol (`IconPickerViewController
  .refreshSelectionRingColor`), inside a modal sheet where nothing is playing
  to mark. Nothing else, ever — gold is never decoration here.
- **Persistence failures are reported, never swallowed.** Every editor write
  goes through `saveOrReport(_:)` / `performDelete(id:)`: on a throw the pane
  re-renders from the model (no control claims a never-saved state)
  and a plain-words alert names the problem. Seam: `test_saveFailureReported`.
- **The bottom add bar says what "+" will do.** With ≥2 speakers
  multi-selected it retitles live to "New Group from N Speakers…"; the create
  sheet prefills its name from the selection ("Office + Sonos Move") and
  auto-focuses the field with the text selected.
- **Power paths follow what they act on.** A group's "Rename…"/"Delete Group…"
  right-click menu lives on its CARD, with the groups; the sidebar keeps what
  is anchored to the device list — the speaker row's "New Group from
  Selection…" (with clicked-vs-selected arbitration), the Groups row's one
  "New Group…", and Cmd-N (a view-local key equivalent on
  `SidebarContainerView`; the editor's ⌘[ back is the same pattern). Both
  menus fire `onRequestRename`/`onRequestDelete`; `MixerWindowController` wires
  them to `focusRenameField()`/`requestDelete()`, unchanged by the move.
- **The editor's way back is a band, Escape, and ⌘[.** The "‹ Groups" band
  tops the editor's scroll DOCUMENT (roadmap 039 is what paid for it — before
  that the pane had no spare points at all) and fires `onBack`; so do
  `cancelOperation` and ⌘[ on the pane's container view. Escape is safe to
  claim unconditionally because a rename in progress consumes it FIRST, in the
  field editor's `control(_:textView:doCommandBy:)`. Seams: `test_goBack()`,
  `test_performBackKeyEquivalent()`.
- **On `.warmPane` the WHOLE membership row is the toggle** (hitTest collapses
  non-checkbox hits onto the row; drag-off cancels; disabled row refuses), and
  hovering the row shows the node's ring. The active group's editor carries a
  "Playing now" badge in the header band and a reassurance caption beside
  "Delete Group…" — beside, not below: both ride inside geometry that already
  existed, so the markers add ZERO height to the pane
  (`theActiveGroupsMarkersAddNoHeightToTheEditorPane`, which reads
  `test_scrollDocumentHeight`).
- **The three pages are four SLOTS in one housing.** Identity (bare,
  parity-locked); Controls — the page's ONE instrument and its only `.card`
  (Equalizer, or the editor's Speakers list); Groups (bare clickable rows);
  About (bare fact rows — Status folds `connectionState` + `isAvailable`, the
  AirPlay row reads `supportsAirPlay2` and is dropped for Bluetooth/This Mac).
  A box is earned by holding a different instrument, never by length. No hint
  line: the footer owns the division of labour. This Mac omits Controls. The
  Equalizer title line carries Reset at the trailing content edge, hidden
  with the slot on This Mac.
- **The sidebar is the FLEET, under one pinned row.** Top to bottom: the
  **Groups** row (group glyph, `bodyEmphasized` label, trailing
  `chevron.right`, gold `speaker.wave.2.fill` marker whenever ANY saved group
  is live), then TWO flat sections — System Audio and Speakers. The Groups row
  is a PLATE (`PlateRowView`, 36 pt): raised fill + hairline edge — the `.card`
  surface vocabulary at row scale, promising the card pane it opens — drawn in
  `drawBackground` so its `Tokens` fills re-resolve per appearance; AppKit's
  own source-list selection draws OVER it, the plate itself never changes with
  selection. The plate is also the divider: no hairline row under it (one
  existed briefly and was removed with the plate). No expand/collapse, no
  nested rows; the Speakers section lists EVERY device (membership is previewed
  in the editor, not by expansion). A `.group(id:)` target passed to
  `select(_:)` lands on the Groups ROW: the editor is pushed inside the content
  pane, and the fleet must never move under the pointer while it is open.
- **The card overview is the group list, and it absorbed the empty state.**
  `GroupsOverviewViewController` draws one card per saved group in a two-column
  grid (its own `GroupsOverviewLayout` constants — deliberately OUTSIDE the
  parity grammar below), the dashed "New Group" tile as the grid's last cell,
  and — at zero groups — a centred canvas instead of a separate pane. It is an
  `NSCollectionView` for what that buys stock: one Tab stop for the whole grid,
  2D arrow keys, and scrolling past ~8 groups. Its `test_*` seams read the
  per-group `CardPlan` computed at rebuild, NOT realized cells — collection
  items only exist once the grid has real size, so a headless run has none.
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
  chrome. The content pane's `panel` fill is `AudioutSharedUI`'s
  `WarmPanelView`.

## Map

| Type | Role |
|---|---|
| `MixerWindowController` | Screen-content controller: owns the split view, sheet flow, auto-select rule; vends `contentController`; visibility via `setHostVisible(_:)`. |
| `ContentPaneHostViewController` | Swapped overview/editor/detail pane + the persistent footer caption. |
| `GroupsOverviewViewController` | The group list: a card grid over `GroupController.groups`, the "New Group" tile, and the absorbed empty state. Own `GroupsOverviewLayout` constants, OUTSIDE the parity grammar. |
| `SidebarViewController` | Source-list: the pinned Groups PLATE row (`PlateRowView`), then System Audio + Speakers, both FLAT; selection drives the content pane. |
| `GroupEditorViewController` | Edit-only pane, pushed from a card: back band, rename, membership toggles, delete. |
| `GroupCreationSheetController` | Standard macOS sheet for new groups; never activates. |
| `DeviceDetailViewController` | Device pane: identity → Equalizer card → Groups → About; icon-edit badge. |
| `MainOutDetailViewController` | Main Audio page: identity → Equalizer card → caption; non-editable well. |
| `IconPickerViewController` | Curated SF Symbol grid + validated search; reports via `onPick`. |
| `MembershipRowView` | Checkbox/node row shared by creation sheet and editor. |
| `DeviceIconWellView` | Large icon + at-rest edit badge (the one approved custom element). |
| `GroupsPaneLayout` | The panes' shared grid constants — the single parity source. |
| `GroupedSectionView` | The one container: `.card` (raised + hairline edge) or `.bare` (inset dividers only). |
| `SidebarSelection` | Enum: `.mainOut`, `.groupsOverview`, `.group(id:)` or `.device(id:)`. `.group` has no row of its own — the cards set it, and the sidebar highlights the Groups row for it. |
