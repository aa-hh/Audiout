# Direction A: Speakers twin

Settings takes the Speakers tab's sidebar shape and page grammar whole. The licence gets the slot Main Audio has on Speakers: one plate under a title at the top of the sidebar. The sections are the list under it. Every page is a `PageHeaderView` over `GroupedSectionView` cards of `ListRowView` rows. The thing Settings does with that grammar that Speakers does not: every row carries the control that changes it in the trailing slot, and its caption says what the current value does.

Comp: `comp.html` in this folder. Dark and light side by side, frames for General, iPhone, Appearance, Audio and the licence trial, then a strip of smaller state fragments.

## Assumptions (no discovery interview was possible)

- Nobody could answer shape's interview, so these are my readings, stated plainly. Any of them can be overturned.
- The person opening Settings comes rarely and for one thing: turn on Launch at login, exclude Zoom, check how many trial days are left, enter a key. Finding that one thing beats reading the whole page.
- "Match the Mixer and Speakers tabs" means the same parts, spacing and inks, so that switching from Speakers to Settings looks like moving between two pages of one tool. It does not mean giving Settings a costume of its own.
- Splitting General into three pages (General, iPhone, License) is fair game as composition. Nothing is dropped and every string comes from the code, except the three lines marked new below.
- The popover is a key window while in use, so stock switches and the slider show the Mac's accent colour (blue by default). The shipped renders show them grey because they were drawn headless. The comp draws them blue and says so.

## 1. Job and audience

General Mac users with two or more speakers, arriving with one setting in mind, rarely, often while sound plays in another room. They need to find the row, read what it will do, flip it, and leave.

## 2. Outcome and proof

- Success: the setting is found by scanning the sidebar and one card, without reading every hint.
- Proof it belongs to the app: put Speakers and Settings side by side and the sidebar, page header, card edge, row height and caption ink are the same parts at the same positions (icon well at x 239, title at x 299, first card at y 190 in surface coordinates).
- Product truth the page must keep: the licence is the one commercial state, and a trial user must be able to see days left and buy without hunting. Today that lives in the middle of General, between usage statistics and the footer buttons.

## 3. Selected direction

**Visual authority:** DESIGN.md as it stands. No new tokens, no new custom drawing, no Settings hue.

**Structure.** The sidebar reads exactly like the Speakers sidebar:

| Speakers sidebar | Settings sidebar (this direction) |
|---|---|
| "System Audio" title over the Main Audio plate | "Audiout" title over a **License** plate (`key` glyph) |
| "Speakers" title over the Overview plate | "Settings" title |
| "Shown in Mixer" group of speaker rows | General, Appearance, Audio, iPhone rows |
| "Add scene" bar at the foot | nothing (the current sidebar's own doc says Settings has no add verb; kept) |

Settings still opens on General, as Speakers opens on Overview, the second item.

**What Settings does with the grammar that Speakers does not.** Three things:

1. **The licence takes the plate slot.** Main Audio heads the Speakers sidebar because everything flows through it. The licence heads Settings because it is the one page about this copy of Audiout rather than how Audiout behaves. A trial user sees it at the top of every Settings visit; a registered user sees one quiet plate.
2. **Every row carries its own control and a live caption.** Speakers' cards mostly list things. Settings' cards change things. Each `ListRowView` gets its stock control in the trailing slot and its caption is the existing live hint, the pattern the speaker page's "Show in Mixer" row already uses ("whose caption explains the current choice beside its pop-up"). One control vocabulary across the tab: a switch for on or off, a pop-up for a choice, a slider for a level.
3. **Titles above a box name a list or a picker; a row names itself.** This is the scene editor's rule ("Speakers" above its checklist) applied consistently: "Apps that stay on this Mac", "Remembered iPhones" and "Theme" sit above their boxes in `body` / `label2`, with a `noteLabel` under the box where the code already has an explanation. Cards of control rows carry no title. Rare actions (Run setup again…, About Audiout…, Check for Updates…) leave the card for a button band under it, where the scene editor puts "Delete scene…".

**Sequence and focal moment.** The eye lands on the sidebar's one plate, then the page header, then the first card. On General the focal point is the card of four switches. On License it is the status caption and the Buy Audiout row.

**Implementation consequence.** `PageHeaderView`, `ListRowView`, `GroupedSectionView`, `DeviceIconWellView` and `PlateRowView` are internal to `AudioutWindowUI`, and `AudioutSettingsUI` depends only on `AudioutCore` and `AudioutSharedUI` (`AudioutCore/Package.swift` line 293). Settings cannot reach them today. Either move them to `AudioutSharedUI` or add `AudioutWindowUI` as a Settings dependency and make them public. Moving them is the cleaner of the two; it touches every Speakers and Scenes call site's import only. `SettingsForm` then has no callers left and goes.

## 4. Scope and boundaries

- Fidelity: a production-ready direction for the whole Settings screen, three panes becoming five.
- Untouched: the header strip (copied from the Speakers render, Settings engaged showing its name), the 713 pt width, the 210 pt non-collapsing sidebar, About and the licence sheet themselves, Speakers and Mixer.
- Anti-goals: a Settings colour, a dashboard of state in the sidebar, any new custom-drawn view, gold anywhere except the theme tile's selection ring (which already exists).

## 5. States and ranges

Shown in the comp (full frames or the state strip) and how each behaves:

| Area | States |
|---|---|
| General | Touch Bar present (row shown) and absent (row not built, card is three rows). Launch at login waiting for approval: an extra row in the card under Launch at login, title "macOS needs you to allow Audiout in Login Items.", trailing "Open Login Items…", the Overview's "Local Network access is off" pattern. |
| iPhone | Switch off: the invitation card is unmounted, the "Remembered iPhones" list stays (today's behaviour). Switch on with no phones: invitation card with the QR tile. Phones listed: "Remembered iPhones" card, one row per phone, `iphone` glyph, name, "Allowed" or "Denied" in `caption` / `label2`, `minus.circle.fill` remove. Launch option in force: the switch is disabled and the row's caption becomes "A launch option is controlling this setting, so the switch can't change it." Build with no companion: the iPhone sidebar row is not built. |
| License | Unregistered, trial with days left, key saved but not verified (adds a small "Check again" before "Change…"), registered (Buy Audiout row removed), refused with the server's reason. Build with no licence server: the License plate and its title are not built, matching today's "hide the whole surface". |
| Appearance | Match system, Light, Dark; Full gold, Subtle. |
| Audio | Apps list empty (only the "Add app…" row) and with apps; Advanced closed (default) and open; buffer change in progress ("Reconnecting speakers…" with a small spinner as a note under the Advanced card, then "Speakers reconnected" or "Some speakers didn't reconnect. Reconnect them from the Mixer."); buffer locked by a launch option; Advanced not built when the backend can't take it. |

Ranges: the apps list and the phone list grow by one 44 pt row each; the pane scrolls past the surface's height ceiling as today. Captions run to two lines at 474 pt card width with a trailing control; the connect-volume caption needs three (see component changes).

## 6. Interaction and layout

**Sidebar (210 pt, stock `.sourceList`).** Section titles in `captionEmphasized` / `labelCool` (today's header uses `label2`; Speakers uses `labelCool`, so this aligns them). The License plate is the Speakers `PlateRowView`: 36 pt, `control` radius, `raised` in light and `label` at 5 % in dark, 1 pt `containerEdge`, `bodyEmphasized` name, `labelCool2` chevron, giving way to the stock selection pill when selected. Section rows are today's icon-and-label cells: General `gearshape`, Appearance `paintpalette`, Audio `speaker.wave.2`, iPhone `iphone`.

**Every page.** `PageHeaderView` with a non-editable `DeviceIconWellView` (the Main Audio page's plain-picture mode) showing the sidebar row's glyph, title in `heading`. A caption only where there is a state worth naming: License ("Trial · 9 days left", "Unregistered", "Registered", "This key was refunded", "Your key is saved") and iPhone ("Audiout Remote", the first mention the copy rules ask for). General, Appearance and Audio have none, like Main Audio. Cards are `GroupedSectionView` `.card` at the `row` radius (16 pt), the speaker page's choice, 14 pt in from the pane on both sides, 20 pt apart.

**Pages.**

- **General:** one card of four switch rows (Launch at login, Reconnect last speakers when Audiout starts, Use Audiout's Touch Bar controls, Share anonymous usage statistics). They are one instrument, so one box ("a box is earned by holding a different instrument, never by length"). Button band under it: Run setup again…, About Audiout…, Check for Updates… (the last hidden when the build has no updater).
- **iPhone (new section):** card one, the Allow control switch row. Card two, while the switch is on, the invitation: "Get Audiout Remote for iPhone" with its caption, and in the trailing slot the stock "Open audiout.app/remote" button beside the 72 pt `RemoteInviteView`. With the section on its own page the tile no longer needs to hide once a phone is remembered (it hid to save General's height), which also stops today's caption saying "Scan with your iPhone's camera" over a missing code. Then "Remembered iPhones" above its card.
- **Appearance:** "Theme" above a card holding the three existing theme tiles, "Follow the system, or force light or dark." as the note under it. Then a card with one row, "Accent", caption the live line ("Meters, dots, and rings glow in the full brand gold." / the Subtle line), and a pop-up (Full gold, Subtle) in the trailing slot. "How strongly meters, dots, and rings use the brand gold." becomes that row's tooltip and VoiceOver hint, the Overview rows' "longer sentence is its tooltip" rule.
- **Audio:** "Apps that stay on this Mac" above a card of app rows (16 pt app icon, name, `minus.circle.fill`) ending in an "Add app…" row (`plus.circle` in `label2`, the whole row one target opening today's menu of running apps plus "Choose from Finder…"); the existing sentence as the note under it. Then one card: Volume when connecting a speaker (stock slider and the existing readout well), Restore Mac audio if speakers don't reconnect (pop-up), Keep Bluetooth speakers streaming during pauses (pop-up). Then "Advanced" with a leading chevron, folding through `FoldingClipView`, over a card with the Audio buffer row.
- **License (new section):** card one: "License key" row, caption the status line, trailing "Enter license…" or "Change…" (plus "Check again" only while a saved key has no verdict). "Buy Audiout" row under it, caption "€30 once keeps everything, including updates." (the trial banner's own sentence), the whole row one target with a `labelCool2` `arrow.up.right` saying it opens the browser. The check-in disclosure sits under the card in the `noteLabel` style.

**Feedback and motion.** None new. Section switches are instant, as today. Advanced folds on the shared 0.15 s clock; under Reduce Motion it lands at once.

**Accessibility.** Plate and rows speak as today's sidebar rows; page titles and the box titles are VoiceOver headings ("Titles Are Headings"). Each switch keeps its row title as its label. Increase Contrast needs nothing new: every ink here already resolves through `Tokens`.

## 7. Constraints, reuse and open decisions

**Reused as is:** `PlateRowView` (License plate), the Settings source list cells, `PageHeaderView`, `DeviceIconWellView` (non-editable), `GroupedSectionView` `.card` with `radiusOverride` = `row`, `ListRowView`, `noteLabel`, `RemoteInviteView`, `FoldingClipView`, the theme tiles, stock `NSSwitch`, `NSPopUpButton`, `NSSlider`, `NSButton`.

**Existing components that change:**

- The five window-page components move to `AudioutSharedUI` (or become public), as in section 3.
- `ListRowView` gains a caption line limit per row (default 2, as today). Only the connect-volume row uses 3: its live hint is 98 characters beside a 200 pt slider-and-readout accessory. The alternative is dropping the readout well, since the caption already says "Connects at 35%"; I kept it because the inventory lists it.
- The Settings sidebar header ink goes from `label2` to `labelCool`, and the sidebar gains a second section (the "Audiout" title over the plate).
- Accent changes from two radio buttons to a pop-up, to keep one control per kind of decision in the trailing slot.

**New pieces:** none custom-drawn. Two new sections (iPhone, License) built only from the parts above.

**New copy (three lines, each needs a yes):**

1. Trial caption on the License key row: "Your trial has 9 days left. After that, Audiout plays on one speaker at a time." Today, as I read `GeneralSettingsViewController.refreshLicenseStatus` and `LicenseCopy.statusLine`, a running trial stores its trial key and gets `.active` back, so Settings says "Registered. Thank you for supporting Audiout.", offers "Change…" and hides Buy Audiout. Worth checking against what the server actually returns for a trial key; if I read it right, that is a bug regardless of direction.
2. The License page header captions reuse fragments of existing lines (listed in section 6); "Trial · 9 days left" is the Mixer pill's own text.
3. Section title "Audiout" above the License plate.

**Analytics:** `settings:pane_selected` sends the pane title, so it gains the values "iPhone" and "License". Add them to `docs/analytics-events.md` in audiout-shared before shipping. Every other event keeps its call site.

**Open decisions for Alec:**

1. **Settings hue: I argue neutral.** Gold means sound and calls to action, and green on Speakers means a speaker can be reached; nothing on these pages is either. A hue here would mean "this is Settings", which the sidebar shape already says. If you want one anyway, it should be fenced the way the Speakers green is (four named placements), and I would rather not spend a sixth meaning on chrome.
2. **Split General into General, iPhone and License?** This is the direction's biggest move. Without it, General goes back to holding the companion block and the licence, and the plate idea has nothing to sit on.
3. **License at the top as a plate**, or as the last plain row under "Settings". Top follows the Speakers shape and helps trial users; bottom is quieter for registered users.
4. **Card radius:** `row` (16 pt, the speaker page) as drawn, or `panel` (26 pt, the Overview). With up to four rows a card, 26 pt reads soft at the corners.
5. **Accent as a pop-up** instead of radios.
6. **Connect-volume row:** allow a three-line caption (as drawn) or drop the readout well.
7. **The three new copy lines** above.
8. **Should Buy Audiout be gold during a trial?** I left it stock: `AudioutSettingsUI/AGENTS.md` says the one gold in Settings is the licence sheet's Register, and the Mixer pill already nudges.

**Found in passing (not part of this direction):** inputs.md places "Reconnecting speakers…" on the wake-restore pop-up; in the code it belongs to the Audio buffer change (`AudioSettingsViewController.swift:731`). The comp follows the code.
