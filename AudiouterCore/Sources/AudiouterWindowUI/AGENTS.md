# AudiouterWindowUI

## Purpose

The "Groups" window — a CONFIGURATION-ONLY host for viewing and editing saved
groups. The window (via `MixerWindowController`) owns a source-list sidebar
(`SidebarViewController`) plus a content pane that swaps between a group
editor (`GroupEditorViewController`), a read-only device detail pane
(`DeviceDetailViewController`), and an empty "No groups yet" pane
(`GroupsEmptyStateViewController`). Selecting a group opens its editor;
selecting a device opens its detail pane; with NOTHING selected the window
AUTO-SELECTS the first saved group (or shows the empty pane when none exist) —
there is no mixer view and no toolbar (live-test feedback 2026-07-18 removed
both; volume control lives only in the popover). **Viewing or editing a group
here never activates it or moves audio** — activation lives in the app's
popover only. All group logic is delegated to the shared `GroupController` in
[../../AGENTS.md](../../AGENTS.md); this module never computes volumes or talks
to a backend directly.

## Rules

- **Configuration-only: sidebar selection ≠ activation.** Clicking a group row
  opens its editor so the user can rename it, add/remove members, or delete it.
  No member becomes active, no audio moves, no Main Out change. Activation
  lives in the popover (`../ AudiouterPopoverUI`), not here.
- **The content pane is swapped, not toggled.** `swapContent(to:)` calls
  `ContentPaneHostViewController.setContent(_:)`, which re-parents the new
  child controller inside the content split item's fixed host (removing the
  old child) — there is no hidden/shown view pair to reach for instead. The
  content `NSSplitViewItem` itself is never removed/re-added anymore (that
  used to also carry the footer along with it; now the footer lives in the
  host and never moves).
- **Persistent footer caption, scoped to the content pane, never
  flag-gated.** `MixerWindowController`'s content split item wraps a
  `ContentPaneHostViewController` — NOT `splitViewController` itself — which
  hosts the swapped editor/detail/empty pane on top and `footerLabel` pinned
  beneath it. The SIDEBAR split item is untouched by any of this and runs the
  full height of the split view down to its own "New Group" bar (design
  review 2026-07-18: the footer used to wrap the WHOLE split view via an outer
  `rootViewController`, which left a gap above it under the sidebar too —
  that outer wrapper is gone; `window.contentViewController` and the public
  `contentController` accessor now vend `splitViewController` directly). The
  footer text ("Set up here — play from the menu-bar icon", stock
  `NSTextField`, `.secondaryLabelColor`, centered, small system font) is
  ALWAYS on screen under the content pane, whether hosted in the standalone
  window or handed to the control-panel shell — it is content, not chrome, so
  `AIRPLAY_CONTROL_PANEL` has no say over it. It teaches the config-vs-playback
  split ONCE as the full sentence; `GroupsEmptyStateViewController.subtitleLabel`
  ("Play groups from the menu bar") is a shorter, lighter echo shown only when
  the empty pane itself is up — don't duplicate the footer's exact wording
  there. Test hook: `test_footerText` (reads through to
  `ContentPaneHostViewController.test_footerText`).
- **This controller only builds the shipping `NSWindow`; the control-panel
  shell is a separate host.** `makeContainer()` always builds the
  document-style window. The control-panel rollout (`AIRPLAY_CONTROL_PANEL=1`)
  does NOT live here — the app hosts this controller's content in the shared
  `ControlPanelWindowController` (in `AudiouterSharedUI`) via the public
  `contentController` accessor (the split view controller). There is no
  `Chrome` enum, no `showPanel`, and no `onClose` on this type anymore — the
  land-home-on-close behavior belongs to the shell. When touching hosting,
  edit the shell, not this controller.
- **`NSWindow.setFrameAutosaveName`'s Bool return does NOT mean "a saved frame
  was restored"** — verified empirically, it returns `true` even for a
  brand-new autosave name with nothing ever saved. `makeContainer()` calls
  `setFrameUsingName` first (the trustworthy restore-and-report API), then
  `setFrameAutosaveName` only to arm future autosave-on-move. `init()` gates
  its default-size/`center()` fallback on that Bool — trusting the wrong one
  silently re-centers over every restored frame on every launch, a regression
  invisible to a same-session move/close/reopen smoke test because
  `AppDelegate` builds this controller once and reuses it.
- **The create sheet gates on the split VC's OWN host window, not
  `self.window`.** `presentCreateSheet` presents on `splitViewController` and
  guards `splitViewController.view.window?.isVisible`, so the sheet re-parents
  correctly whether the content sits in the standalone window OR the shell's
  panel (where `self.window` is off screen and would be the wrong window to
  consult). Headless runs (host never shown) keep the sheet reference and
  drive it through the `test_*` hooks.
- **Group creation moved to a sheet.** The old in-pane draft flow is gone.
  `GroupCreationSheetController` is a standard macOS sheet (`presentAsSheet`)
  that never activates a group — the caller selects the resolved group and
  opens its editor.
- **The sidebar always shows the Groups section** (design revamp: this window
  is groups-configuration only). When empty it displays "No groups yet"
  (a non-selectable placeholder), plus a labeled "New Group" button at the
  bottom. The Devices section appears whenever there is at least one device.
- **`SidebarViewController.viewDidAppear()` seeds Tab-key traversal for the
  WHOLE window (A11Y-GROUPS), not just the sidebar.** A live test found Tab
  did nothing anywhere in this window; root cause was that nothing in the
  window's lifecycle ever calls `NSWindow.makeFirstResponder(_:)` (not even
  the sidebar's own programmatic auto-select — only a real click promotes
  first responder), so a freshly-shown window has no key view for Tab to
  advance from. Don't remove this override as apparently-dead code — it only
  fires on a genuine on-screen appearance (never under `swift test`/harness
  runs, so it's invisible to headless coverage) and is the one thing that
  makes Tab work at all. Known gap: it doesn't re-seed after the content pane
  swaps (`MixerWindowController.swift`'s `ContentPaneHostViewController` —
  out of scope where this was fixed) — if a future live retest finds Tab
  breaks specifically after switching panes, look there first.
- **Both sidebar sections are FLAT — no expand/collapse, no nested rows**
  (design review 2026-07-18). A group row is a single leaf row: icon (in the
  SAME icon column as a device row) + name, no disclosure chevron, no
  member-device children under it — `SidebarViewController.Node.Payload.group`
  carries no `children` anymore. Previewing a group's members happens in
  `GroupEditorViewController`'s own "Speakers" checklist, not by expanding the
  sidebar row, so the old nesting was pure duplication. Consequently the
  **Devices section now lists EVERY device**, grouped or not — the old filter
  that hid a device because it belonged to the (never-set, in this
  config-only window) active group is gone; hiding a device here would make
  it unreachable now that membership isn't previewed via expansion. Test
  hooks: `test_groupRowCount`, `test_deviceRowCount` (was
  `test_ungroupedDeviceRowCount`), `test_groupRowsAreFlat`. There is no more
  `test_memberIDs(underGroup:)` — nothing to assert, group rows have no
  children.
- **`GroupEditorViewController` is edit-only.** It shows an already-persisted
  group, allows renaming and membership edits, and can delete it. Group
  creation (`GroupCreationSheetController`) is a separate, parallel flow.
- **`MembershipRowView` is a shared checklist row.** Used by both the
  creation sheet and the group editor to present devices as a checkbox list
  (memberships, not routing). When shown in the group editor's membership
  checklist (`Surface.warmPane`), the checkbox becomes an invisible cell +
  gold `MembershipBusView` node, tied together by a `BusRailOverlayView`
  rail hooked out of the group's icon well; in the "New Group" creation
  sheet (`Surface.systemSheet`), it stays a plain stock checkbox row. The
  popover's `DeviceRowView` remains the routing-and-volume row; never
  conflate them. Gold on the warm pane measures too low contrast (≈2.3-2.5:1)
  against the system sheet's white background, so this split confines the
  gold to where the background can support it.
- **`GroupedSectionView` is this window's ONE section shape**, in its own file
  (it used to be `private` inside the editor) so both panes share it rather
  than growing look-alikes: a rounded `Tokens.Color.well` fill,
  `Tokens.Color.hairline` border, and inset hairline dividers between adjacent
  rows — a section holding fewer than two rows draws none, which is what lets
  it also serve as the plain header container. The editor uses two (header +
  membership list); the detail pane uses three (header + device state + "In
  groups"). Its `contentLeadingInset` is always
  `GroupsPaneLayout.contentLeadingInset`, so the dividers start where the
  content does. `GroupsWindowTextColorLockTests` samples the editor's real
  drawn fill/divider through reflection on the stored property named
  **`membershipWell`** — renaming that property breaks the test's reach.
- **The content column is ELASTIC, with two anchoring traps.** Both panes give
  the column symmetric margins (`PopoverColumnGrid.leadingInset` /
  `.trailingInset`, 14 each) and let it STRETCH to the pane — a high-priority
  "fill" constraint out to the trailing margin, stopped by a required
  `<= GroupsPaneLayout.contentMaxWidth` cap. Before this the sections hugged
  their ~277pt intrinsic content (the widest device name plus a permanently
  reserved "Unavailable" label) and left a dead strip beside them; rows now
  fill the section so a trailing annotation lands on the section's own edge.
  Two things break SUBTLY the moment the column takes its own margin, because
  both used to be pinned to the CONTAINER and were only accidentally right:
  (1) `railOverlay` must be re-pinned to the COLUMN, or the spine and the
  nodes separate by exactly the margin — `test_nodeCenterXInOverlaySpace` is
  the guard, and it must equal `PopoverColumnGrid.railGutterCenterX`;
  (2) the "Delete group…" button's leading anchor must be re-based to the
  column, or it drifts one margin left of everything it sits under.
- **The editor pane has NO scroll view, so its fitting height is a hard
  budget — and the budget is NOT the window's height.** The window is
  `.fullSizeContentView`, so the pane starts at its SAFE AREA (the title bar,
  ~32pt) and the persistent footer strip (~28pt) comes off the bottom: a
  content pane gets `MixerWindowController.defaultContentSize.height` minus
  both. A guard that compares against the whole window height passes while the
  pane overflows — which is exactly what happened: the pre-fix editor wanted
  484pt of a 445pt budget (39pt of list and the "Delete group…" button below
  the window's edge) and the old `<= 505` assertion was green. Assert against
  `test_titleBarHeight` + `test_contentPaneChromeHeight`, both measured off
  the real window (`MembershipRailTests
  .testEditorFitsTheHeightTheWindowActuallyGivesIt`).
- **Window defaults live in `MixerWindowController`, once each.**
  `defaultContentSize` is 560×505 (narrowed from 720 when the panes became
  elastic), `minimumContentSize` is 480×420, and the sidebar is capped at
  `maximumThickness = 260`. `defaultFrameAutosaveName` was BUMPED to
  `"MixerWindow-v2"` in the same change: an existing install has a frame saved
  under the old key and would keep opening at its old size forever, so the new
  default would never be seen. Bump it again if a future default change must
  reach existing installs — and expect exactly one such adoption per bump.
- **No toolbar, no volume UI.** The window mounts no `NSToolbar` at all —
  the master slider left with the mixer pane (live-test feedback 2026-07-18).
  Anything that changes what you HEAR belongs in the popover.
- **Auto-select, never a no-op pane.** With no sidebar selection the window
  selects the first saved group's editor; with zero groups it shows
  `GroupsEmptyStateViewController` ("No groups yet" + a New Group button that
  runs the same creation sheet). The empty-state subtitle is "Music first —
  rooms can come later."
- **Header parity is GEOMETRIC, and lives in `GroupsPaneLayout`.**
  `GroupEditorViewController` and `DeviceDetailViewController` swap places
  behind one sidebar, so their headers must land on the same pixels: same
  icon-well x, same title x and vertical centre, same 92pt band height
  (`GroupsPaneLayout.headerBandHeight` = `headerPadding` + `DeviceIconWellView
  .size` + `headerPadding`). Every shared number — `columnInset`,
  `contentLeadingInset`, `contentMaxWidth`, `headerPadding`, `iconToTitleGap`
  — is read from that one enum rather than copied; the two panes carried
  hand-copied literals once and drifted ~22.5pt apart, which made switching
  sidebar selection jump the header sideways. `GroupsHeaderParityTests`
  asserts the real laid-out frames, not the constants, so a new constraint
  that quietly wins can't pass it.
- **The header is SIDE BY SIDE: icon BESIDE name, not above it** (design
  review 2026-07-25). Stacking cost 30pt on a pane that was already
  overflowing its own window. Because the two now share one horizontal band,
  the rail's origin hook is back on the ICON WELL (`railHookAnchor`) — hooking
  the icon hooks the name's line, and the well is a fixed 64pt tile rather
  than a field whose width changes with the name it holds.
- **Edit-affordance vocabulary: bordered + pencil = editable, bare =
  read-only.** A group's name is renameable, so it wears the
  `WarmNameFieldCell` skin (raised fill, hairline border, trailing pencil); a
  device's name is not, so it is a plain label at the identical geometry. The
  decoration IS the message — the same rule the icon wells already run (the
  device *icon* is editable, so it wears a pencil badge). Don't decorate a
  read-only string, and don't strip the field's skin to "match" the detail
  pane. The two pencils share `PopoverColumnGrid.editAffordanceRestAlpha` /
  `editAffordanceHoverAlpha` so the header's two cues can't drift.
- **The rename field is a REAL `NSTextField`; only its drawing is ours.**
  `WarmNameFieldCell` (in `AudiouterSharedUI`) is swapped in the way
  `MembershipRowView` swaps `InvisibleSwitchCell` — cell FIRST, configuration
  after. Behaviour contract, all covered by `GroupRenameFieldTests`: Return
  commits · focus loss commits · **Escape reverts** to the pre-edit name
  (routed through `control(_:textView:doCommandBy:)`; it did nothing before) ·
  **emptying restores the previous name into the field** (the rename was
  already refused, but the field was left blank while the group kept its old
  name — the UI lied) · first focus selects all, Finder-style · hover changes
  drawing only, never geometry (R7).
  An editable `NSTextField` has NO intrinsic width, so the width is three
  constraints, not one: a REQUIRED `>= 140` floor (a bare `<=` cap collapses
  it to zero — it rendered invisible once, snapshot-caught 2026-07-18), a
  hand-MEASURED "hug the name" width, and a 999-priority `<=` cap against the
  section's inset edge (it used to be a FIXED 260 that hung ~21pt past its
  section). The measured width sits BELOW `.defaultLow`: at a normal priority
  a long group name was satisfied by growing the whole content pane, which
  squeezed the sidebar past its own minimum thickness. Same reason
  `DeviceDetailViewController`'s name label and view-only hint have lowered
  compression resistance — in this window, text truncates; it never moves
  furniture.
- **No synthesized clicks in headless runs.** Every controller exposes
  `test_*` methods mirroring a real UI action; add one for any new
  user-facing action or it becomes untestable outside a live window.
- **Depends on the model, never the reverse.** No backend types are
  imported; everything comes through `GroupController` or `update(devices:)`.
- **`DeviceDetailViewController` is read-only, and CONFIGURATION-ONLY like the
  rest of this window.** Selecting a device in the sidebar shows this pane
  instead of the mixer; it only ever renders a `Device` snapshot (name,
  status, availability, volume, kind) plus which saved groups it belongs to
  (via the injected `GroupController`). No slider, no mute, no Selected-
  Devices toggle, no group-activation control lives here. Its metadata sits in
  two `GroupedSectionView`s (device state, then "In groups"), captions
  leading and values RIGHT-ALIGNED into a real column that uses the section's
  width — the old fixed 90pt caption column stranded them mid-pane, and the
  stock `NSBox` separator between the two groups is gone (it drew a rule that
  stopped a third of the way across). `test_hasBoxDivider` keeps it gone.
- **The icon-edit badge is the one approved custom-drawn element**
  (`../../AGENTS.md`) — `DeviceIconWellView`, shared by exactly two hosts:
  `DeviceDetailViewController` and `GroupEditorViewController` (header
  parity). ONE affordance, not two (live-test feedback 2026-07-18b): a small
  faint circular pencil badge sits in the well's bottom-trailing corner AT
  ALL TIMES (discoverable without a hover) and steps up in alpha when the
  pointer enters — through `setOverlayVisible(_:)`, which honors Reduce
  Motion (instant vs. a brief fade). The earlier full-coverage hover scrim
  was REMOVED — a persistent badge plus a separate full-cover pencil-on-hover
  read as two conflicting affordances. The whole well is the click target
  (camera-badge pattern: badge is the cue, glyph is the button); clicking
  presents `IconPickerViewController` as an anchored popover, and picking a
  symbol (or "use default") writes through `DeviceIconController` (devices)
  or `saveGroup` (groups). Do not copy this custom-drawn pattern anywhere else.
  Being a bare `NSView` (A11Y-GROUPS), it gets none of `NSButton`'s free
  keyboard/VoiceOver support — `acceptsFirstResponder`, Space/Return in
  `keyDown(with:)`, and `accessibilityPerformPress()` are hand-rolled;
  preserve all three in any future change here.
- **`IconPickerViewController` has no opinion on presentation.** It only
  builds a curated grid (`DeviceIcon.curated`, filtered through
  `DeviceIcon.isValid` so a stale curated name never renders a blank glyph)
  plus one search field doing double duty, and a "Use default icon" button.
  The search field (a) LIVE-FILTERS the curated grid by case-insensitive
  substring match on every keystroke — empty text shows the full curated
  set, a non-matching search shows an empty grid with a plain "No matches"
  label (never a crash) — AND (b), independently, validates the typed text
  live as an EXACT SF Symbol name against `DeviceIcon.isValid` for a preview
  + Apply gate (invalid/empty disables Apply). Both behaviors run off the
  same keystroke and coexist: a user can type a partial name to browse the
  narrowed grid and tap a result, or type a full valid name and hit Apply
  directly — narrowing the grid never disables or replaces the exact-name
  path. Icons shown are monochrome only — no color-picking, matching the
  house rule. Every path funnels through `onPick`; the caller (icon well in
  the group editor, creation sheet, or `DeviceDetailViewController`)
  presents it as an anchored `NSPopover` and persists the result.
- **`DeviceIcon` is the single resolution point for "what SF Symbol
  represents this device/group."** `DeviceIcon.resolve(_:default:)` is the
  render-time fallback every row/detail/icon-well caller uses instead of its
  own nil-check-plus-validate dance — an override that's gone stale (renamed
  or removed symbol on a newer/older OS) falls back to the kind/group default
  rather than a blank glyph. `DeviceIconController` (in `AudiouterSharedUI`)
  is the only place a per-device override is looked up or written, backed by
  `DeviceIconStore` (in `AudiouterCore`); only the bare symbol name string is
  persisted, never the resolved image.
- **`Group.iconSymbolName` is optional and required no schema bump** — `nil`
  decodes cleanly from any pre-existing persisted group and means "use
  `Group.defaultIconSymbolName`." The popover's `GroupRowView` and this
  window's sidebar/editor/creation-sheet icon wells all resolve it through
  the same `DeviceIcon.resolve(_:default:)` path as device overrides, so a
  group icon and a device icon never fall back differently.
- **Text colors are frozen; contrast lifts from surfaces, not hue.** The
  entire Groups window uses Apple's stock semantic text colors
  (`.secondaryLabel`, `.tertiaryLabel`) everywhere — no warm-tinted text
  anywhere. Contrast improvements in the Warm Signal redesign come ONLY from
  new surface layers (the well, hairlines, sidebar tint) — never from text
  color changes — a locked tradeoff accepted by Alec. Light-mode secondary/
  tertiary text stays below common readability floors (≈3:1 ceiling), but
  changing it to warm text risked breaking cohesion with other AppKit panes
  and other apps. This is not an oversight; don't "fix" it back to warm text
  without re-confirming the decision.

## Map

| Type | Role |
|---|---|
| `MixerWindowController` | Owns `NSWindow` (no toolbar), split-view, sheet; swaps content between editor/detail/empty panes inside `ContentPaneHostViewController`; auto-select rule. Exposes `contentController` (the split view controller) so the shared control-panel shell can host the same content. |
| `ContentPaneHostViewController` | Wraps the swapped editor/detail/empty pane plus the persistent footer caption, scoped to the content split item only — the sidebar item is untouched and runs the full split-view height. |
| `GroupsEmptyStateViewController` | "No groups yet" empty state: primary message + secondary subtitle ("Play groups from the menu bar") + New Group call-to-action. |
| `SidebarViewController` | Source-list (Groups + Devices sections), both FLAT (no expand/collapse, no nested rows); selection drives the content pane. |
| `GroupEditorViewController` | Edit-only pane: rename, membership toggles, delete; no creation flow. |
| `GroupCreationSheetController` | Standard macOS sheet for new groups; never activates. |
| `DeviceDetailViewController` | Read-only device detail pane (name, status, volume, kind, groups); the one approved custom-drawn icon-edit badge lives on its icon well. |
| `IconPickerViewController` | Curated SF Symbol grid + validated free-text search, presented as an anchored popover; reports a symbol name via `onPick`. |
| `MembershipRowView` | Checkbox + icon + name row used in creation sheet and editor. |
| `DeviceIconWellView` | Shared large icon + at-rest edit badge (the one approved custom element; no hover scrim); used by editor + detail headers. Its badge alphas come from `PopoverColumnGrid.editAffordanceRestAlpha`/`HoverAlpha`, shared with the rename field's pencil. |
| `GroupsPaneLayout` | The content panes' shared grid: column margins, width cap, content inset, header padding/gap, derived header band height. The single source both panes read, so header parity can't drift. |
| `GroupedSectionView` | This window's one grouped-section container (`well` fill, `hairline` border, inset row dividers). Used by the editor (header + list) and the detail pane (header + state + groups). |
| `SidebarSelection` | Enum: `.group(id:)` or `.device(id:)`. |
