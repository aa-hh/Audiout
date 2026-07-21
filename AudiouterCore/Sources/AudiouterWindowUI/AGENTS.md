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
  (memberships, not routing). The popover's `DeviceRowView` remains the
  routing-and-volume row; never conflate them.
- **No toolbar, no volume UI.** The window mounts no `NSToolbar` at all —
  the master slider left with the mixer pane (live-test feedback 2026-07-18).
  Anything that changes what you HEAR belongs in the popover.
- **Auto-select, never a no-op pane.** With no sidebar selection the window
  selects the first saved group's editor; with zero groups it shows
  `GroupsEmptyStateViewController` ("No groups yet" + a New Group button that
  runs the same creation sheet).
- **Header parity between groups and devices.** `GroupEditorViewController`
  and `DeviceDetailViewController` share the identical large-icon header —
  the same `DeviceIconWellView` (size, edit badge, click-to-pick) — the only
  difference being that a group's title is an EDITABLE borderless field
  (commits like a Finder rename) while a device's title is a static label.
  An editable `NSTextField` has no intrinsic width: the title uses a FIXED
  width constraint, not a `<=` cap (a cap alone collapses it to zero).
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
  Devices toggle, no group-activation control lives here.
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
| `DeviceIconWellView` | Shared large icon + at-rest edit badge (the one approved custom element; no hover scrim); used by editor + detail headers. |
| `SidebarSelection` | Enum: `.group(id:)` or `.device(id:)`. |
