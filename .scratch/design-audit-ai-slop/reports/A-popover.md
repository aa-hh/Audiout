# A — Mixer popover and app shell

Paths are relative to `/Users/alechenderson/Projects/AirPlay Controller/.claude/worktrees/design-audit-ai-slop-f1de78`.

## 1. Verdict

The mixer panel itself is the work of a person: the cards draw no chrome of their own, the ring and the rail carry state by form as well as colour, the motion is one authored moment tied to a real event, and almost every constant in the row grid has a measured reason written beside it. What does not hold is the frame around it and one execution gap inside it: the app puts a logotype and a branded hold in front of a volume control that people click in a hurry, and the row's single most important control has no visible appearance at all, which the code itself patches with a printed sentence and a pointing-hand cursor.

Highest-impact change: give the device row a control the eye can find without hovering, and delete the printed instruction and the first-open splash that exist to cover its absence.

## 2. Findings

```
[P1] Mixer, device row — AudioutCore/Sources/AudioutSharedUI/DeviceRowView.swift:2319, :3138-3153; AudioutCore/Sources/AudioutPopoverUI/PopoverController.swift:2311 — popover-light.png, popover-dark.png
  tell:  C reinvented control / invented affordance for a standard task
  now:   Picking a speaker has no visible control. The real NSButton checkbox is drawn by
         `InvisibleSwitchCell`, which paints nothing; the only marks are a circle on the rail
         in the far-left gutter and the row name's ink. Three separate regions accept the
         click and are signalled by nothing but a pointing-hand cursor on hover: the name
         (`resetCursorRects`, :3142, toggles selection), the icon (:3146, opens a menu) and
         the rail gutter (:3152, toggles selection). The app ships a sentence to explain it:
         "Click a speaker's name to play your audio on it. Click it again to stop."
         (PopoverController.swift:2311), whose own comment reads "the Mixer's rows are all
         affordances and none of them says so."
  why:   A printed instruction telling a Mac user how to click a list row is the standard
         admission that the affordance is missing, and the pointing hand is the web's link
         cue borrowed to stand in for it. One cursor promises three different outcomes. The
         rail is a named, sanctioned custom control, so the direction is not the problem; the
         execution is, and the codebase already says so in its own comment.
  fix:   Make the state visible at rest on the row, not only in the gutter: for example give
         the row's own ink and the rail node a resting difference strong enough to read
         without hover, or restore a real, visible checkbox in the gutter column and let the
         rail draw behind it. Then delete `membershipHintText` and drop the pointing-hand
         cursor from the name and the gutter (keep it on the icon only if the icon keeps its
         menu). If the hint has to stay for now, that is the measurement that says the
         control is not doing its job.
```

```
[P1] First open of the surface — AudioutCore/Sources/AudioutPopoverUI/SurfaceSplashView.swift:7-51, AudioutCore/Sources/AudioutPopoverUI/AppSurfaceController.swift:229-238, :410 — no screenshot
  tell:  A scaffold / decorative motion — an orchestrated load sequence in front of a task
  now:   The first time the surface opens in a process, the click shows nothing on screen for
         up to `revealCeiling` 0.6 s (AppSurfaceController.swift:238, whose own comment calls
         it "a bound on how long a menu-bar click can appear to do NOTHING"), then covers the
         mixer with the brand mark over the wordmark for at least `holdDuration` 0.7 s
         (SurfaceSplashView.swift:37), up to `ceilingDuration` 2.7 s (:43), plus a 0.25 s
         fade. The class doc calls it "ORNAMENT and nothing else" (:13).
  why:   No Apple menu-bar extra does this, and the instinct it comes from is a marketing
         site's, not a utility's. PRODUCT.md's own principle 4 says kill-switch controls
         (mute, master volume) stay one gesture away and are never buried; this buries them
         behind a logo on the one open where the user has never seen the app work. The code
         comment justifies saying the product's name, but it never weighs that against the
         delay it buys, and the delay is the part the user feels.
  fix:   Delete `SurfaceSplashView` and its reveal deferral, and let the first click open the
         panel at whatever size discovery has reached. If the name has to appear on first
         open, put it in the panel's own empty state while discovery runs, with the rows
         arriving under it and every control live the whole time.
```

```
[P2] Surface header strip — AudioutCore/Sources/AudioutPopoverUI/SurfaceToolbar.swift:181, :486-517 — no screenshot
  tell:  C native conformance / brand where the window title belongs
  now:   `SurfaceBrandView` sets "Audiout" in ClashDisplay-Semibold at 17 pt and pins it to
         the window's centre line via `toolbar.centeredItemIdentifiers` (:181), where a
         macOS window puts its title.
  why:   A display-face logotype centred in a title bar is the clearest single cross-platform
         import on a Mac window; the centre of a title bar names the document or the screen,
         not the vendor. The strip already says the product name three ways a Mac user
         expects (the menu-bar glyph they clicked, the About window, the app menu), so the
         wordmark adds identity where the platform expects orientation. It is an owner's
         call recorded in the code (2026-09-05), so it is a chosen thing that still reads as
         a tell rather than an accident.
  fix:   Put the current screen's name there instead ("Mixer" / "Scenes" / "Settings"), in
         the system face, and let the tab glyph carry the icon. If the wordmark stays, it is
         worth knowing it is the one element in this slice a Mac-fluent stranger will name
         first.
```

```
[P2] Output Speakers card, Bluetooth subsection — AudioutCore/Sources/AudioutPopoverUI/PopoverController.swift:3372, :3477, :3401, :3517 — popover-light.png, popover-dark.png
  tell:  D copy / inconsistent action verbs
  now:   Two controls about 40 pt apart fire the same closure with two different names. The
         empty-state row reads "Connect a speaker" (:3477) and calls `onPairBluetoothSpeaker`
         (:3517); the "+" footer's menu reads "Pair a Bluetooth speaker…" (:3372) and calls
         the same `onPairBluetoothSpeaker` (:3401). The same menu also carries "Connect
         '<name>'" items, which do something genuinely different (a reconnect).
  why:   Two verbs for one action, both on screen at once, with a third use of "Connect" for
         a different action in the same menu. This is the drift that happens when two
         affordances are added by two passes and nobody reconciles the words, and the copy
         rules call it out by name ("Pick one verb per action and reuse it").
  fix:   Say the same thing in both places. The Settings trip is a pairing trip, so:
         "Pair a speaker…" on the empty-state row and "Pair a speaker…" in the menu, leaving
         "Connect '<name>'" to mean only a reconnect of something already paired.
```

```
[P2] Device row — AudioutCore/Sources/AudioutSharedUI/DeviceRowView.swift:3290-3339 — no screenshot
  tell:  B decorative motion built on spec
  now:   `flashRow()` inserts a full-width gold layer behind the row and pulses its opacity
         0 → 1 → 0 over 0.5 s. It has no caller anywhere in `AudioutCore/` except its own
         test (`DeviceRowConnectionStateTests.swift:671`). Its doc says it exists "so a host
         can draw the eye to a row that just changed".
  why:   An attention flourish nobody asked for, written for a hypothetical host, kept alive
         by a test. That is the plainest form of an unspecified default: the effect is there
         because good UI is assumed to have one, not because a real event needs it. It also
         quietly claims gold for something that is not audio state.
  fix:   Delete `flashRow()`, `flashLayer`, `test_flashRow` and the test. If a real event
         later needs to draw the eye, it gets its own decision then.
```

```
[P2] Device row and Main Audio row, mute and Equalizer — AudioutCore/Sources/AudioutSharedUI/DeviceRowView.swift:974, :1005; AudioutCore/Sources/AudioutPopoverUI/MainOutRowView.swift:630; AudioutCore/Sources/AudioutSharedUI/RowAccessorySymbol.swift:51, :55 — no screenshot
  tell:  C system drift — the form stopped carrying the state, against the app's own rule
  now:   Both engaged marks now draw the OUTLINE symbol and change only the ink.
         `updateMuteTint()` passes `Self.muteRestSymbolName` in every state (:974);
         `updateEQButton()` passes `Self.eqRestSymbolName` in every state (:1005);
         `MainOutRowView.updateMuteTint()` does the same (:630). The two filled symbols,
         `RowAccessorySymbol.muteEngaged` (:51) and `.equalizerEngaged` (:55), are still
         declared, still referenced by the constants at DeviceRowView.swift:323 and :327,
         and still in `allNames`, which makes `make-app.sh` fail the build if they are
         missing from the asset catalogue — but nothing draws them. The doc comments
         directly above all three methods still describe the filled square with the marks
         punched through, and so does DESIGN.md's Mute Button and Equalizer Door sections.
  why:   Two controls sit 6 pt apart, the same 17.5 pt outline square at the same weight, and
         the only thing separating engaged from at rest, and mute from Equalizer, is hue:
         periwinkle against green against neutral. HaloRingView's own header states the rule
         the app set for itself, "the FORM carries the state, not just the color". The rows
         have lost it, the symbols drawn to carry it are shipped and unused, and every
         comment in the area still describes the retired version, so the next reader will
         believe the wrong thing.
  fix:   Decide it once and make the code and the comments agree. Either draw
         `muteEngaged` / `equalizerEngaged` for the engaged states as the comments say, or
         keep the ink-only version, delete the two unused symbols and their constants, and
         rewrite the three doc comments and DESIGN.md's two component sections to describe
         what actually ships.
```

```
[P3] Output Speakers card — AudioutCore/Sources/AudioutSharedUI/DeviceRowView.swift:3543-3545 vs AudioutCore/Sources/AudioutSharedUI/HaloRingView.swift:249-252 — popover-light.png, popover-connection-light.png
  tell:  B surface habit — one visual device, two unrelated meanings
  now:   A dashed stroke means "connecting" on the icon ring (HaloRingView.swift:252) and
         "never measured" on the Offset chip (SyncChipCell, DeviceRowView.swift:3543). Both
         can appear on the same row band, about 1000 pt apart on the same line.
  why:   The dashed outline is the standard placeholder-slot convention imported from design
         tools, and the app also uses it as its "in progress" form. One reader, two readings.
         The chip's reason is recorded (D10: zero reads as finished, "Not set" reads as an
         invitation) so the intent is real, but the dash is not what carries it — the words
         are.
  fix:   Drop the dash from the untuned chip and let the solid hairline border and the
         `label3` "Not set" text carry it, leaving the dash to mean "in progress" alone.
```

```
[P3] Mixer, Source column — AudioutCore/Sources/AudioutSharedUI/FeedPillView.swift:33-51, :105 — popover-light.png, popover-feed-composite-light.png
  tell:  C web-shaped control / inert thing dressed as an interactive one
  now:   Every value in the Source column is a bordered capsule with a fill and an edge
         ("System", "Music", "+5"), up to three per row across twelve rows. `hitTest`
         returns nil (:105): none of them is clickable, and the overflow "+5" does not
         expand.
  why:   On macOS a small bordered capsule with a word in it reads as a token you can press
         or remove. Dozens of them on one screen, none pressable, is the most repeated
         element in the panel promising something it does not do. This is an owner's call
         carried over verbatim from the iPhone companion, so it is a chosen thing that still
         reads as a tell.
  fix:   If they stay inert, drop the fill and the edge and let the text carry it, separated
         by the column's own spacing; the row already has a well-defined grid. If the "+5"
         is meant to be reachable, make that one a real control with a menu.
```

```
[P3] Failure diagnosis panel — AudioutCore/Sources/AudioutCore/ConnectionState.swift:115 vs :119 — popover-connection-light.png, popover-connection-dark.png
  tell:  D copy — jargon, and one action named two ways
  now:   "The speaker is visible on the network but isn't answering AirPlay requests. It may
         be stuck or held by another app. Power-cycle it, then try again." The sibling
         string four lines down (:119) calls the same physical act "restart the speaker".
  why:   "Power-cycle" is engineer's shorthand, and PRODUCT.md's design target is a general
         Mac user with no audio vocabulary. Two names for one action in adjacent strings is
         the drift that happens when each case is written on its own.
  fix:   "The speaker is on the network but isn't answering. It may be stuck, or another app
         may be holding it. Turn the speaker off and on again, then try again."
```

```
[P3] Output Speakers "+" menu — AudioutCore/Sources/AudioutPopoverUI/PopoverController.swift:3386-3387 — no screenshot
  tell:  C system drift against the app's own documented pattern
  now:   The Bluetooth pairing list is introduced by a plain `NSMenuItem` titled
         "Bluetooth pairings" with `isEnabled = false` (:3387), and the items under it are
         not indented.
  why:   DESIGN.md's "Menu Section Headers Indent Their Entries" rule says a section header
         is an `NSMenuItem.sectionHeader` and its entries sit one indentation level in, and
         it says in as many words that a hand-disabled plain item does not substitute. This
         menu is the one place in the slice that builds a section header, and it uses the
         version the design record rules out.
  fix:   `NSMenuItem.sectionHeader(title: "Bluetooth pairings")` with
         `indentationLevel = 1` on each Connect item, matching the rule.
```

## 3. Repeated patterns across the slice

**Brand where orientation belongs.** The splash and the centred wordmark are the same instinct twice: the product's name placed in front of, or on top of, the thing the user came for. Both are recorded owner-side decisions, so neither is careless, but together they are the part of this slice that reads as a website's habits applied to a menu-bar utility. Every other identity decision in the panel is the opposite and is better for it: gold appears only when audio is flowing, the header goes gold only while its section is sounding (`setCardHeaderLive`, PopoverPanelViewController.swift:976-984), and the toolbar seats are explicitly neutral because "a header seat is navigation".

**The doc record has drifted from the code in three places in this slice, all in the same direction: the record describes a version that was replaced.** DESIGN.md's Surface Header Strip section describes four `SurfaceToolbarSeatCell` items on a 30 x 26 pt seat at radius 10, while the shipped strip is one stadium capsule holding three tabs, a circular Pin and a centred wordmark (SurfaceToolbar.swift:40-80, :181). `AudioutCore/Sources/AudioutPopoverUI/AGENTS.md` states the opposite again, that the strip is bordered `NSToolbarItem`s with AppKit's own `selectedItemIdentifier` and "never an authored fill", which the seat cell contradicts. And the mute and Equalizer doc comments describe filled symbols the code no longer draws. None of this is visible to a user, but the next agent reading any of the three will build on something that is not there.

**Almost every constant in this slice is measured and its reason is written down beside it.** `PopoverColumnGrid` is 858 lines of named geometry where each value carries a doc comment saying what it was measured against. That is the opposite of the padding-with-no-scale tell, and it is worth saying plainly because it is rare.

## 4. Positives

- `CardView` draws no chrome at all: no shadow, no material, no rounded tile. The one separator between sections is a 1 px line, and the class comment names the decision (CardView.swift:8-15, :103-107). This is the single most common slop scaffold refused on purpose.
- The connection ring carries state by shape, not only by colour: no ring, dashed, solid, heavier solid. Under Reduce Motion the dashed form survives and only the pulse drops (HaloRingView.swift:13-38, :349-372).
- The rail's connect pulse is one authored moment tied to a real event, drawn as a stroke with an explicit "a stroke, never a shadow" rule, cancelled under Reduce Motion, and it leaves nothing on the layer at rest (BusRailOverlayView.swift:660-720, HaloRingView.swift:384-448).
- The failure panel names the cause and the fix per cause, puts Return on "Try again" and Escape on dismiss, and hides "Copy details" when there is nothing to copy (ConnectionDiagnosisView.swift:104-105, :133-138, :210).
- The "+ / -" footer is a stock `NSSegmentedControl` at the card's leading inset, the same shape System Settings and Contacts use, with a comment saying so and refusing the full-width labelled button (PopoverController.swift:29-42).
- The menu-bar icon is always a template image, and the comment records the accent-coloured version that shipped once and became unreadable on a matching wallpaper (StatusItemIcon.swift:10-20).
- The Touch Bar replaces Apple's Control Strip with the same controls in the same SF Symbols because the system's own volume keys measurably go dead against the app's aggregate device, and it says so (TouchBarFullBar.swift:7-33).

## 5. Unverified impressions (screenshot only, no code anchor)

- In `popover-dark.png` and `popover-resting-ring-dark.png` the gold section headers and the Main Audio ring look as though they carry a faint resting bloom. I could only anchor `Tokens.Color.glow` to transient pulses that remove themselves, so this may be PNG compression around saturated gold on near-black rather than anything drawn.
- In `popover-feed-composite-light.png` the "Overflow Speaker" row has the gold live wash but a hollow rail node, while the two washed rows above it have filled ones. I did not trace the predicate that decides node fill against the wash.
- The vertical gap between the "Connect a speaker" row and the "+" footer below it reads larger than every other gap in that card. Two add-shaped affordances stacked one above the other also read as one affordance too many, though they do different things (the row pairs a Bluetooth speaker, the footer opens a menu).

## 6. Screens and states in my slice I could not see

No screenshot exists and I could not render one, so these were audited from source alone:

- The menu-bar status item in all three states (idle, streaming, failure) and its right-click menu.
- The surface header strip: the wordmark, the three tabs, Pin, the shared capsule, and the selected tab's name reveal.
- The first-open splash.
- The volume HUD.
- The quitting indicator.
- The Touch Bar.
- Inside the mixer: a muted row, a row with a shaped Equalizer curve, an open sync drawer, the first-join alignment note, the "Removed, Undo" offer, and a row with the AP1 micro-tag.
- The silence-fallback banner, the system-AirPlay note banner, and the unregistered note.
- The Output Speakers "+" menu and the running-app picker.
- The device list scrolled past twelve rows, and the panel under Increase Contrast, the Subtle accent dial, or Reduce Transparency.
