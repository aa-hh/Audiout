# Accessibility audit — VoiceOver, keyboard, contrast (Phase 3 Task A6)

## Method

Static code audit only — no live app launches, no VoiceOver session (this
worktree is read-only, no audio sessions). Read the repo-root `AGENTS.md`,
then `AudioutCore/AGENTS.md` and the `AGENTS.md` nearest every package
touched (`AudioutSharedUI`, `AudioutPopoverUI`, `AudioutWindowUI`,
`AudioutSettingsUI`). Then, for every custom-drawn or composite view named
in the brief plus everything each package's `AGENTS.md` "Map" section lists:
read the full source, `git grep`'d for `setAccessibility*` / `isAccessibility*`
/ `mouseEntered` / `mouseDown` / `acceptsFirstResponder` / `keyDown` across
`AudioutCore/Sources`, and cross-checked every hover-only visual cue against
whether the same action is also reachable through an always-present control.

Two names in the brief don't exist verbatim in source — `ControlCenterSlider`
is just a plain `NSSlider` styled per-row (no subclass), and
`HoverActionButton` doesn't exist as a class; the closest matches are
`ThemeTileButton` (a real `NSButton` subclass) and `DeviceIconWellView` (a
plain `NSView`, see Critical-1). Per house rule ("docs orient, code
decides"), this audit follows the source, not the brief's guessed names.

Genuinely live-only questions (does VoiceOver actually skip an unlabeled
subview, does Esc actually close a given window, does a segmented control's
per-segment label win over the control-level label) are tagged
`[confirm-in-G1]` throughout rather than asserted from code alone.

## Per-view a11y coverage map

| View | Role + label exposed? | State conveyed (non-visually)? | Keyboard path? | file:line |
|---|---|---|---|---|
| `DeviceRowView` | Yes — `.group`/`.menuItem`, composed label (name, membership, volume, connection state, AP1) | Yes — connection state is a spoken clause | Yes — checkbox/slider/mute are real controls; name-click and unsupported-row click are mouse-only *conveniences* layered on an already-accessible primary control | `AudioutSharedUI/DeviceRowView.swift:1114` |
| `AppRowView` | Yes — `.group`, label = "name, volume X percent" | Partial — destination and "not running" omitted from the row's own label (reachable by tabbing into the destination popup; offline badge has no label anywhere) | Yes — richest in the codebase: `acceptsFirstResponder`, body-click select, Up/Down move, Delete/Backspace remove, all via `NSStandardKeyBindingResponding` overrides | `AudioutSharedUI/AppRowView.swift:826`, offline badge: `:434` |
| `GroupRowView` | Yes — `.button` on the row, but press is unwired (no `accessibilityPerformPress`/`acceptsFirstResponder`) | Yes — "active/inactive, expanded/collapsed, master volume" in the label | Yes, but only via the real `activateButton`/`chevronButton`/`muteButton`/`masterSlider` children — the row's own advertised `.button` role has no confirmed activation path | `AudioutPopoverUI/GroupRowView.swift:374` |
| `MainOutRowView` | Yes — `.group`, label + slider label + popup label/value | Yes | Yes — every control is stock (`NSSlider`/`NSButton`/`NSPopUpButton`) | `AudioutPopoverUI/MainOutRowView.swift:380` |
| `StatusDotView` | No (by design — relies on the host row's composed label) | Color/motion-only for its *own* value (see Major-1); the state is separately spoken via the host row's label | N/A (non-interactive) | `AudioutSharedUI/StatusDotView.swift:32` |
| `LevelMeterView` | No (decorative, `hitTest` → nil) | No live-playback-activity signal exists anywhere else either (see Minor-2) | N/A (non-interactive) | `AudioutSharedUI/LevelMeterView.swift:32` |
| Card collapse header (`PopoverPanelViewController.beginCard`) | Yes — real `NSButton` chevron, dynamic "Expand/Collapse `<title>`" label | Yes | Yes — chevron is a real control; whole-header click is a bonus on top of it | `AudioutPopoverUI/PopoverPanelViewController.swift:322`, `:499` |
| `ConnectionDiagnosisView` | Yes — group label + 3 labeled buttons | Yes | Yes — real buttons | `AudioutPopoverUI/ConnectionDiagnosisView.swift:247` |
| `PopoverHeaderView` | Yes — group label + 3 labeled/tooltipped icon buttons | N/A | Yes | `AudioutPopoverUI/PopoverHeaderView.swift:175` |
| `ApplicationsFooterView` (± control) | Yes — control-level label + per-segment image descriptions | Yes (enabled/disabled) | Yes — `NSSegmentedControl` | `AudioutPopoverUI/PopoverController.swift:36-68` |
| `IconPickerViewController` (grid/search/Apply) | Yes, but grid cells speak the raw SF Symbol identifier (see Minor-3) | Yes | Yes — every element is a real control | `AudioutWindowUI/IconPickerViewController.swift:176-193` |
| `DeviceIconWellView` (icon-edit affordance) | Yes — `.button`, "Edit icon" label | N/A | **No** — plain `NSView`, `mouseDown`-only, no `acceptsFirstResponder`/keyDown/press override, and it is the *only* entry point into the icon picker | `AudioutWindowUI/DeviceIconWellView.swift:95-97`, `:117` |
| `PermissionRowView` (onboarding) | Yes — entirely stock controls, each status (Allow/Allowed/Requested/Denied/Unsupported) gets its own labeled icon+text | Yes | Yes — real `NSButton`s throughout | `AudioutOnboardingUI/PermissionRowView.swift` (whole file) |
| `ThemeTileButton` (Appearance theme picker) | Partial — real `NSButton` + `theme.displayName` label, but selection state isn't announced (see Minor-1) | No — "currently selected" isn't in the accessibility tree | Yes — real `NSButton`, target/action | `AudioutSettingsUI/AppearanceSettingsViewController.swift:78-99` |
| Excluded-apps rows (`AudioSettingsViewController`) | Yes — add/remove buttons individually labeled, always visible | N/A | Yes | `AudioutSettingsUI/AudioSettingsViewController.swift:449-500` |
| `GeneralSettingsViewController` (launch-at-login) | Yes | Yes (native switch) | Yes | `AudioutSettingsUI/GeneralSettingsViewController.swift:35` |
| `SidebarViewController` (Groups/Devices list) | Yes — stock `NSOutlineView` | Yes | Yes — native arrow-key/VO rotor navigation | `AudioutWindowUI/SidebarViewController.swift:76` |
| `MembershipRowView` | Yes — dynamic "Add/Remove `<device>` … group" label | Yes | Yes — real checkbox | `AudioutWindowUI/MembershipRowView.swift:158-161` |
| `ControlPanelWindowController` (shared panel shell, flag-gated) | N/A (window chrome, not a control) | N/A | Unclear — native close button is force-hidden and no `cancelOperation`/Escape wiring found (see Major-2) | `AudioutSharedUI/ControlPanelWindowController.swift:102` |
| Status item → popover open/close | Yes — stock `NSStatusItem`/`NSStatusBarButton`; popover uses `.behavior = .transient` (Escape/outside-click close is an AppKit default) | Yes | Yes — standard macOS menu-bar-extra keyboard/VO navigation, not app code | `AudioutApp/AppDelegate.swift:194-195`, `AudioutPopoverUI/PopoverController.swift:362` |

**Coverage summary:** 12 views/surfaces fully covered, 5 partial (`AppRowView`,
`GroupRowView`, `StatusDotView`, `ThemeTileButton`, `IconPickerViewController`'s
grid labels), 2 with a real functional gap (`DeviceIconWellView`,
`ControlPanelWindowController`'s closability) — plus `LevelMeterView`, which is
intentionally non-interactive/decorative and is counted separately below.

---

## Findings

### Critical

**C1 — The device/group icon picker cannot be opened without a mouse.**
The large icon in the Groups editor header and the Device Detail pane is how
you change a device's or group's icon. Clicking it opens the icon picker.
That click handler lives on a plain, non-button view with no keyboard
equivalent at all — a keyboard-only user or a VoiceOver user has no way to
reach the icon picker, full stop. Every other click affordance in the app has
a fallback (a real button, a menu item, arrow keys); this one doesn't.
Evidence: `AudioutCore/Sources/AudioutWindowUI/DeviceIconWellView.swift:44`
(`final class DeviceIconWellView: NSView`, not `NSButton`), `:117`
(`override func mouseDown(with event: NSEvent) { onClick?() }` — the sole
trigger), `:95-97` (accessibility is *labeled* `.button` but nothing wires a
press action), and the two callers that only ever set `.onClick`:
`AudioutWindowUI/GroupEditorViewController.swift:104-106`,
`AudioutWindowUI/DeviceDetailViewController.swift:95-96`.
Fix direction: back the well with a real `NSButton` (image-button covering
the whole well, exactly like `ThemeTileButton` already does elsewhere in this
codebase), or at minimum add `override var acceptsFirstResponder: Bool { true }`
plus a Space/Return `keyDown` and an `accessibilityPerformPress()` override
that call the same `onClick` closure.

### Major

**M1 — Connection status is conveyed by dot color alone for its most common
transition.** The on-icon status badge is a plain filled circle that changes
color only: gray-and-pulsing while connecting/reconnecting, solid green when
connected, solid orange when failed, teal for an advanced "routing but not
selected" case — same shape every time, no icon or pattern difference. The
`.failed` case has a safety net (visible "Couldn't connect" text, and
VoiceOver hears the state as part of the row's spoken label), but the
everyday connecting→connected transition has no textual backup at all — a
device that's "System"-selected and mid-connect reads exactly like one that's
already connected and playing, distinguishable only by the dot's gray-vs-green
hue and a subtle pulse. This is the classic WCAG "use of color" trap, worse
for colorblind or low-vision users glancing at an 8pt dot.
Evidence: `AudioutCore/Sources/AudioutSharedUI/StatusDotView.swift:107-130`
(the fill-color switch is the only differentiator), and
`AudioutSharedUI/DeviceRowView.swift:416-426` (`resolveSublabel`'s
precedence ladder has no "Connecting…" branch — a connecting, selected device
falls straight into the routing-line branch and just shows "System").
Fix direction: add a shape/glyph cue (e.g., an outlined vs. filled dot) or a
brief "Connecting…" sublabel state, so the distinction survives without color.
`[confirm-in-G1]`: verify VoiceOver doesn't also land on the bare, unlabeled
`StatusDotView` subview itself as a separate silent stop.

**M2 — The floating control-panel shell hides its close button with no
confirmed alternative.** `ControlPanelWindowController` (the shared panel
used to host Groups/Settings/Setup behind `AIRPLAY_CONTROL_PANEL=1`) explicitly
hides the native red traffic-light close button and relies on "✕ / Esc /
performClose" per its own doc comments — but no Escape/`cancelOperation`
wiring exists anywhere in the file, and the visible ✕ is the very thing that
was hidden. This flag is OFF by default today (`AppDelegate.useControlPanel`),
so it does not affect the shipping paid build, but it's live code that could
ship later without a verified way to dismiss the panel for anyone who isn't
clicking outside it with a mouse.
Evidence: `AudioutCore/Sources/AudioutSharedUI/ControlPanelWindowController.swift:102`
(`panel.standardWindowButton(.closeButton)?.isHidden = true`), no
`keyEquivalent`/`cancelOperation` hits anywhere in that file;
`AudioutApp/AppDelegate.swift:143` (flag gate, off by default).
`[confirm-in-G1]` — this needs a live keyboard/VO check before the flag is
ever turned on for a release; the code alone doesn't prove Escape works or
fails.
Fix direction: wire an explicit `cancelOperation(_:)` → `performClose(_:)`
path (or un-hide the close button) before this ships as the default shell.

**M3 — The per-app routing row doesn't tell VoiceOver where an app is routed
or whether it's still running.** `AppRowView`'s composed accessibility label
is just "`<app name>`, volume X percent" — a sighted user also sees the
destination dropdown's current text and, when the app has quit, a small
warning badge on the icon; neither reaches the row's own label. A VoiceOver
user has to tab one control further (into the destination popup) to learn
where audio is going, and has no way at all to learn "this app isn't running"
— the offline badge's `NSImage` carries an `accessibilityDescription` but
nothing surfaces it as a label on the badge view or folds it into the row.
Evidence: `AudioutCore/Sources/AudioutSharedUI/AppRowView.swift:826-832`
(`configureAccessibility` — no destination, no running-state), `:434-439`
(`offlineBadge` — image has a description, view has none).
Fix direction: mirror `DeviceRowView`'s `stateClause` pattern — append the
current destination title and an "not running" clause to the row's own label.

### Minor

**N1 — The Appearance theme picker doesn't announce which theme is
selected.** `ThemeTileButton` is a real, keyboard/VoiceOver-reachable
`NSButton`, and each tile is labeled with its theme name ("Light", "Dark",
"Match System") — but "currently selected" lives only in a custom
`isSelectedTile` flag that drives a hand-drawn accent ring, never in
`NSButton.state` or an explicit `accessibilityValue`. A VoiceOver user
tabbing through the three tiles hears three identically-phrased buttons with
no indication of which one is active.
Evidence: `AudioutCore/Sources/AudioutSettingsUI/AppearanceSettingsViewController.swift:86`
(label set once, at creation, to just `theme.displayName`) and
`:136-138`/`:95-99` (`isSelectedTile` never touches `button.state` or
accessibility).
Fix direction: set `tile.setAccessibilityValue(isSelected ? "Selected" : nil)`
(or flip `NSButton.state`) inside `applySelectionHighlight()`.

**N2 — No non-visual signal for "is audio actually reaching this device right
now."** `LevelMeterView` (the VU meter) is deliberately non-interactive and
carries no accessibility surface — reasonable on its own, since VoiceOver
users don't typically want a live-updating numeric readout. But there's
currently no substitute anywhere: connection state and volume % tell you
"selected and at 40%," not "sound is actually flowing." Low severity —
flagging for awareness, not urging a fix for v1.
Evidence: `AudioutCore/Sources/AudioutSharedUI/LevelMeterView.swift`
(no `setAccessibility*`/`isAccessibilityElement` calls anywhere in the file).

**N3 — Icon-picker grid buttons speak raw SF Symbol identifiers.** Each
curated icon in `IconPickerViewController`'s grid is a real, reachable
`NSButton`, but its accessibility label is the literal symbol name (e.g.
`"hifispeaker.2.fill"`) rather than a plain-language description — functional,
but reads as engineering jargon to a VoiceOver user browsing icons by ear.
Evidence: `AudioutCore/Sources/AudioutWindowUI/IconPickerViewController.swift:185`
(`accessibilityDescription: name` where `name` is the raw curated symbol
string).
Fix direction: maintain a small `[String: String]` display-name lookup for
`DeviceIcon.curated` and use it for the label, keeping the symbol name as the
tooltip (already the case).

**N4 — `GroupRowView` advertises a `.button` role it can't actually press.**
The whole group row sets `setAccessibilityRole(.button)` and a rich label,
but never overrides `accessibilityPerformPress()` and never opts into
`acceptsFirstResponder` — so a VoiceOver user who lands on the row itself
(rather than its child chevron/activate buttons) and tries to "press" it
likely gets no response. Every actual action the row offers (expand/collapse,
activate, mute, master volume) is separately reachable through its own real
`NSButton`/`NSSlider` child, so this doesn't block anything — it's a labeling
promise the view doesn't keep.
Evidence: `AudioutCore/Sources/AudioutPopoverUI/GroupRowView.swift:374-385`
(`configureAccessibility` sets `.button` with no press wiring anywhere in the
file).
`[confirm-in-G1]` — live VoiceOver check of "press" on the row body.
Fix direction: either wire `accessibilityPerformPress()` to the same
`groupRowToggleExpansion` call `mouseDown` uses, or drop the role to `.group`
to stop over-promising.

**N5 — The per-app-routing sublabel is the smallest, lowest-contrast text in
the popover despite being load-bearing.** `DeviceRowView`'s "System ·
`<AppName>`" line — the only place a user learns which apps are currently
routed to a given speaker — renders at an explicit `10pt` in
`.secondaryLabelColor`, smaller than the app's own smallest named system size
(`NSFont.smallSystemFontSize`, ~11pt) used everywhere else for genuinely
secondary text (the `%` readouts).
Evidence: `AudioutCore/Sources/AudioutSharedUI/DeviceRowView.swift:542-543`
(`statusLabel.font = .systemFont(ofSize: 10)`).
`[confirm-in-G1]` — a rendered-contrast check against the popover's `.menu`
material in both light and dark is a visual-audit question, not a code-read
one.
Fix direction: bump to `NSFont.smallSystemFontSize` to match every other
secondary line in the row.

### Nit

**T1 — No support for "Differentiate Without Color" or "Increase Contrast."**
Zero occurrences anywhere in `AudioutCore/Sources` of
`accessibilityDisplayShouldDifferentiateWithoutColor` or
`accessibilityDisplayShouldIncreaseContrast` (confirmed by repo-wide grep,
alongside the Reduce-Motion checks which ARE present throughout). Wiring
"Differentiate Without Color" would directly resolve M1 for the subset of
users who've already told macOS they need it.

**T2 — Header icon buttons (Groups editor / Settings / Quit) are borderless
until hovered.** `showsBorderOnlyWhileMouseInside = true` means the rounded
bezel outline is invisible at rest — the glyph itself is always visible and
the buttons are always clickable/keyboard-focusable, so nothing is actually
blocked, but a low-vision user scanning for "where are the buttons" gets a
weaker cue than Settings/Quit deserve.
Evidence: `AudioutCore/Sources/AudioutPopoverUI/PopoverHeaderView.swift:140`.

**T3 — Fixed point-size fonts throughout, no Dynamic-Type-style scaling.**
Standard and expected for a Control-Center-style menu-bar utility — Apple's
own Control Center doesn't scale with the system Text Size setting either —
so this is a platform-appropriate choice, not a defect. Noting only because
the brief asked for an explicit check.

**T4 — `ApplicationsFooterView`'s ± control sets one label for the whole
`NSSegmentedControl`** ("Add or remove application") in addition to each
segment's own image `accessibilityDescription` ("Add application" /
"Remove application"). `[confirm-in-G1]`: whether VoiceOver announces the
per-segment description or the control-level label when focus lands on an
individual segment — stock `NSSegmentedControl` behavior, low risk either way.
Evidence: `AudioutCore/Sources/AudioutPopoverUI/PopoverController.swift:60-68`.

---

## What's already solid (context for the severities above)

Worth stating plainly so the findings above don't read as "the app has no
accessibility": coverage here is good, and two classic traps are already
fixed on purpose, per the surrounding `AGENTS.md`/doc-comment history —

- The old **hover-only ✕ remove button** on device rows was deliberately
  removed in favor of the always-visible `ApplicationsFooterView` ± control,
  a context-menu item, and Delete/Backspace — all three keyboard-reachable.
- The old **full-coverage hover-only pencil scrim** on the icon well was
  deliberately replaced with an always-at-rest-visible badge (2026-07-18b
  live-test feedback) specifically because a hover-only affordance is
  undiscoverable. (The *visual* discoverability problem is fixed; the
  *keyboard* reachability problem is not — see Critical-1.)
- `DeviceRowView`, `AppRowView`, `MainOutRowView`, `ConnectionDiagnosisView`,
  and the onboarding `PermissionRowView` are built almost entirely from stock
  `NSButton`/`NSSlider`/`NSPopUpButton`/`NSTextField`, each with an explicit
  `setAccessibilityLabel` — which is exactly why they're fully covered:
  stock controls get keyboard/VoiceOver support close to free, and this
  codebase leans on that consistently.
- `NSPopover.behavior = .transient` gives the popover a working Escape-to-close
  and outside-click-to-dismiss for free — no custom code needed or found.
- Reduce Motion is checked consistently (`LevelMeterView`, `StatusDotView`,
  `DeviceIconWellView`, `CardView`'s collapse animation, `ControlPanelWindowController`'s
  fade) — no a11y-specific Reduce-Motion gaps found in this pass.

## Top 5 by user impact

1. **C1** — Icon picker (device + group icon customization) is entirely
   unreachable without a mouse — a full feature blocked, not just degraded.
2. **M1** — Connection status (the core "is my speaker connected" signal)
   relies on color alone for its most frequent state transition.
3. **M3** — Per-app routing — the app's headline feature — hides its two
   most useful facts ("where is this app's audio going," "is it even
   running") from VoiceOver's summary of the row.
4. **M2** — The upcoming shared panel shell hides its only close button with
   no confirmed keyboard alternative — currently inert behind a flag, but a
   release-blocker the moment that flag flips on.
5. **N1** — The theme picker (a settings control every sighted user operates
   by glancing at a ring) tells a VoiceOver user nothing about which theme is
   currently active.
