# P1 — AppKit menu brief (T-R1)

Research brief for the menu-bar UI tasks **T-U1 / T-U2 / T-U3**. Transcribe from
this; do not re-derive. Grounded in Apple docs + practitioner findings (cited).
Contract: SPEC §9 ("Menu bar extra", "Groups in the menu", "Device row").

Sources (canonical):
- NSMenuItem.view / NSMenu / NSMenuDelegate / NSStatusItem:
  https://developer.apple.com/documentation/appkit/nsmenuitem
  https://developer.apple.com/documentation/appkit/nsmenu
  https://developer.apple.com/documentation/appkit/nsmenudelegate
  https://developer.apple.com/documentation/appkit/nsstatusitem
- **Views in Menu Items** (the load-bearing doc for #2/#3/#5):
  https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/MenuList/Articles/ViewsInMenuItems.html
- Help-menu first-responder bug + fix: https://indiestack.com/2018/04/helpless-help-menu/
- Menu keyboard-nav hacking: https://kazakov.life/2017/05/18/hacking-nsmenu-keyboard-navigation/
- Updating a menu while open (cocoa-dev / omni): https://lists.apple.com/archives/cocoa-dev/2012/Apr/msg00403.html

---

## 1. NSMenu mutation while open — VERDICT: **YES, with caveats**

Live `insertItem(_:at:)` / `removeItem(_:)` on a **displayed** `NSMenu` works and
re-lays-out live. `NSMenu` posts item-added/removed/changed notifications and the
open menu view observes them and re-lays-out; you normally do **not** call any
`relayout`/`update()` yourself (griffith NSMenu ref; cocoa-dev). This is exactly
the mechanism SPEC §9 "Expansion" wants for in-place group expand/collapse.

**The one real caveat** (this is what "you can't change a menu item while it's
displayed" refers to online): mutating an **existing** item's `title` /
`attributedTitle` while open is the unreliable path — it only redraws on
mouse roll-on/off (cocoa-dev/omni thread). Structural **insert/remove of whole
items is not that case** and is reliable. So: put changing content in the item's
**custom view** (which you `setNeedsDisplay:` freely), and express expansion as
insert/remove — never as retitling live.

Secondary caveat: the archive doc says "resizing [a menu item] during menu
tracking is not supported" — i.e. don't resize an *item's view frame* mid-track.
Inserting/removing *whole items* changes the menu's own height and is fine; it's
per-item view-frame resize that's unsupported. Keep each row a fixed height.

Recommended pattern (primary):

```swift
// Rows for one group's members, tracked so we can remove exactly them.
private var expandedRows: [ObjectIdentifier: [NSMenuItem]] = [:]

func toggleExpansion(of group: Group, headerItem: NSMenuItem, in menu: NSMenu) {
    let key = ObjectIdentifier(group as AnyObject)
    if let rows = expandedRows[key] {                 // collapse
        for item in rows { menu.removeItem(item) }    // live remove, re-lays out
        expandedRows[key] = nil
    } else {                                          // expand in place
        var insertAt = menu.index(of: headerItem) + 1
        var inserted: [NSMenuItem] = []
        for device in group.members {
            let item = NSMenuItem()
            item.view = DeviceRowView(device: device) // fixed height, see §2
            menu.insertItem(item, at: insertAt)       // live insert, re-lays out
            inserted.append(item); insertAt += 1
        }
        expandedRows[key] = inserted
    }
}
```

**Fallback (if the live path ever misbehaves on a target OS):** full rebuild via
`NSMenuDelegate`. Keep the menu model in an array; on toggle, mutate the model and
call the same builder. `menuNeedsUpdate(_:)` fires "when a menu is about to be
displayed at the start of a tracking session" (docs) — so it only helps for the
*next* open, not a live toggle. For a live full-rebuild fallback, do
`menu.removeAllItems()` + rebuild synchronously inside the chevron action; it
flickers slightly but is bulletproof. Prefer the primary; keep the model-driven
builder so switching is a one-line change (per SPEC §9 note: "fallback is
`menuNeedsUpdate`").

---

## 2. NSMenuItem.view custom rows (slider / mute / solo)

`NSMenuItem.view` "assigns drawing responsibility entirely to the view"; the item
draws no title/state itself. "Keyboard equivalents and type-select continue to
use the key equivalent and title as normal" (NSMenuItem docs).

**Continuous slider drag while the menu stays open — works, this is the核心.**
"During 'non-sticky' menu tracking (manipulating menus with the mouse button held
down), a view in a menu item receives `mouseDragged:` events" (Views in Menu
Items). So an `NSSlider` in the row gets the full drag. Set `isContinuous = true`
so the action fires throughout the drag (per SPEC §9 device-row row). The menu
**stays open** during the drag because AppKit routes the drag to the view instead
of dismissing — no extra work needed.

```swift
let slider = NSSlider(value: dev.volume, minValue: 0, maxValue: 100,
                      target: self, action: #selector(volumeChanged(_:)))
slider.isContinuous = true          // fires action continuously during drag
slider.controlSize = .small
```

**Highlight / tracking:** the menu does NOT paint a selection background behind a
custom view — the view owns all drawing (docs). To get the standard blue
menu-highlight you draw it yourself in the row when the item is highlighted. Track
hover with an `NSTrackingArea` (needed for the SPEC §9 hover-revealed pencil and
for highlight):

```swift
override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(
        rect: bounds,
        options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
        owner: self))
}
override func draw(_ dirty: NSRect) {
    if enclosingMenuItem?.isHighlighted == true {
        NSColor.selectedMenuItemColor.setFill(); bounds.fill()
    }
    // ...draw contents; use .selectedMenuItemTextColor when highlighted
}
```

**Sizing:** "A menu item with a view sizes itself according to the view's frame …
always at least as wide as its view." Auto Layout works inside the row, but give
the row an explicit height and let width auto-expand: set the autoresizing mask
`.width` (`NSViewWidthSizable`) so it fills the menu, and pin a height constraint.
"Resizing during menu tracking is not supported" — so fix the height up front.

```swift
let row = DeviceRowView()
row.translatesAutoresizingMaskIntoConstraints = false
row.heightAnchor.constraint(equalToConstant: 28).isActive = true
row.autoresizingMask = [.width]   // fill menu width
```

**Timers / meters** (if ever re-enabled — Q8 SKIPPED in P1): a repaint timer must
be added in `.eventTracking` mode or it freezes while the menu is open (docs).

---

## 3. Editable NSTextField in a menu item view — VERDICT: **DON'T. Use a popover/panel.**

Apple is explicit: **"A view in a menu item can receive all mouse events as
normal, but keyboard events are not supported"** (Views in Menu Items). A field
in a menu row cannot become a working first responder during menu tracking:
keystrokes are dropped / beep. The Help-menu search field is the *system's own*
specially-plumbed control, not something app code can reproduce with an ordinary
`NSTextField` in `NSMenuItem.view`. The indiestack write-up documents the mirror
failure (menus stealing first responder and leaving text views beeping).

**Firm recommendation for T-U3's group-name editor:** do NOT put an editable
`NSTextField` in the in-menu editor. Instead, on "New group…" / pencil, close the
menu and present a small **`NSPopover`** (or borderless attached panel) anchored
to the status-item button. The popover is a normal window → real first responder,
real typing, real field editor. Checkboxes (`NSButton(checkboxWithTitle:)`) are
fine in a popover too, and this keeps the whole editor together.

```swift
// From the chevron/pencil action: dismiss the menu, show an anchored popover.
statusItem.menu?.cancelTracking()
let popover = NSPopover(); popover.behavior = .transient
popover.contentViewController = GroupEditorViewController(group: group) // has the NSTextField
if let button = statusItem.button {
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
}
```

This diverges from SPEC §9's "swaps in place to an editor … group-name
`NSTextField`" — flag to ahh: the checkbox list *can* live in-menu, but **text
entry must move to a popover**. Non-text swap-in-place editing (back arrow, the
checkbox "Speakers" list, Cancel/Save as custom-view rows with buttons) is
achievable via §1's live mutation; only the name field is the blocker. Simplest
coherent answer: whole editor in a popover.

---

## 4. NSStatusItem via `.button` (modern setup)

Never init `NSStatusItem` directly and never touch `.view`/`.title`/`.image`
(deprecated — docs). Use `statusItem(withLength:)` and customize only `.button`.

```swift
let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
if let button = statusItem.button {
    button.image = NSImage(systemSymbolName: "speaker.wave.3.fill",
                           variableValue: masterVolume,          // 0.0…1.0
                           accessibilityDescription: "AirPlay volume")
    button.image?.isTemplate = true    // correct in dark/light menu bar
}
statusItem.menu = buildMenu()          // menu shown automatically on click
```

- **Volume-reactive icon:** rebuild the image with a new `variableValue` whenever
  master volume changes (SF Symbol waves fill with level). Template rendering is
  automatic for SF Symbols; set `isTemplate = true` to be safe.
- **`menu` property vs target/action:** assigning `.menu` makes AppKit open the
  menu on click (no action fires) — this is what we want. If you ever need custom
  click handling (e.g. left-click menu, option-click something else), leave
  `.menu` **nil**, set `button.target/action` + `button.sendAction(on:
  [.leftMouseUp, .rightMouseUp])`, and show the menu programmatically:

```swift
statusItem.menu = nil
button.target = self; button.action = #selector(statusClicked(_:))
button.sendAction(on: [.leftMouseUp, .rightMouseUp])
@objc func statusClicked(_ sender: NSStatusBarButton) {
    let menu = buildMenu()
    statusItem.menu = menu                 // assign, pop, then clear
    button.performClick(nil)
    statusItem.menu = nil
}
```

For P1, plain `statusItem.menu = menu` is enough; keep the custom-click path in
reserve. (App runs `.accessory` per Q1 — no Dock icon.)

---

## 5. Keyboard navigation + accessibility with custom-view rows

**What breaks:** custom-view rows do NOT participate in the menu's normal
arrow-key highlight/selection cycle the way titled items do — "keyboard events
are not supported" in the view, and the menu won't auto-highlight a fully custom
row (Views in Menu Items; kazakov.life, which resorts to the *private*
`highlightItem:` — do NOT ship private selectors). Type-select and key-equivalents
still work off the item's `title`/`keyEquivalent`, so **set a `title` on each
custom-view item even though it isn't drawn** — it gives type-select + a11y a
label to work with, and keeps arrow navigation landing on the row.

**What to set:**
- Give every custom-view `NSMenuItem` a real `title` (used by type-select and
  accessibility even though the view draws instead).
- In `draw(_:)`, honor `enclosingMenuItem?.isHighlighted` so arrow-key navigation
  is visible (see §2) — without this, keyboard users see no selection.
- Set accessibility on the row view so VoiceOver announces it:

```swift
row.setAccessibilityElement(true)
row.setAccessibilityRole(.menuItem)                       // it IS a menu row
row.setAccessibilityLabel("\(device.name), volume \(pct)%")
slider.setAccessibilityRole(.slider)                      // controls keep their roles
muteButton.setAccessibilityLabel(isMuted ? "Unmute" : "Mute")
```

- Interactive controls inside the row (slider, mute/solo buttons) keep their own
  a11y roles; make sure their labels are set since the item's title won't cover
  them.

Accept that full arrow-key drive of sliders inside a menu is not a system-provided
behavior — mouse is the primary interaction (SPEC §9 sliders are drag controls).
Provide keyboard reach to the *rows* (via title/highlight) and rely on mouse/
VoiceOver for the embedded controls.

---

## Gotcha list (transcribe into T-U2/T-U3)

1. **Never retitle an item live while open** — only mouse roll-on/off redraws it.
   Put mutable content in the custom view and `setNeedsDisplay:` it. (§1)
2. **Insert/remove whole items = fine live; per-item view-frame resize = not**
   during tracking. Fixed row heights. (§1/§2)
3. **`menuNeedsUpdate` fires at open, not on a live toggle** — it's the *next-open*
   / fallback hook, not the live-expand mechanism. (§1)
4. **Slider must be `isContinuous = true`** or it only fires on mouse-up. Menu
   stays open during drag automatically (mouseDragged is delivered). (§2)
5. **The menu paints no highlight behind a custom view** — draw it yourself from
   `enclosingMenuItem.isHighlighted`, add an `NSTrackingArea` for hover. (§2/§5)
6. **No keyboard events in menu item views → no working editable text field.**
   Group-name entry goes in a popover/panel, not in-menu. (§3)
7. **Repaint timers need `.eventTracking` run-loop mode** or they stall while the
   menu is open. (§2)
8. **Give custom-view items a real `title`** for type-select + accessibility even
   though it isn't drawn. (§5)
9. **Only `.button` on NSStatusItem** — `.view`/`.title`/`.image` deprecated.
   Rebuild the button image to update `variableValue`. (§4)
10. **Don't ship private selectors** (`highlightItem:` et al.) — App Review /
    fragility; keep to the documented surface. (§5)
