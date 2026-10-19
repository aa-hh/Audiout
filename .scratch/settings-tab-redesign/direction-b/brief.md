# Direction B: Settings as one Mixer page, no sidebar

**Thesis.** Settings becomes one scrolling page built from the Mixer's own parts: four cards with Mixer card headers, every setting a row on the Mixer's column grid with its control in the trailing column, and the card headers' folds as the only way to move around. Flip from Mixer to Settings and the chevrons, titles, names and trailing column stay at the same x.

## Assumptions (nobody could answer the discovery interview)

The impeccable context asks for one probe before inferring. This agent has no question tool and the orchestrating session said nobody can answer, so everything below rests on these readings. Each is a guess and can be overturned.

1. People open Settings rarely and with one goal: change one thing, enter a key, or check what is set. Nobody browses it.
2. The most common arrivals are the licence (from the Mixer's limit note or trial pill) and the Audio controls. Appearance is set once.
3. A page that scrolls is acceptable on Settings. On the Mixer it would not be, because volume and mute must stay one gesture away. Nothing on Settings is a kill switch.
4. "Match the Mixer and Speakers tabs" means matching the shared grammar (card headers, column grid, row ink, folds), not copying their content.
5. Alec wants Settings neutral unless a hue earns its place (see Colour).

## 1. Job and audience

The household Mac user from PRODUCT.md, in operate mode: they came to change one setting and leave. Secondary: a trial or unregistered user sent here to enter a key. They read the page top to bottom once, then return to the one card they use.

## 2. Outcome and proof

- Success: a person finds any setting in one look down the left edge (card titles, then row names at the Mixer's name column) and changes it without leaving the page.
- The licence state is readable without opening anything: it is the first card's note line and stays visible when that card is folded.
- Proof it belongs to the app: the header row, chevron, title, rule, column x positions and row height are the Mixer's, measured, not imitated.

## 3. Selected direction

### Structures weighed (the seed fixes "no sidebar, Mixer cards"; these are the arrangements inside it, most resonant first)

1. **Four cards, licence first and folded small, actions in its header.** Chosen.
2. Licence in the Mixer's note slot at the top of the panel as a tinted banner, three cards below. Rejected: a standing banner on a settings page reads as a warning even when the licence is fine, and the Mixer already owns that banner.
3. Licence as a page footer beside Run setup again and About. Rejected: a trial user who scrolls nowhere never sees it.
4. Cards ordered by use (Audio first). Rejected: reorders what people already know from today's sidebar for a small gain.
5. One flat list with no cards, section names as subsection headers only. Rejected: no fold at card level means no way to shorten the page.
6. Accordion with one card open at a time. Rejected: forcing one open card is a tab strip with extra steps, which is the thing the folder rule forbids.

`impeccable concept-seed` was not run: the orchestrating brief pinned this direction, and a pinned direction beats the roll.

### How sections are reached without a sidebar

By the card folds and nothing else. Each card header is one click target that folds its body, exactly as on the Mixer (chevron, title, 0.10 hover wash, 0.15 s fold on `FoldAnimator`'s clock). Fold state is kept for the life of the app process, the way the Mixer keeps its own (`transientCollapsed`), and resets on relaunch. A person who only uses Audio folds the other three once and Settings opens as three header lines and the Audio card for the rest of that session. With everything folded, the page is four title lines plus the licence note, which is a complete list of sections.

Optional, for Alec to accept or drop: Option-click on a card header folds or unfolds every card, the convention Finder and every `NSOutlineView` disclosure triangle already follow.

### Why this is not a second tab strip

`AudioutSettingsUI/AGENTS.md` says "Sections are sidebar rows, never tabs". The rule exists so Settings never grows a segmented control that swaps one pane for another. This direction has no switching at all: all four cards are on screen at once, they scroll with the content, and nothing is hidden unless the person folded it themselves. The rule would be rewritten to "Sections are cards on one page, never tabs; a new section becomes another card." `selectSection(at:)` (used by `AppDelegate` before presenting the licence sheet) becomes "scroll to card N and unfold it", and its tests keep driving it.

## 4. The page, card by card

Geometry is `PopoverColumnGrid`'s, rail gutter included, so every x matches the Mixer: chevron at 38.5 pt, card title at 58.5 pt (`headerTitleLeading`), row glyph in the 26 pt icon column from 38.5 pt, name at 73.5 pt (`nameColumnLeading`), slider column 297 to 447 pt, readout 453 to 493 pt, trailing column 499 to 699 pt, trailing inset 14 pt. The rail gutter stays empty on Settings; keeping it is what holds the titles still across a tab switch.

Ground: `WarmPanelView` (`panel`), one scroll view whose document is a `FlippedView`-style top-anchored column. A 1 pt `hairline` rule under the header strip, as the Scenes and Speakers hosts already draw, because content scrolls under the strip.

**Card header** (Mixer rank 1): 28 pt, `chevron.down` / `chevron.right` 16 pt wide in `label2`, title in `captionEmphasized` / `label2`, VoiceOver heading. Never gold here: the title turns `goldText` on the Mixer only while audio comes out of its rows, and no Settings row carries audio. **Card note** under it when the card has one: one truncating line, `detail` / `label2`, 18 pt, at `headerTitleLeading`, visible when folded. **Subsection header** (Mixer rank 2): 22 pt, `captionMedium` / `label3`, chevron at `subsectionHeaderLeading` (54.5 pt), also folds. **Card rule**: 1 pt `containerEdge` `RuleView` before every card but the first, starting at the icon column.

**Setting row**: a 16 pt SF Symbol in `label2` in the icon column; the name in `menuItem` / `label` on the first line; the control on that same line, trailing; the caption below in `caption` / `label2`, spanning from the name column to the trailing inset and wrapping. Minimum 42 pt (`bodyRowHeight`), 8 pt top and bottom. Switches sit flush to the trailing inset; pop-ups fill the 200 pt trailing column, like Main Audio's destination pop-up; radios start at the trailing column. A row whose control would carry live state reads it from the same source VoiceOver does.

### Card 1: License (only in builds with a licence server)

- Header: "License", then the key action as a small `.accessoryBar` button after the title, where "Manage speakers…" sits on Output Speakers: "Enter license…" or "Change…", plus "Buy Audiout" beside it when buying would help, plus "Check again" while a saved key has no verdict.
- Card note: the existing status sentence for the state (`licenseStatusLine` / `LicenseCopy.statusLine`), so the state is readable when folded. Full sentence in the tooltip and the spoken value when it truncates.
- Body: the check-in disclosure ("Audiout checks in with the license server once per launch…") at the name column, `caption` / `label2`, shown only when a check-in can fire.
- Buy Audiout stays a stock button. `AudioutSettingsUI/AGENTS.md`: the one gold in Settings is the licence sheet's Register.

### Card 2: General

- Launch at login (switch). When `SMAppService` lands in `.requiresApproval`, an inset `TintedNoteBackgroundView` in `ring` mounts under the row through a fold, Mixer inset-card geometry (from the icon column, 10 pt trailing inset, 4 pt above and below, 10 pt padding): "macOS needs you to allow Audiout in Login Items." with a small "Open Login Items…" button trailing.
- Reconnect last speakers when Audiout starts (switch), live hint as caption.
- Use Audiout's Touch Bar controls (switch). Row absent on a Mac with no Touch Bar.
- Share anonymous usage statistics (switch), live hint as caption.
- Subsection **Audiout Remote** (absent entirely in a build with no companion):
  - Allow control from iPhone on this network (switch). The launch-option override note mounts under it as a caption when an override is in force; the switch is disabled.
  - Invitation row, only while the switch is on: glyph `qrcode`, name "Get Audiout Remote for iPhone", caption "Scan with your iPhone's camera, or open audiout.app/remote.", a small "Open audiout.app/remote" button under the caption, and the 72 pt `RemoteInviteView` tile with its address in the trailing column. The tile hides once a phone is remembered; the text and button stay.
  - "Remembered iPhones" caption (`captionEmphasized` / `label2`) at the name column, then one row per phone: `iphone` glyph, the phone's name, and in the trailing column "Allowed" or "Denied" in `caption` / `label2` and the existing `minus.circle.fill` remove button. Hidden while the list is empty.

### Card 3: Appearance

- Theme: the three existing theme tiles (custom drawn, absolute sRGB mirrors, gold selection ring), right-aligned across the slider, readout and trailing columns, labels under each. Caption "Follow the system, or force light or dark."
- Accent: two stock radios, "Full gold" and "Subtle", starting at the trailing column. The live hint is the caption; the static line "How strongly meters, dots, and rings use the brand gold." moves to the row's tooltip and VoiceOver help.

### Card 4: Audio

- Volume when connecting a speaker: `RowVolumeFader` (the Mixer's own fader, `WarmFaderCell`) at the slider and readout columns in its idle form (`rim` fill, `emberText` readout), so the default reads as the exact control a speaker row will show when it connects. Live hint as caption. NEEDS ALEC'S YES, because the idle readout is in the gold family; the fallback is a stock `NSSlider` in the same columns with the readout in `label2`.
- Restore Mac audio if speakers don't reconnect (pop-up: Never, 1 minute, 2, 5, 10 minutes), live hint. Row absent when the host passes no wake-restore controller.
- Keep Bluetooth speakers streaming during pauses (pop-up: Never, 5, 10, 30 minutes), live hint.
- Subsection **Apps that stay on this Mac**: the line "Audio from these apps always plays on your Mac, never sent to speakers." at the name column, then one row per app (its icon in the icon column, its name, `minus.circle.fill` remove in the trailing column), then an "Add app…" row built like the Mixer's "Pair Bluetooth speaker…" row: a borderless button, `plus` on the icon column, opening the existing menu of running apps plus "Choose from Finder…".
- Subsection **Advanced**, folded by default, through `FoldingClipView` as today: Audio buffer (pop-up of 1,000 / 1,500 / 2,250 ms) with its live hint, and under it the existing 20 pt status line (small spinner, "Reconnecting speakers…", then "Speakers reconnected" or the partial-failure line). Under a launch-option override the pop-up row is replaced by the existing locked note. The whole subsection is absent when the backend reports no buffer support.

### Page footer

After a `containerEdge` rule from the icon column: small stock rounded buttons "Run setup again…", "About Audiout…", "Check for Updates…" (the last only when the host wires updates), starting at the icon column, 28 pt row like the Mixer's `CardFooterView`.

## 5. States covered

| State | What changes |
|---|---|
| Source build (no licence server) | License card absent; General is first |
| Unregistered | "Enter license…" + "Buy Audiout"; note "Unregistered. Audiout keeps working, on one speaker at a time, until it has a license key."; no disclosure |
| Trial running | "Enter license…" + "Buy Audiout"; note "Trial · 3 days left" (the Mixer pill's own copy); disclosure shown. See open decision 4 |
| Trial ended | "Change…" + "Buy Audiout"; note "Your trial has ended. Audiout plays on one speaker at a time until you buy." |
| Registered | "Change…"; note "Registered. Thank you for supporting Audiout."; disclosure |
| Refused key | "Change…" + "Buy Audiout"; note names the reason, e.g. "This key was refunded, so Audiout plays on one speaker at a time." |
| Saved, not verified | "Change…" + "Check again"; note "Your key is saved. Audiout hasn't been able to verify it yet." |
| Login Items approval needed | ring inset note under Launch at login |
| iPhone control off | invitation row and QR unmounted; remembered phones still listed if any |
| iPhone control on, no phones | invitation row with QR tile |
| iPhone control on, phones listed | invitation text and button without the tile; "Remembered iPhones" and phone rows |
| Override in force | switch disabled, caption note under it |
| Touch Bar absent | Touch Bar row absent |
| No companion offered | Audiout Remote subsection absent |
| Advanced closed / open / applying | folded; open with pop-up; open with spinner and "Reconnecting speakers…" |
| Buffer locked by launch option | locked note replaces the pop-up row |
| No excluded apps | the explanatory line and the "Add app…" row only |
| Everything folded | four header lines, the licence note, the footer |

## 6. Interaction and layout

- **Height.** The surface frame is measured once per open and never resized by a screen swap. The open page runs about 1,200 pt; the surface opens at the same height as the other tabs (711 pt in the renders) and the page scrolls under the header strip on an overlay scroller. Folding shortens the scroll, never the window. Settings still publishes no pane size.
- **Keyboard.** Tab walks headers and controls top to bottom; Space on a focused header folds it. ⌘4 still lands here.
- **VoiceOver.** Card and subsection titles are headings, so the heading rotor is the section list. A folded header speaks "collapsed". The licence note is spoken as part of the License heading's value.
- **Reduce Motion.** Folds land at their end state in the caller's turn, as every other fold does. The buffer spinner is left out; the words carry it.
- **Increase Contrast.** Every colour above is a `Tokens` colour with its own Increase Contrast value; the tinted note gets its 1 pt edge; views that draw call `redrawOnAccessibilityDisplayChange()`.
- **Light.** One flat `#FAFAFB` ground; cards are separated by the `containerEdge` rule alone, as on the Mixer. No fills behind cards in either appearance.

## 7. Components

**Reused as they are:** `WarmPanelView`, `RuleView`, `FoldingClipView` and `FoldAnimator`, `HoverTracker` with `PopoverColumnGrid.fillRowWash`, `PopoverColumnGrid` constants, `TintedNoteBackgroundView`, `RowVolumeFader` (pending the yes), `RemoteInviteView` at 72 pt, the theme tiles, stock `NSSwitch` / `NSPopUpButton` / `NSButton` (rounded, small, `.accessoryBar`, radio) / `NSProgressIndicator`.

**Changed:**
- The Mixer card header (built today inside `PopoverPanelViewController.beginCard` in `AudioutPopoverUI`): its header row, card note line and subsection header row move to `AudioutSharedUI` as public views, because `AudioutSettingsUI` cannot import `AudioutPopoverUI` (the Popover target depends on Settings). The Mixer then builds its headers from the moved views. `CardView` itself stays in the Popover target: the rail reads its fold generation and closing guard, which Settings does not need.
- `SettingsForm.row` is rebuilt on `PopoverColumnGrid` columns (glyph, name in `menuItem`, caption spanning below, control on the name's line). `SettingsForm.sectionHeader` and its `NSBox` separators go.
- `SettingsRootViewController` stops being a split: one scroll view, four cards. `SettingsSidebarViewController` is deleted.
- The excluded-apps list loses its bordered box and becomes rows plus an "Add app…" row. The remembered-phones list does the same.

**New custom drawing:** none.

## 8. Colour

**Proposal: Settings stays neutral.** Gold means audio is flowing or a call to action, green means the Mac can reach a speaker, and nothing on this page does either. A third tab hue would be decoration. The engaged Settings seat in the header strip is already neutral, which matches.

Gold that still appears, all of it already shipped or flagged:
- The theme tile selection ring (selection, shipped).
- The fader's idle `emberText` readout and `rim` fill, only if Alec says yes to reusing `RowVolumeFader`.

No `speakersAccent`, no permission hues, no `systemGreen`, no gold Buy button.

On switches and radios: stock controls take the Mac's own accent colour. The comp draws them in graphite because that is what the renders show.

## 9. Open decisions for Alec

1. **Drop the sidebar and accept one scrolling page.** The cost is a page that scrolls; the gain is Mixer-identical geometry and no second navigation idiom. Rewrites the folder rule.
2. **Settings hue: neutral** (recommended above), or name a hue. NEEDS ALEC'S YES either way, since it closes the open question.
3. **Reuse the Mixer fader for "Volume when connecting a speaker"**, which brings the idle `emberText` readout onto Settings. NEEDS ALEC'S YES. Fallback: stock slider, `label2` readout.
4. **Trial copy and buttons in Settings.** Today a running trial with its key issued reads "Registered. Thank you for supporting Audiout." with only "Change…" and no Buy button (the trial key is stored, its verdict is active). This direction shows the Mixer pill's "Trial · N days left" as the note with "Enter license…" and "Buy Audiout". That is a behaviour change in `refreshLicenseStatus`, and it reuses existing copy only.
5. **License card first.** It is the one setting that changes how many speakers play; folded it costs 52 pt. Alternative: last, before the footer.
6. **Fold memory**: for the process's life, matching the Mixer (proposed), or across launches like the Equalizer's Advanced fold (`eqAdvancedExpanded`).
7. **Option-click folds all cards**: keep or drop.
8. **Row glyphs.** Proposed SF Symbols: `power`, `arrow.clockwise`, `keyboard`, `chart.bar`, `iphone`, `qrcode`, `circle.lefthalf.filled`, `paintpalette`, `speaker.wave.2`, `laptopcomputer`, `pause.circle`, `timer`, `plus`. They give each row the Mixer's icon-then-name shape; dropping them leaves the icon column empty and the names hanging at 73.5 pt.

## 10. Found while reading

- The Settings status line has no trial sentence (decision 4 above).
- inputs.md places "Reconnecting speakers…" under Restore Mac audio; in code it is the Audio buffer's apply status (`AudioSettingsViewController`, `applyStatusLabel`). The comp puts it where the code does.
- inputs.md's hard constraint 3 says "no brand lockup", but the Speakers render and DESIGN.md both show the centred "Audiout" lockup. The comp copies the render faithfully, lockup included.
- With `RowVolumeFader`, the readout says "35 %" (`VolumePercent`) while the hint says "35%" (`percentLabel`). One of the two formats should win.

## Comp

`comp.html`, dark and light side by side at 1x:
1. Full page: registered, iPhone control on with no phones, Touch Bar Mac, Advanced closed. A dashed line marks 711 pt, the height the other tabs open at.
2. Trial with 3 days left, top of page: no Touch Bar, Login Items approval note, one remembered phone.
3. Scrolled to the bottom with Advanced open and applying.
4. Everything folded.
