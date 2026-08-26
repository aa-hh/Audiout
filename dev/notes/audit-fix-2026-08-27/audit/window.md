# Impeccable audit — Mixer/Groups window (`AudioutWindowUI`)

Surface: the fuller window — sidebar, group editor, device detail pane, Main Audio
detail, group creation sheet, icon picker.
Sources: `AudioutCore/Sources/AudioutWindowUI/`, shared components in
`AudioutCore/Sources/AudioutSharedUI/`, host wiring in
`AudioutCore/Sources/AudioutApp/AppDelegate.swift` and
`AudioutCore/Sources/AudioutPopoverUI/AppSurfaceController.swift`.
Visual evidence: all 14 PNGs in `dev/notes/window-snapshots/` (goldens are
known-unreproducible; read as evidence only, never regenerated).
Audience lens: a general Mac user with saved speaker groups and no audio vocabulary.

## Scores

| Dimension | Score |
|---|---|
| 1. Accessibility | 2 / 4 |
| 2. Performance | 2 / 4 |
| 3. Appearance & Theming | 4 / 4 |
| 4. Platform Conformance (macOS) | 3 / 4 |
| 5. States & Honesty | 2 / 4 |
| **Total** | **13 / 20** |

## Verdict

The theming layer is the best-executed part of this codebase and possibly of the
whole product: not one hard-coded colour in the module, every fill and stroke
resolved inside `draw(_:)` so it re-picks per appearance and per Increase
Contrast, and a measured contrast rationale written next to almost every token.
Several accessibility details that most apps skip are done properly here — the
custom icon well hand-rolls first responder, Space/Return, VoiceOver press and a
rounded focus-ring mask; the invisible membership checkbox still draws a focus
ring around its node.

What pulls the score down is two things that no amount of polish compensates for.
First, the destructive-action confirmation states something the code contradicts:
deleting the group that is currently playing **does** change what is playing, and
the alert says it does not. That is the "UI never lies" principle broken on the
one action where it costs the most. Second, the content pane has no equivalent of
the change-gate the sidebar got: every backend event, several per second during
discovery, tears down and rebuilds the whole group editor — which among other
things writes over the rename field while the user is typing in it, destroys
keyboard focus, and cancels an in-flight click on a membership row.

Underneath both is one shape: the parts that were deliberately worked are
excellent, and the paths that were never walked end-to-end by a critical user
(delete a playing group; create a group that already exists; type a name while a
speaker reconnects; press ⌘V in the name field) are where it falls down.

---

## P0

### P0-1 — The delete confirmation states the opposite of what the code does

**Location** `AudioutCore/Sources/AudioutWindowUI/GroupEditorViewController.swift:846`
(alert copy) against `AudioutCore/Sources/AudioutCore/GroupController.swift:629-634`
(`deleteGroup`).

The confirmation reads:

```swift
alert.informativeText = "Deleting a group doesn't change which speakers are playing."
```

`deleteGroup(id:)` does this:

```swift
if activeGroupID == id { activeGroupID = nil }
if mainOut == .group(id: id) { setMainOut(.selectedDevices) }
```

`setMainOut` (`GroupController.swift:457-462`) calls `applyRouting()`, which calls
`backend.setOutputSet(routableOutputIDs)`. So when the deleted group is the active
Main Out group — exactly the case where the editor is also showing a gold "Playing
now" badge two inches above the button — the delete re-routes system audio away
from that group's members onto the Selected Devices set. Speakers stop; other
speakers may start.

**Impact** The highest-stakes action in the surface, taken while audio is live in
other rooms, is confirmed with a false reassurance. A user who reads the sentence
and clicks Delete during a dinner party gets silence in rooms the app told them
would be unaffected. This also breaks Product Principle 2 ("the UI never lies")
and Principle 4 ("live audio is high-stakes") simultaneously.

**Recommendation** Branch the informative text on whether the group being deleted
is the active Main Out. Inactive: keep the current sentence. Active: say what will
actually happen, in plain speech — e.g. "This group is playing now. Deleting it
stops sending audio to its speakers." Verify the exact post-delete routing with a
live test before wording it, since the fallback target is the Selected Devices set
and what that means to the user depends on what is in it.

---

## P1

### P1-1 — A backend event overwrites the rename field while the user is typing

**Location** `AudioutCore/Sources/AudioutWindowUI/MixerWindowController.swift:491-495`
→ `GroupEditorViewController.swift:542-570` (line 547 is the write).
Driven from `AudioutCore/Sources/AudioutApp/AppDelegate.swift:1688`.

`refreshAll()` re-shows the editor unconditionally whenever the editor is the
current content:

```swift
if currentContent === editorViewController {
    if let id = editorViewController.editingGroupID, groupController.groups.contains(where: { $0.id == id }) {
        editorViewController.show(groupID: id, devices: devices)
```

and `show(groupID:devices:)` does `nameField.stringValue = group.name` with no
check for whether the field is currently being edited. `AppDelegate
.repaintFromCurrentState()` calls `update(devices:)` on essentially every backend
event (device added/updated/removed, volume echo, connection-state change), and
`update(devices:)` runs `refreshAll()` whenever the Groups screen is the visible
one. The sidebar is protected from this flood by a rendered-projection diff
(`MixerWindowController.swift:548-554`); the content pane has no such gate.

**Impact** Rename a group while a speaker reconnects, a volume echo arrives, or
discovery is still settling, and the half-typed name is replaced with the old one
mid-keystroke. Input loss, and the field's caret position goes with it.

**Recommendation** Two fixes, both worth doing. (a) In `show(groupID:devices:)`,
skip the `nameField.stringValue` write when `nameField.currentEditor() != nil`.
(b) Better: give the content pane the same change-gate the sidebar has — compare a
small Equatable projection of what the editor actually renders (group name, icon,
member set, candidate list, active flag) and return early when nothing changed.
That fixes P1-2 in the same stroke. *Needs live check* to confirm the exact
AppKit field-editor behaviour, but the unconditional write is unambiguous in code.

### P1-2 — Every backend event tears down and rebuilds the whole membership list

**Location** `GroupEditorViewController.swift:588-628` (`rebuildCandidates` →
`buildRows`), reached from the same unconditional `show()` above.

`buildRows` removes every arranged subview and constructs a fresh
`MembershipRowView` per candidate device, each of which builds an `NSImage` from a
symbol name (`MembershipRowView.swift:257-264`), installs constraints, and on
mount runs `updateTrackingAreas()` + `refreshHoverFromPointer()`
(`MembershipRowView.swift:356-374`). The pane-level rail is then re-planned and
repainted (`updateRail()`, plus `RailRepaintingView.layout()` and
`RailRepaintingStackView.layout()` at `GroupEditorViewController.swift:1145-1168`,
which both dirty the overlay on every layout pass).

**Impact** Three separate costs. Performance: a full view-tree teardown and
rebuild, several times a second during discovery, for a pane whose content usually
did not change. Interaction: a click on a row is a swallowed `mouseDown` waiting
for a `mouseUp` (`MembershipRowView.swift:329-341`) — if the row is destroyed
between the two, the toggle is silently lost. Accessibility: keyboard focus on a
membership checkbox is destroyed on every event, so a keyboard user tabbing
through the checklist gets thrown out repeatedly, and VoiceOver loses its cursor.

**Recommendation** Same projection gate as P1-1. If the candidate list and member
set are unchanged, call `MembershipRowView.apply(device:checked:iconSymbolName:)`
on the existing rows (that method exists precisely for this) instead of rebuilding.
Only rebuild when the candidate set itself changes.

### P1-3 — Creating a group that already exists silently discards the name and icon

**Location** `GroupCreationSheetController.swift:372-385` (`commit`),
`GroupController.swift:591-607` (`createGroup` dedup),
`MixerWindowController.swift:428-435` (`onComplete`).

`createGroup` dedups on the member set: if a saved group already has exactly those
members, it returns that group with `alreadyExisted == true` and the caller's
`name` and `iconSymbolName` are never applied (documented at
`GroupController.swift:580-587`). `MixerWindowController`'s completion handler
ignores `alreadyExisted` entirely — it refreshes, selects the resolved group, and
opens its editor.

**Impact** The user names a group "Party", picks an icon, checks Office and Sonos
Move, clicks Create — and lands in the editor for an existing group called
"Downstairs" with a different icon. Nothing on screen says a group was not
created, or why the name they typed is gone. It reads as the app ignoring them.

**Recommendation** Use the flag that is already plumbed through. When
`alreadyExisted` is true, tell the user in plain speech before selecting — a sheet
or a brief inline note: "Those speakers are already saved as \"Downstairs\"." Offer
the two real choices (open it, or go back and change the selection). Alternatively
allow a second group with the same member set; but silently resolving is the one
option that cannot stay.

### P1-4 — A failed group creation is swallowed and the sheet just sits there

**Location** `GroupCreationSheetController.swift:380-384`.

```swift
guard let result = try? groupController.createGroup(...) else { return }
```

On a throw (`GroupError.emptyMembership`, or any store write failure from
`saveGroup` → `store.save`), `commit()` returns without calling `finish`. The sheet
stays open, Create stays enabled, and nothing changes or is said.

**Impact** The user clicks Create and the app does nothing at all. Repeated clicks
do nothing. This directly contradicts the module's own written rule
(`AudioutWindowUI/AGENTS.md`: "Persistence failures are reported, never
swallowed") which the editor pane honours via `saveOrReport(_:)`.

**Recommendation** Mirror `GroupEditorViewController.saveOrReport(_:)`
(`GroupEditorViewController.swift:682-704`): catch, present the plain-words alert
as a sheet on the sheet's own window, and keep the form's state intact.

### P1-5 — "New Group…" with no reachable speakers is a dead end

**Location** `GroupCreationSheetController.swift:271-278` (`configure`) with
`GroupCreationSheetController.swift:313-322`.

Candidates are filtered to `isAvailable` devices only — deliberate and correct as
a rule. But when that filter yields nothing (nothing discovered yet, Wi-Fi down,
Local Network permission not granted), the sheet presents an empty checklist under
a "Speakers" label, a "0 speakers selected" caption, and a permanently disabled
Create button. There is no empty-state row and no explanation.

**Impact** The empty pane's own call to action ("Group your speakers" → "New
Group…") leads straight into a form that cannot be completed and does not say why.
On a first run — the most likely moment for zero discovered speakers — this is the
first thing a new user sees the app do.

**Recommendation** Add an honest empty row in the checklist when
`candidateDevices` is empty: name the cause the app actually knows ("No speakers
found yet" / "Audiout can't see your network"), and if a permission is missing say
so and offer the same route the onboarding uses. The "0 speakers selected" caption
is not an explanation.

### P1-6 — No Edit menu: ⌘C / ⌘V / ⌘X / ⌘A / ⌘Z are dead in every text field here

**Location** `AudioutCore/Sources/AudioutApp/AppDelegate.swift:1218-1240`
(`installMainMenu`) — the main menu is App + File ▸ Close only.

Affects the group rename field (`GroupEditorViewController.swift:232-259`), the
creation sheet's name field (`GroupCreationSheetController.swift:143-147`), and the
icon picker's search field (`IconPickerViewController.swift:108-115`). AppKit's
field editor implements `copy:`/`paste:`/`selectAll:`/`undo:`, but the *key
equivalents* for them come from the Edit menu. With no Edit menu, none of those
shortcuts fire.

**Impact** A user cannot paste a group name they copied from somewhere else, or
select-all before retyping, or undo a mis-edit. Right-clicking the field still
offers Cut/Copy/Paste, so this is invisible as a bug and just reads as the app
being broken. It is also an accessibility barrier: keyboard-only and
switch-control users lose the standard text-editing verbs entirely.

**Recommendation** Add a standard Edit menu to `installMainMenu()` — Undo, Redo,
Cut, Copy, Paste, Delete, Select All, all with `target: nil` so they travel the
responder chain. This is a handful of lines and fixes every text field in the app
at once, not just this surface.

### P1-7 — Icon search matches raw symbol names, not the plain words it shows

**Location** `IconPickerViewController.swift:359-362` (filter) against
`IconPickerViewController.swift:287-312` (the plain-language map).

The grid filter is a case-insensitive substring match against the raw SF Symbol
name:

```swift
curatedNames = allCuratedNames.filter { $0.range(of: trimmed, options: .caseInsensitive) != nil }
```

while the same file already knows that `fork.knife` means "Kitchen", `bed.double.fill`
means "Bedroom", `sofa.fill` means "Living room", `music.note.house.fill` means
"Music room", `appletv.fill` means "Apple TV".

**Impact** A user searching the words the app itself uses gets "No matches" for
icons that are right there in the grid. "kitchen", "bedroom", "living room",
"desktop", "router", "apple tv" (with the space) all fail. The placeholder says
"Search icons", so the user reasonably concludes the icon does not exist. The
plain-language layer exists and is simply not wired to the one control that needs
it.

**Recommendation** Match against both: the raw name **and**
`Self.accessibilityLabel(forSymbol:)`. One-line change to the filter predicate.

### P1-8 — Two sidebar states are conveyed by colour alone to VoiceOver

**Location** `SidebarViewController.swift:797-800` and `868-886` (`makeIconLabel`,
`dimmed`), and `SidebarViewController.swift:663-682` (`IconLabelCellView`).

An unavailable speaker is rendered by swapping the text and icon tint to
`.disabledControlTextColor`. Nothing sets an accessibility label, value, or help
that says "unavailable". The active group's gold `speaker.wave.2.fill` marker
carries a `toolTip` and an image `accessibilityDescription`, but the cell's spoken
label is still just the group name — a table cell's `textField` wins, and a
trailing `NSImageView` inside an `NSTableCellView` is not reliably announced.

**Impact** A VoiceOver user hears "Bedroom HomePod" for a speaker that is offline
and "Downstairs" for the group that is currently playing — identical to every other
row. The two pieces of state the sidebar exists to carry are invisible. A
low-vision user relying on Increase Contrast is in a similar position for the
dimmed rows.

**Recommendation** `MembershipRowView.swift:274-277` already does this correctly:
`setAccessibilityLabel("\(device.name)\(device.isAvailable ? "" : ", unavailable")")`.
Apply the same pattern to the sidebar cells — append ", unavailable" for dimmed
device rows and ", playing now" for the active group row, using the same words the
visible UI uses so the spoken state derives from the same source the screen draws.

---

## P2

### P2-1 — Gold stops meaning "live" the moment an active group's membership is edited

**Location** `GroupEditorViewController.swift:603` (`row.railArmed = isActiveGroup`),
`MembershipRowView.swift:240-243` (node filled when `checked`),
`GroupController.swift:559-568` (`saveGroup` is a pure model op — it does not
re-route).

The editor's rail draws gold when the edited group is the active Main Out, and
fills a node when a device is *checked*. But saving a membership change does not
move audio (correctly — the reassurance line at
`GroupEditorViewController.swift:135-138` says so). So after unchecking a member
of the group that is playing, that speaker's node goes hollow while the speaker is
still playing; after checking a new one, its node fills gold while nothing is
being sent to it.

**Impact** The module's own stated invariant — "Gold means LIVE, so the editor's
rail is armed/idle end to end" (`AudioutWindowUI/AGENTS.md`) — is only true until
the first edit. The picture and the reassurance sentence then say opposite things
on the same screen.

**Recommendation** Decide which truth the rail tells and make it consistent. Either
drive the node's armed tone from the *routed* member set rather than the saved one
(so an edited-but-not-reapplied member reads idle), or drop the armed tone for a
group whose saved membership no longer matches what is routed and let the
reassurance line carry the whole story.

### P2-2 — Destructive delete is the default button, unnamed, unmarked

**Location** `GroupEditorViewController.swift:844-849`.

```swift
alert.messageText = "Delete this group?"
alert.addButton(withTitle: "Delete")   // first button = default, fires on Return
alert.addButton(withTitle: "Cancel")
```

Three HIG deviations at once: the destructive action is the default (Return
deletes), the alert does not name the group being deleted, and the Delete button
is not marked `hasDestructiveAction` even though the pane's own button is
(`GroupEditorViewController.swift:278`).

**Impact** A user who hits Return out of habit deletes a group. If they reached
the alert from the sidebar context menu on a row they right-clicked without
selecting, they cannot tell from the alert which group is about to go.

**Recommendation** Name the group in the message ("Delete \"Downstairs\"?"), set
`alert.buttons[0].hasDestructiveAction = true`, and make Cancel the default by
giving it the Return key equivalent (or reorder so Cancel is first).

### P2-3 — Escape in the rename field kills Tab traversal for the window

**Location** `GroupEditorViewController.swift:718-722`.

```swift
private func cancelRename() {
    nameField.abortEditing()
    restoreNameField()
    nameField.window?.makeFirstResponder(nil)
}
```

`makeFirstResponder(nil)` makes the *window* the first responder. That is exactly
the state the A11Y-GROUPS work diagnosed as the reason Tab did nothing in this
window (`SidebarViewController.swift:121-159`), and nothing re-seeds the loop after
an Escape — the two existing seeds fire on `viewDidAppear` and on a content-pane
swap, neither of which happens here.

**Impact** Press Escape while renaming and the keyboard goes dead until the user
clicks something. Same bug the module already fixed, re-introduced at one site.

**Recommendation** Hand focus somewhere real instead of nowhere — the sidebar's
outline view is the natural anchor and is always present. Or re-seed
(`window.recalculateKeyViewLoop()` + `makeFirstResponder(sidebar)`) after the
abort.

### P2-4 — Membership checkbox's VoiceOver label goes stale after every toggle

**Location** `MembershipRowView.swift:274-277` (set in `apply`) against
`MembershipRowView.swift:396-400` (`checkboxToggled`) and `117-124` (`isChecked`).

The label is composed once per `apply` as "Add X to group" / "Remove X from
group". Toggling the row updates `checked`, the drawn node, and the checkbox
state — but never the label.

**Impact** After a VoiceOver user checks a row, the control still announces "Add
Kitchen to group" while being checked. The state comes through the checkbox role,
but the verb now describes the wrong action.

**Recommendation** Move the label composition into a small `updateAccessibility()`
called from `apply`, `checkboxToggled`, and the `isChecked` setter. Or drop the
verb entirely and let the checkbox role carry the state ("Kitchen", checked) —
simpler and no less clear.

### P2-5 — Duplicate group names are allowed and are indistinguishable in the sidebar

**Location** `GroupEditorViewController.swift:664-674` (`commitRename`) and
`GroupController.swift:591-607` (dedup is on member *set*, never on name).

Nothing prevents two groups being named "Kitchen". The sidebar then renders two
identical rows (`SidebarViewController.swift:791-795` — icon + name only), and the
device detail pane's Groups list renders two identical navigable rows
(`DeviceDetailViewController.swift:700-747`).

**Impact** The user cannot tell which "Kitchen" is which from any surface, and the
device pane's "which groups is this speaker in?" answer becomes unusable. This
compounds with P1-3: member-set dedup means the app *does* care about duplicates,
just on the wrong axis for what the user sees.

**Recommendation** Either refuse a duplicate name on commit with a plain-words
explanation (matching the empty-name refusal already there), or auto-suffix
("Kitchen 2") the way Finder does. Refusing is more honest; suffixing is less
friction.

### P2-6 — Delete runs unconfirmed when the pane has no window

**Location** `GroupEditorViewController.swift:850-857`.

```swift
let performDelete = { self.performDelete(id: editingGroupID) }
if let window = view.window {
    alert.beginSheetModal(for: window) { ... }
} else {
    performDelete()      // no confirmation at all
}
```

**Impact** The fallback exists for headless tests, but it is a live code path in
the shipping binary: any state where the pane is momentarily unhosted (a pane swap
racing a context-menu dispatch, the surface closing) turns "Delete Group…" into an
unconfirmed destructive action. A test-only convenience should not be the
production fallback for a destructive operation.

**Recommendation** Make the no-window case a no-op in production and have the test
hook call `test_confirmDelete()` — which already exists at
`GroupEditorViewController.swift:1017-1020` and does exactly this. Then the
window-less branch can simply return.

### P2-7 — The device detail pane rebuilds its Groups rows on every backend event

**Location** `DeviceDetailViewController.swift:520-549` (`refreshUI` calls
`rebuildGroupRows()` unconditionally) and `650-671`.

Same driver as P1-2. Each refresh destroys and reconstructs one `NSButton` per
member group, each with a freshly built `NSImage`.

**Impact** Keyboard focus on a Groups row is destroyed several times a second
during discovery, so a keyboard user cannot reliably reach and press one. Wasted
main-thread work on a pane whose group membership rarely changes.

**Recommendation** Compare `shownGroupIDs` (plus the groups' names and icons)
against the freshly computed list and return early when unchanged.

### P2-8 — A sidebar reload can leave the wrong row highlighted

**Location** `SidebarViewController.swift:378-418` (`reload`) with `440-447`
(`select`).

`reload` captures `currentSelection`, calls `outlineView.reloadData()`, then
`select(previous, notify: false)`. `select` returns silently when
`findNode(matching:)` finds nothing — which is exactly the case when the previously
selected group or device no longer exists. `reloadData` preserves selection by row
*index*, so the highlight can land on whatever now occupies that index.

**Impact** After a group is deleted elsewhere (or a speaker disappears), the
sidebar can highlight a different row than the one the content pane is showing.
The host's `refreshAll()` fallback fixes the *content*, not the highlight.

**Recommendation** In `select`, clear the outline's selection
(`deselectAll(nil)`) when the target node cannot be found, so the sidebar never
shows a highlight it does not mean.

### P2-9 — "New Group from Selection…" claims a selection that may not exist

**Location** `SidebarViewController.swift:733-739`.

Standard macOS arbitration is implemented correctly — a right-click outside the
selection acts on the clicked row alone — but the menu item's *title* is fixed and
says "from Selection" in both cases.

**Impact** Right-click one speaker with nothing selected and the menu offers to
build a group "from Selection". The user has no idea what the selection is or how
big the resulting group will be. The bottom-bar button already solves this
(`SidebarViewController.swift:293-299` retitles to "New Group from N Speakers…");
the menu did not get the same treatment.

**Recommendation** Retitle per click, off the `ids` array the item already carries:
one id → "New Group from \"Kitchen\"…"; several → "New Group from 3 Speakers…".

### P2-10 — The editor pane cannot scroll and has zero headroom at seven speakers

**Location** `GroupEditorViewController.swift:481-482` (the `<=` bottom pin), the
module rule in `AudioutWindowUI/AGENTS.md`, and the fixed frame at
`AudioutCore/Sources/AudioutSharedUI/SurfaceLayout.swift:13` /
`AppSurfaceController.swift:182, 428-429`.

The editor has no scroll view by design; its budget is the surface's content
height minus the footer strip. The AGENTS file states the pane has *zero* spare
points at a seven-device fleet, and the guard test pins exactly seven. The window's
height is derived from the Mixer screen's fit, which grows at a different rate per
device than the editor does.

**Impact** A household with ten or twelve speakers may push the editor past its
budget, at which point the `<=` pin breaks and content clips with no way to scroll
to "Delete Group…". Unverified either way.

**Recommendation** *Needs live check* — build a mock fleet of 10–14 speakers and
open the editor. If it clips, roadmap 039 (a scroll view for the editor) stops
being optional. At minimum extend the fitting-height guard past seven.

### P2-11 — The membership control has no checkbox affordance and no legend

**Location** `MembershipRowView.swift:128-243` (invisible cell + node),
`GroupEditorViewController.swift:594-628`. Evidence:
`dev/notes/window-snapshots/mixer-7-edit-active-group-dark.png`.

The Speakers checklist replaces the checkbox with a hollow or filled disc on a
vertical wire. Nothing on the pane says the discs are toggles or what hollow
versus filled means; the "Speakers" label above it is the only text.

**Impact** For the stated design target — a general Mac user with no audio
vocabulary — the pane's primary control is not recognisable as a control. Hover
reveals a ring, but nothing invites the hover. The house rule that the whole row is
the target helps once you know, and does nothing for discovery.

**Note** This is a settled design decision (Warm Signal v4 §Call-1, Alec Q6,
2026-07-25), so flagging it as a comprehension risk rather than a defect.

**Recommendation** One line of quiet copy under "Speakers" would close it —
something like "Click a speaker to add or remove it from this group." If the pane's
height budget genuinely cannot take a line (see P2-10), the alternative is a
trailing "In group" / blank annotation per row, which costs no height.

### P2-12 — Symbol images are reconstructed per row per refresh

**Location** `SidebarViewController.swift:874`, `MembershipRowView.swift:257-264`,
`DeviceDetailViewController.swift:722-725, 792`.

Every cell/row build calls `NSImage(systemSymbolName:accessibilityDescription:)`
and often `.withSymbolConfiguration(...)`. Combined with the per-event rebuilds
above, this is symbol lookup and image construction on the main thread at event
rate.

**Impact** Not visible on its own; a multiplier on P1-2 and P2-7. Matters more on
a large fleet during discovery.

**Recommendation** Cache resolved images by (symbol name, point size, weight) in
`DeviceIcon` — it is already the single resolution point
(`AudioutCore/Sources/AudioutSharedUI/DeviceIcon.swift`), so it is the natural
home. Lower priority than fixing the rebuild itself.

---

## P3

### P3-1 — The empty state's headline is drawn in the secondary tone
`MixerWindowController.swift:857` — `messageLabel.textColor = Tokens.Color.secondaryLabel`
on the page's primary message ("Group your speakers"), with the subtitle in
tertiary. Visible in `mixer-1-default-dark.png`: the headline reads as a caption
rather than a heading. Use `Tokens.Color.label` for the headline and keep the
subtitle secondary — the hierarchy is currently one rung too low across the board.

### P3-2 — ⌘N fires while a text field is being edited
`SidebarViewController.swift:699-707`. Key equivalents dispatch down the whole view
tree, so `SidebarContainerView` claims ⌘N regardless of what has focus — including
the rename field. Typing ⌘N mid-rename opens the create sheet. Guard on
`window?.firstResponder` not being a field editor, or take the upgrade path the
`razor:` comment already names (a real File ▸ New Group menu item, which would also
advertise the shortcut — it is currently invisible).

### P3-3 — Nothing on the device page can be copied
`DeviceDetailViewController.swift:179-187` (name label) and `472-499` (About rows)
build non-selectable labels. A user cannot copy a speaker's name or status to paste
into a support message. Set `isSelectable = true` on the name and the About values.

### P3-4 — Stale doc comments claim the screen is user-resizable
`DeviceDetailViewController.swift:52-53` and `MainOutDetailViewController.swift:29-30`
both say the Groups screen "is user-resizable with drag memory". It is not:
`SurfaceLayout.width` is fixed at 623 and `AppSurfaceController.swift:443-446` says
"The frame never changes — every screen wears the session size." The reasoning the
comments give for the scroll views is still valid; the premise is not. Correct the
comments so the next reader does not plan around resizability.

### P3-5 — The icon picker grid is 24 tab stops with no arrow-key navigation
`IconPickerViewController.swift:189-217`. Each curated symbol is its own focusable
button in an `NSGridView`. Reaching the last icon by keyboard is 24 presses of Tab,
and the standard grid gesture (arrow keys) does nothing. An `NSCollectionView`
would give arrow navigation for free; short of that, the search field is the
practical keyboard path — which makes P1-7 sharper than its own severity suggests.

### P3-6 — Sidebar icons duplicate the row's name to VoiceOver
`SidebarViewController.swift:874` — `NSImage(systemSymbolName: symbol,
accessibilityDescription: text)` gives the icon the device's own name as its
description, alongside the cell's text field carrying the same string. Pass `nil`
(the decorative case) as the device detail pane's chevron already does
(`DeviceDetailViewController.swift:736`).

### P3-7 — No undo anywhere
Renames, membership toggles, icon picks and deletes all apply instantly and
permanently, with no ⌘Z and (per P1-6) no Edit menu to host one. Instant-apply is
the right model for this surface; the missing half is a way back. Registering the
editor's writes with an `NSUndoManager` is the standard macOS answer and would
land once the Edit menu exists.

---

## Systemic patterns

**1. The refresh path has one gate, and it is on the wrong half.**
`MixerWindowController` built a careful rendered-projection diff so an EQ-only
backend event cannot rebuild the sidebar (`:540-591`), and a hidden-screen gate so
events never repaint a screen nobody is looking at (`:297-301`). Neither
protection was extended to the content pane, which is the expensive and
state-bearing half. P1-1, P1-2, P2-7 and P2-12 are all one missing gate.

**2. Rules the module wrote down are honoured in one place and not the next.**
"Persistence failures are reported, never swallowed" holds in the editor
(`saveOrReport`) and is violated in the creation sheet (`try?`). "Nothing else ever
calls `makeFirstResponder`" holds everywhere except `cancelRename`. "Gold means
LIVE end to end" holds until the first membership edit. The rules are good; they
need a second pass for call sites that predate them.

**3. Accessibility is excellent where it was consciously built and absent where it
was inherited.** The custom icon well and the invisible checkbox — the two places
someone knew stock AppKit would not help — have first responder, key handling,
press seams, focus-ring masks and labels. The stock `NSTableCellView` sidebar, where
AppKit gives you a label for free, is where the two pieces of state that matter go
unspoken (P1-8). The pattern is "custom got attention, stock got assumed".

**4. Plain-language layers exist but are not wired to the controls that need them.**
`curatedAccessibilityLabels` knows every icon's household name and only VoiceOver
ever sees it (P1-7). `alreadyExisted` is computed, returned, documented — and
ignored (P1-3). The information needed to fix several findings is already in the
codebase, one call site away.

**5. Copy is written with real care and is checked against one state only.**
"AirPlay 1 — sync not exact", the folded Status line, the reassurance sentence,
"Ready" instead of "Not connected" — all of these are better than most shipping
apps. Each was written for the common case and not re-read against the edge case:
the delete alert is true for an inactive group and false for the active one (P0-1);
"New Group from Selection…" is true when there is a selection (P2-9).

---

## Positive findings

**Theming is exemplary and should be the model for the rest of the product.**
Zero hard-coded colours in `AudioutWindowUI` (verified by grep). Every surface
that could freeze a colour instead draws it: `HairlineView`, `GroupedSectionView`,
`DeviceIconWellView`, `WarmPreviewTileView` all resolve tokens inside `draw(_:)`
so they re-pick per appearance and per Increase Contrast on every paint, with
`viewDidChangeEffectiveAppearance` triggering the repaint. The one genuinely
layer-backed element (the icon well's pencil badge) is re-stamped both on
appearance change and on `NSWorkspace.accessibilityDisplayOptionsDidChange`
(`DeviceIconWellView.swift:200-229`) — the case almost every app misses — and has a
test hook that counts re-stamps rather than comparing colours, because "correct
already" and "never updated" are not the same thing.

**Contrast is measured, not eyeballed, and the reasoning is written down.**
`Tokens.swift` carries per-token WCAG ratios against the specific surfaces each
token lands on, names the floors, and explains every deviation from the spec sheet
(e.g. `hairline` at `:288-297`, `gold` at `:484-497`, `well` at `:240-264`). Where a
value fails a floor, the Increase Contrast variant is the escape valve rather than
a quiet pass.

**The custom controls carry their own accessibility rather than dropping it.**
`DeviceIconWellView` hand-rolls `acceptsFirstResponder`, `keyDown` for
Space/Return/keypad-Enter, `accessibilityPerformPress()`, and a rounded
`drawFocusRingMask()` matching the drawn shape — plus a keyboard-focus badge
step-up so a sighted keyboard user gets the same cue a mouse user gets on hover.
`InvisibleSwitchCell` (`DeviceRowView.swift:3129-3149`) draws no glyph but still
returns a focus-ring mask around the node, so the invisible checkbox is visibly
focusable. `isEditable = false` correctly flips the role to `.image` and refuses
every interaction path, so the Main Audio well makes no promise it cannot keep.

**Reduce Motion and Reduce Transparency are honoured at every site.**
`DeviceIconWellView.setOverlayVisible` branches on
`accessibilityDisplayShouldReduceMotion`; `BusRailOverlayView` cancels its pulse
and gates all three animation entry points on it (`:156, 403, 555, 673`); the
sidebar wash promotes itself to opaque under Reduce Transparency
(`SidebarViewController.swift:645-654`).

**The EQ editor is the strongest accessibility work in the module.** Every control
has an explicit label *and* a live `accessibilityValue` refreshed from the model
(`EQEditorView.swift:691-696`); the response curve is exposed as an image with a
spoken summary of the whole curve (`EQResponseCurveView.swift:198-201, 242`); the
Advanced disclosure composes label, hint and shaped-band count into one spoken
string. The in-flight echo guard (`DeviceDetailViewController.swift:153, 543-545`;
`MainOutDetailViewController.swift:262-266`) is a genuinely subtle correctness fix
— a queued stale snapshot can no longer rewind a slider under the pointer — and
the reasoning for releasing on echo rather than at commit is documented.

**The icon picker never speaks jargon and never signals by colour alone.** Raw SF
Symbol names are mapped to household words for VoiceOver
(`IconPickerViewController.swift:287-318`), with a humanising fallback so a future
symbol is merely less polished rather than silent; the gold "current icon" ring is
paired with a ", current icon" label suffix; the ring's layer colour re-resolves on
appearance flip via an observing root view.

**The state model is honest where it counts.** Status folds `connectionState` and
`isAvailable` into one line specifically because two rows read as a contradiction
(`DeviceDetailViewController.swift:583-591`); "Ready" beats "Not connected" for a
reachable idle speaker; the AirPlay row says what AirPlay 1 *costs* rather than
printing a version number; the row is dropped entirely for devices where the
question has no answer. Empty states exist and teach rather than just reporting
("Group your speakers" + what a group is for). An unavailable device stays visible
and removable while it is a member, and stops being offered for joining
(`GroupEditorViewController.swift:588-591` vs
`GroupCreationSheetController.swift:271-278`) — the right rule, stated once,
applied both ways.

**The one-way-door risks are identified and defended.** The sidebar split item is
both `canCollapse = false` *and* re-asserted on every refresh, because the flag
alone does not stop AppKit's own auto-collapse — with the reasoning for why a
collapse would be unrecoverable written at the site
(`MixerWindowController.swift:162-171, 477-482`).

**Header parity is geometric rather than hand-copied.** Every shared number lives
in `GroupsPaneLayout` and is asserted against real laid-out frames, so swapping
sidebar selection between a group and a device does not twitch the header —
a class of polish bug most apps never close.

**Cross-surface vocabulary is consistent.** "System Audio" as the section, "Main
Audio" as the row and page title, matching the popover's own card and row
(`PopoverController.swift:1697`, `MainOutRowView.swift:120`), and the "Playing
now" wording plus glyph is literally the same in the sidebar and the editor header
so one state cannot acquire two names.
