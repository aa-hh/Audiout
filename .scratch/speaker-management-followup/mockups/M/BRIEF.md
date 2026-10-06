# M: the Speakers tab, sidebar and overview merged

Made with impeccable `shape` from three inputs in this folder: `sidebar/BRIEF.md` (structure and the dot), `overview/BRIEF.md` (the Speakers overview page) and `copy/COPY.md` (every word; the owner delegated naming to it). `OWNER-BRIEF.md` and its later ruling stood in for the shape interview. Where the inputs disagree, "Resolved conflicts" says which won and why.

Line numbers are on `claude/speakers-nav` at 95f5fa60. Spot-checked 2026-10-04; the uncommitted edits in that worktree touch none of the cited lines.

Mockup: `mockup.html` (the moving highlight runs live), `mockup.png`, `mockup-dark.png`. The window shows the owner's 20 speakers after the search, Overview selected. Beside it: the dot, how the numbers fill in, and the sidebar strings that change. Below: four overview states drawn at 75 %.

## Job

The tab answers two questions. Where do I control what the Mac plays? Main Audio, first, on a plate like the overview's. Which speakers do I have, and which can I use right now? The sidebar lists every speaker with a two-state dot, and the overview counts the same rows so its numbers add up to the sidebar. App UI: scanning and native expectations come before expression.

## Sidebar

### Structure, top to bottom

| # | Row | Treatment |
|---|---|---|
| 1 | Section title "System Audio" | The existing header cell (`SidebarViewController.swift:1242-1265`): `Tokens.Font.captionEmphasized` (11 pt semibold), `Tokens.Color.label2`, flush with the cell's leading edge. |
| 2 | Main Audio plate | The plate treatment, unchanged: `PlateRowView` (`:906-946`), 36 pt, `Tokens.Color.raised` fill, 1 pt `Tokens.Color.containerEdge`, `Tokens.Layout.Radius.control`, 10 pt side inset; `DeviceIcon.mainAudioSymbolName` at the cell's leading edge (no dot slot); `Tokens.Font.bodyEmphasized`; `chevron.right` 10 pt semibold in `label3`. Selected, the source list's own pill stands alone (`:895-905`). Today `.mainOut` is a flat row with an empty dot slot (`:1180-1182`); it moves onto the plate path that `rowViewForItem` and `heightOfRowByItem` give `.speakersOverview` (`:1139-1166`). VoiceOver: "Main Audio". |
| 3 | 16 pt gap | A non-selectable spacer row: no text, no menu, no drop, nothing spoken. It separates the two sections. |
| 4 | Section title "Speakers" | Same style as row 1. New, because the copy names the section. |
| 5 | Overview plate | Today's Speakers plate (`hifispeaker.2`), relabelled "Overview". VoiceOver "Speakers overview", replacing "Speakers, manage speakers" (`:1178`). Opens the Speakers page. |
| 6 | Subsection "Shown in Mixer" | A group row as today (drop target, never folds). New style: `Tokens.Font.caption` (11 pt regular), `Tokens.Color.label3` (its own doc names subsection headers as a `label3` job, `Tokens.swift:117`). Text starts 16 pt in from the cell's leading edge: `SidebarPresenceDotView.side` 9 (`:955`) + `dotToIconGap` 7 (`:1330`), so it lines up with the speaker icons. No gap between the Overview plate and this row. Holds When available and Always speakers, and This Mac. |
| 7 | Speaker rows | Geometry unchanged, new dot. A hidden speaker in use is a 40 pt row with the caption "Shown while playing". |
| 8 | Subsection "Hidden unless playing" | Same style as row 6. Still only when it has rows, still folds through the stock Show/Hide. |
| 9 | Add scene bar | Unchanged. |

**Why the rows are not indented.** Finder and Mail indent to show nesting, but the name column cannot spare the width. The code's note says 210 pt fits "MacBook Pro Speakers" (139.9 pt) and 200 pt did not; that was before the dot. With the dot slot the name column is about 128 pt (210 − 28 cell insets − 46 for dot, gap, icon, gap − 8 trailing), so that name already truncates. One indent level (about 16 pt) would cut every name to about 112 pt. Nesting comes instead from the section titles keeping the outer column, the subsection headers stepping in 16 pt at regular weight in `label3`, and the 16 pt gap between the sections. Source lists have one stock header level; the header cell is already custom (`makeHeaderLabel`), so the second style is a font, colour and constraint constant.

**Caption width.** "Shown while playing" is 106.1 pt in the 11 pt caption font the row uses (`statusLabel`, `Tokens.Font.caption`, `SidebarViewController.swift:849`), inside the 128 pt column. At 13 pt it would be 122.4 pt, still inside. Today's "In the Mixer while it plays" is 132.0 pt and truncates. Measured in Chrome's system font, which reproduces the code's 139.9 pt for "MacBook Pro Speakers".

### The dot

Two states (owner ruling). Filled: the speaker is reachable on the network, connected ones included. Ring: anything else, meaning unavailable, can't be found, or not seen yet this launch.

**Colour: `Tokens.Color.rim`** (`Tokens.swift:311-314`: dark `#6B767D`, dark Increase Contrast `#818B90`, light `#66717A`, light Increase Contrast `#586269`). It is the Mixer's connected colour:
- The glyph ring's connected form strokes `rim` (`HaloRingView.swift:243-249`). That view carries connection state alone; `joinsSpine` swaps in gold only on Main Audio's ring.
- The Mixer's status dot, connected and silent, is a hollow ring in the ring's colour, `rim` (`HaloRingView.swift:262` hands it over, `RouteArmedDotView.swift:183-186` strokes it), 1.5 pt (`PopoverColumnGrid.swift:397`). Ring strokes elsewhere on the row are 1.6 pt (`PopoverColumnGrid.swift:325`).
- Gold appears only while playing: a gold disc with a 1 pt `ember` edge (`RouteArmedDotView.swift:181-182`, `PopoverColumnGrid.swift:393`) and the rail's gold member node (`MembershipBusView.swift:268-272`). Gold means live audio (`AudioutWindowUI/AGENTS.md`), so it cannot mark "reachable".

**Geometry.** 9 pt, unchanged. Filled: a `rim` disc. Ring: a 2 pt `rim` stroke inside the 9 pt edge (path inset 1 pt), leaving a 5 pt hole. 2 pt instead of the Mixer's 1.5 pt because the ring also stands for "can't be found", and on the darker end of the estimated dark ground it measures 2.99:1, where a thinner anti-aliased line renders below its colour's ratio. Same width in every mode; Increase Contrast changes only the colour.

**Selected rows.** `rim` fails on both selection pills, so a selected row draws the same shape in the row's text colour: `Tokens.Color.label` on the grey pill (8.44 dark, 11.58 light), white (`NSColor.alternateSelectedControlTextColor`) on the accent pill when the list has focus (4.8 to 6.4). The cell reads its `backgroundStyle` (`.emphasized` is the accent pill) and its row's `isSelected`. Today's ember dot has the same problem; this fixes it.

**Contrast of `rim`** (WCAG ratios). The sidebar ground is the system source-list colour, not `panel` (`MixerWindowController.swift:169-173`), unmeasured since the 2026-09-03 migration, so it is bracketed at `#E8E8EA`–`#F5F5F6` light and `#1E1E20`–`#2C2C2E` dark.

| `rim` against | Light | Light, IC | Dark | Dark, IC |
|---|---|---|---|---|
| Sidebar ground | 4.08–4.58 | 5.10–5.73 | 2.99–3.58 | 4.00–4.78 |
| Grey selection pill | 3.43 | 4.29 | 2.03 | 2.71 |
| Accent selection pill | ≈1.2 | ≈1.2 | ≈1.2 | ≈1.2 |

Today's `ember` measures 2.78–3.32 on the same dark band, so `rim` is no step down. The accent dial does not remap `rim` (it did remap `ember`), so the dots look the same in Full and Subtle. Header inks on the ground band: `label2` 5.09–7.41, `label3` 4.64–5.54.

### Row states

| Speaker | Dot | Row ink | Spoken suffix and tooltip |
|---|---|---|---|
| Reachable, including connected or playing | filled | `label` | none |
| This Mac | filled | `label` | none |
| Unavailable: seen this launch, out of reach now | ring | `label3`, as today (`:1300`) | ", unavailable" |
| Can't be found: no live device since Audiout opened | ring | `label3` | ", can't be found" and tooltip "Can't be found", once the first search has settled (open question 3); before that, ", unavailable" |
| Hidden and in use | filled | `label`, 40 pt row, caption "Shown while playing" | adds ", shown in the Mixer while playing" |
| Selected | same shape in the row's text colour | pill ink | unchanged |

The sidebar's can't-be-found speakers and the overview's can't-be-found row must be one set. Today they differ: the sidebar calls any record with no live device lost (`SidebarViewController.swift:457-459`, `:468`), while the page leaves out This Mac and waits for the search (`SpeakersPageViewController.swift:247-248`). The merged rule is under "The counting rule" below, and both read it.

Also drawn in the sidebar brief's mockup and unchanged: the second group folded (stock Show on hover) and a drag onto the other group's header (stock drop outline).

### Today's "playing" state: removed

1. The owner's rule allows two states.
2. It never meant playing. It fires on `connectionState == .connected` (`SidebarViewController.swift:469`), so a muted or silent connected speaker went gold. The Mixer turns its dot gold only when the row is route-armed and connected (`DeviceRowView.swift:683`), so the sidebar already disagreed with the Mixer.
3. The folder rule says the sidebar dot shows presence, never routing; gold is reserved for live audio.
4. Nothing is lost. A connected speaker is reachable, so it draws filled. The Mixer shows what plays, and the hidden-and-in-use caption stays.

For the builder: `SidebarPresenceDotView.State` drops `.playing` and `.lost`; the ", playing" suffix goes (`:1316`); `SidebarActionsTests.swift:123-124` pins `.playing` and `.lost` and changes with it. No analytics event changes.

### A speaker the Mac can't find: what still marks it

The warning glyph leaves the sidebar only. Still there:
- Right-click: **Forget "Name"…** appears only for these speakers (`SidebarViewController.swift:388-391`, several selected `:412-417`).
- Tooltip "Can't be found" on the row (new; today the tooltip is only the id of a speaker whose details are unknown, `:1191`, and the two combine).
- VoiceOver keeps ", can't be found" (`:1314`).
- Selecting the row opens its page: failure glyph, "Can't be found", and Forget (`DeviceDetailViewController.swift:641`).
- The overview carries the count and "Forget N speakers…".
- A speaker with unknown details still reads "Missing speaker".

### Right-click menu

Order unchanged (`SidebarViewController.swift:367-392`). Shown speaker: Hide from Mixer, **Show even when unavailable** (ticked = Always, unticked = When available), separator, Speaker settings…, then for a speaker that can't be found a separator and Forget "Name"…. Hidden speaker: Show in Mixer. Several selected: Hide N speakers from Mixer / Show N speakers in Mixer.

### Sidebar accessibility

- The dot stays drawing only; the row's label carries the state (`:1308-1321`).
- Shape carries the state, so one hue is enough and colour blindness changes nothing.
- Increase Contrast resolves `rim`'s own values live; the view already repaints on the display-options change (`:965`).
- Nothing animates.
- Plates are ordinary selectable rows. Section titles, subsection headers and the gap row are not selectable, so arrow keys skip them.

## Speakers overview page

### Decisions

1. **Five tiles, always, in one strip.** AirPlay · Bluetooth · Cast · This Mac, a 1 pt `containerEdge` rule, then **Unavailable**. A kind with no speakers shows 0, so the strip never changes shape and always adds up.
2. **"Available" labels the four kind tiles.** A caption above them in `Tokens.Font.captionEmphasized` / `label2`, starting at the strip's 18 pt inset. The rule before Unavailable runs the strip's full height (inset 2 pt top and bottom), so the caption reads as belonging to the left four only. Without it, "4 AirPlay" reads as a total, the misreading the owner hit.
3. **Each speaker counted exactly once.** The header caption is the total, "20 speakers". 4 + 0 + 3 + 1 + 12 = 20 for the owner's fleet, and 20 is the sidebar's row count.
4. **Unknown kind counts as Unavailable; its tile goes.** A record's kind is `nil` only when the Mac has neither a live device nor saved details for it (`SpeakerLibraryController.swift:302-303`: `kind: device?.kind ?? metadata?.kind`), so it is never available.
5. **Unavailable = unavailable + can't be found** (owner ruling). Its glyph is the sidebar's ring (`SidebarPresenceDotView` in its `.away` state). The sidebar's ring count and the Unavailable number always match.
6. **The can't-be-found row stays, shown only when true and only after the search.** "6 speakers can't be found" with **Forget 6 speakers…** (shipped strings, `SpeakersPageViewController.swift:261-263`). It sits directly under the strip, and its glyph is the same 9 pt ring, so it reads as part of Unavailable rather than more speakers on top. The red triangle goes (owner ruling). Its tooltip says what the title cannot: "6 of the 12 unavailable speakers haven't appeared since Audiout opened." followed by the shipped scene sentence ("Forgetting them takes them out of 2 scenes.", `SpeakersPageViewController.swift:256-257`).
7. **No search status line.** The spinner, "Looking for speakers…", the green check, "Done looking" and "All N speakers found" all go. While a number is unknown it shows a placeholder with a moving highlight (the owner's "shimmer"); each number replaces its own placeholder when its category is known.
8. **Row order:** strip, can't-be-found row (only when true, only after the search), Bluetooth access is off (only when true), Pair Bluetooth speaker… (always).
9. **A count of 0 draws in `label3`**, one step quieter than `label`. Glyph and label ink unchanged.
10. **Strip glyphs use the outline symbols** so all five tiles share one stroke: `airplayaudio`, `radio` (the current Bluetooth glyph is `radio.fill`), `tv.and.hifispeaker` (currently `.fill`), `laptopcomputer`. The rows keep their own glyphs.

### The counting rule

For each record in `library.records`:

| Record | Goes to |
|---|---|
| `isLocalDevice` (`SpeakerLibraryController.swift:101`) | This Mac ("the Mac would always be connected") |
| otherwise `isAvailable` (`:105`) and kind `homePod`, `appleTV`, `airportExpress`, `sonos`, `generic` | AirPlay |
| otherwise `isAvailable` and kind `bluetooth` | Bluetooth (available = connected to this Mac) |
| otherwise `isAvailable` and kind `cast` | Cast |
| everything else, including kind `nil` | Unavailable |

- **Header total** = `records.count`, every row the sidebar lists. The sum holds by construction.
- **Can't-be-found set** = Unavailable records with `liveDevice == nil` (`deviceRemoved` keeps a speaker that was seen and then dropped, `OutputBackend.swift:28-30`), counted only once the search is done. Bluetooth records are left out while Bluetooth access is off (open question 7), and network records while Local Network access is known to be off (open question 10). Speakers left out stay in Unavailable, and the sidebar says ", unavailable" for them.

### When each number is known

No "finished" signal comes from the network, so "known" comes from timing. Events arrive one device at a time (`BackendEvent`, `OutputBackend.swift:24`).

| Category | Known when | Source in code |
|---|---|---|
| This Mac | the local output is in the device list; the backend adds it before any search starts, so in practice at once | `NativeBackend.swift:2066` |
| Bluetooth | its live ids have not changed for 0.5 s, timed from launch (the tracker starts at once, so an empty list is also known after 0.5 s). macOS gives the whole list in one pass: Core Audio plus the paired list, sent once after start | `BTDeviceEnumerator.swift:124-125, 196-200`; `DiscoverySettleTracker.start()` `:47` |
| AirPlay | its live ids have not changed for 0.5 s after the first AirPlay speaker answers, or the whole search is done, whichever comes first. The tracker is not started early, because Bonjour answers arrive over time | `NativeDiscovery.swift:813-814` |
| Cast | same as AirPlay, for kind `cast` | `CastBrowser.swift:93` |
| Unavailable, the header total, the can't-be-found row | the whole search is done (`SpeakerSearch.isDone`, rule unchanged: no change in live ids for 0.5 s, or the 10 s ceiling). Until then a remembered speaker may still answer, and a new one may still raise the total | `SpeakersPageViewController.swift:48-51, 75-91` |

After the search every number stays live for the rest of the launch: a speaker switching on or off changes the numbers in place with the 180 ms fade, and no placeholder comes back. A page first opened after the search never shows a placeholder. Every placeholder lasts at least 0.5 s by construction, except This Mac's, which normally never draws, so no flicker rule is needed.

### States

| State | Header | AirPlay · Bluetooth · Cast · This Mac · Unavailable | Rows |
|---|---|---|---|
| First launch, still looking | placeholder + "speakers" | placeholder · placeholder → 0 at 0.5 s · placeholder · 1 · placeholder | Pair |
| First launch, nothing on the network (done) | 1 speaker | 0 · 0 · 0 · 1 · 0 | Pair |
| Mid-search, owner's fleet, 1.5 s (mockup panel 1) | placeholder + "speakers" | 4 · 0 · placeholder · 1 · placeholder | Pair |
| Done, owner's fleet (mockup window) | 20 speakers | 4 · 0 · 3 · 1 · 12 | 6 speakers can't be found [Forget 6 speakers…], Pair |
| Done, one can't be found (mockup panel 2) | 9 speakers | 3 · 1 · 0 · 1 · 4 | 1 speaker can't be found [Forget 1 speaker…], Pair |
| Done, every speaker reachable (panel 3) | 12 speakers | 7 · 2 · 2 · 1 · 0 | Pair |
| Bluetooth access off (panel 4) | 14 speakers | 6 · 1 · 2 · 1 · 4 | 2 speakers can't be found [Forget 2 speakers…], Bluetooth access is off [Open Privacy Settings… / Allow Bluetooth…], Pair |
| After Forget | the total and Unavailable drop by the number forgotten; the row goes when the set is empty | | |

The owner's fleet: six paired Bluetooth speakers are switched off but listed by macOS, so they are unavailable and not in the can't-be-found set. Five AirPlay speakers and one with no saved kind have not appeared, so Forget offers those six.

### Tokens and geometry

Unchanged from L unless named. Pane width 443 (`SurfaceLayout.swift:13` 653 − `:17` 210). Column top `GroupsPaneLayout.columnTopInset` 28 (`GroupsPaneLayout.swift:42`), header `headerPadding` 16 (`:86`), icon to title 12 (`:88`), card gap `sectionGap` 20 (`:103`), column cap `contentMaxWidth` 415 (`:61`). Icon well 48 (`DeviceIconWellView.swift:66`).

- Card: `GroupedSectionView` `.card` (`GroupedSectionView.swift:73`), fill `raised` (`Tokens.swift:218`), edge and in-card dividers `containerEdge` (`Tokens.swift:295`, `GroupedSectionView.swift:170`), radius `Radius.panel` 26 (`Tokens.swift:1445`).
- Strip: inset 18 from the card's leading edge (`ListRowView.leadingInset`, `ListRowView.swift:14`) and 10 from its trailing edge, 12 pt top, 11 pt bottom. Row 1: the "Available" caption, 14 pt line, then 4 pt. Row 2: five equal tiles of 77.4 pt. The Unavailable tile carries the 1 pt `containerEdge` leading rule and **12 pt** before its glyph. `hairline` is not allowed on `raised`.
- Tile: 16 pt glyph in `label2` (`ListRowView.glyph`, `ListRowView.swift:45`), 6 pt gap, count in `Tokens.Font.heading` (`Tokens.swift:1269`) with tabular digits, ink `label` (`Tokens.swift:94`), or `label3` (`:129`) for 0. Label 1 pt below in `Tokens.Font.caption` (`:1286`) and `label2` (`:113`). "Unavailable" is 60.3 pt in a 64.4 pt slot.
- Unavailable glyph: `SidebarPresenceDotView` `.away`, 9 pt (`SidebarViewController.swift:952-955`), centred in the 16 pt glyph box. It draws whatever the sidebar sets: the 2 pt `rim` ring (`Tokens.swift:311`, 4.78:1 light, 3.39:1 dark on `raised`).
- Rows: `ListRowView`, 44 pt minimum (`ListRowView.swift:17`). The can't-be-found row's glyph is the same 9 pt ring.
- Header caption: `caption` / `label2`, "N speakers" ("1 speaker").
- Placeholder: fill `Tokens.Color.meter` (`Tokens.swift:327`; light `#C6C9CE` 1.59:1, dark `#464C55` about 1.75:1 on `raised`, with Increase Contrast values of its own). A second use of the meter's empty-track grey, and the meaning carries over: a reading not taken yet. No new token.

### Motion

- **Placeholder.** For a count: 20 × 12 pt, corner radius 3, starting where the first digit will start (6 pt after the glyph) and centred on the count's 20 pt line. For the header: 16 × 8 pt, radius 2.5, 4 pt before "speakers".
- **Moving highlight.** One per page. A horizontal gradient 44 pt wide: clear, highlight colour, clear. Highlight colour = `meter.blended(withFraction: 0.70, of: .white)` in light and `0.30` in dark. It travels in pane coordinates from 44 pt before the leading edge to the trailing edge (443 pt) in **1.1 s**, timing `cubic-bezier(0.45, 0, 0.55, 1)`, then rests **0.5 s**: a **1.6 s** period, repeating. Each placeholder shows only the part of that one gradient crossing it, so the light runs left to right through the header and then the strip, AirPlay to Unavailable. To build it: clip each placeholder to its bounds and give it a gradient sublayer animating `position.x` from `-44 - x` to `443 - x` (x = the placeholder's offset in the pane), key times [0, 0.6875, 1]. All placeholders share one `beginTime`, taken when the first placeholder appears.
- **Arrival.** Placeholder and number crossfade in **180 ms**, `cubic-bezier(0.16, 1, 0.3, 1)`. Nothing moves and the number does not count up. That placeholder's animation is removed.
- **Stops.** Paused while the page is off screen; stopped for good when the last placeholder fills.
- **Reduce Motion.** The highlight is never added: placeholders are plain `meter` and hold still. The 180 ms fade stays (opacity only). Read `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` when placeholders appear, and follow live changes through `redrawOnAccessibilityDisplayChange()` (`AccessibilityDisplayRedraw.swift:33`).

### Overview accessibility

- **Strip.** One group labelled "Speaker counts". Each tile is one static-text element whose value is the copy's sentence (the caption, placeholder, glyph and label are not elements):
  - arrived: "4 AirPlay speakers available", "1 Cast speaker available", "No Cast speakers available"; "This Mac, available"; "12 speakers unavailable", "1 speaker unavailable", and for 0 "No speakers unavailable" (not in COPY.md; follows its zero pattern)
  - still looking: "AirPlay, still looking"; same pattern for Bluetooth, Cast and Unavailable
- **Header caption** value: "20 speakers", or "still looking".
- **When a number arrives**, post `.valueChanged` on that tile. VoiceOver speaks it only if focus is on it; nobody else is interrupted.
- **When the search finishes**, if the window is key and the page is on screen, post one low-priority `.announcementRequested`: "Finished looking for speakers." Nothing else is announced.
- **Help text** (tooltip and VoiceOver hint, like the rows): AirPlay "AirPlay speakers on your network right now." Bluetooth "Bluetooth speakers connected to this Mac right now." Cast "Cast speakers on your network right now." This Mac "This Mac's own output." Unavailable "Speakers your Mac can't reach right now." Can't-be-found row: see decision 6.
- **Increase Contrast.** `meter` has its own Increase Contrast values; the highlight fractions stay. Placeholders carry nothing VoiceOver doesn't also say.
- **Keyboard.** No new focusable controls.

## Words

`copy/COPY.md` is the string table, used unchanged except where "Resolved conflicts" says. Its "Strings elsewhere that change" table (file:line, including `DeviceDetailViewController.swift:698-700`, `window-harness/main.swift:98-99` and the DESIGN.md ranges) and its list of tests asserting old strings are part of this change. Strings this brief adds that COPY.md does not have: the tile help texts above (from the overview brief), the can't-be-found row's tooltip, the header "N speakers", "Speaker counts", and the header's "still looking".

## Builder notes

- **Analytics.** `speaker:library_counted` stays exactly as it is: same name, same nine properties from `SpeakerLibraryCounts.analyticsProperties` (`SpeakersPageViewController.swift:31-35`), still fired once from `SpeakerSearch.finish()` (`:86-91`). The page's five numbers and the can't-be-found set are worked out beside those fields, never added to them. No other event changes.
- **`SpeakerSearch`** reports which categories are known and calls the page back when that changes: one `DiscoverySettleTracker` each for Bluetooth (started at once), AirPlay and Cast (armed on first arrival); the overall rule is unchanged. The page's `isSearchDone` becomes that richer state, and the sidebar reads the same "search done" to stop holding "can't be found".
  - Cheaper fallback if per-kind tracking is not worth it: AirPlay and Cast fill with Unavailable at search done. This Mac and Bluetooth still come first.
- **Removed:** the spinner, the green check, the caption dots, the Unknown tile, the red Forget glyph, the sidebar's `.playing` and `.lost` dot states, and `IconLabelCellView.activeMarkerView` (`SidebarViewController.swift:815-828`, a gold speaker glyph no row shows; open question 6).
- **Tests to rewrite:** `test_subtitleText`, `test_kinds`, `test_discoveryShowsSpinner`, `SidebarActionsTests.swift:123-124`, plus the suites COPY.md lists for old strings.
- **Docs that change with the code:** `AudioutWindowUI/AGENTS.md` map line ("search result, kinds, Bluetooth, lost, Pair"); DESIGN.md "Layout" → "Speakers page" paragraph; DESIGN.md "Speakers Sidebar and Pages" (the ember, gold and triangle dots, "In the Mixer", and the second-to-last paragraph's even older subtitle, already stale at `DESIGN.md:699-705`).

## Resolved conflicts

1. **Second section's name.** The sidebar brief kept the plate "Speakers" with no title above it (its question 1). COPY.md names the section "Speakers" and the plate "Overview". COPY.md wins, and the sidebar brief's own fallback applies: a title in the section-title style above the plate, with the 16 pt gap kept between the sections.
2. **Subsection header.** Sidebar placeholder "Shown in the Mixer" becomes "Shown in Mixer" (COPY.md: the setting is Show in Mixer). The overview mockup's context sidebar still drew the shipped "In the Mixer"; superseded.
3. **Hidden-and-in-use caption.** "In the Mixer while it plays" becomes "Shown while playing", measured to fit (106.1 pt in about 128 pt). Closes the sidebar brief's question 7.
4. **Menu checkmark item.** The sidebar mockup drew the shipped "Keep in Mixer when unavailable"; it becomes "Show even when unavailable".
5. **"Away" becomes "Unavailable"** on the overview: tile label, VoiceOver and help text. Closes the overview brief's question 6. The longer word is 60.3 pt, so the padding before the tile's glyph drops from 14 to 12 pt, leaving 4.1 pt spare instead of 2.1.
6. **Can't-be-found row title.** The overview brief's "Not seen since Audiout opened" loses to COPY.md's shipped "N speakers can't be found". COPY.md defines "can't be found" as exactly the speakers not seen this launch, and the sidebar's spoken label (`SidebarViewController.swift:1314`), its tooltip and the speaker page (`DeviceDetailViewController.swift:20, 641`) already use it for them, so one phrase names one set everywhere. It also differs from "Unavailable", so the row reads as part of that number rather than a second count. "Since Audiout opened" moves into the row's tooltip. Closes the overview brief's question 4: the device page and the sidebar keep "Can't be found". The red triangle still goes; the glyph is the ring.
7. **The "Available" label.** COPY.md labels the kind counts "Available" and describes Unavailable as a row below them. The overview brief puts all five in one strip with no group label. Structure comes from the overview brief and the word from COPY.md: an "Available" caption over the four kind tiles, with the rule before Unavailable running the full height. Open question 1 offers the two-row version.
8. **Header caption.** The overview brief shows the total "20 speakers" with its own placeholder. COPY.md drops every search caption and, if the slot stays, would show "Looking for speakers…" then nothing. The total stays and "Looking for speakers…" does not appear: the owner dropped the search status and asked for shimmer on the numbers, the total is a number rather than a status, it is the check his "doesn't add up" complaint needs, and COPY.md's list of dropped strings does not include it. Open question 2.
9. **VoiceOver per tile.** The overview brief's "4 available" / "still counting" / "12 not available right now" become COPY.md's sentences, carried as each tile's value and still posted with `.valueChanged`.
10. **End-of-search announcement.** The overview brief's "Counted 20 speakers: 8 available, 12 not available right now." becomes COPY.md's "Finished looking for speakers."
11. **Unavailable help text.** The overview brief's "Speakers you've used that aren't available right now: …" becomes COPY.md's "Speakers your Mac can't reach right now."
12. **Ring stroke.** The overview mockup drew its Away glyph at 1.5 pt. It is the same view as the sidebar's ring (`SidebarPresenceDotView` `.away`), so it takes the sidebar's 2 pt everywhere.
13. **Main Audio row and unreachable-row ink.** The overview mockup's context sidebar drew Main Audio flat with an empty dot slot and unreachable names in `labelCool`. The sidebar brief owns the sidebar: Main Audio is a plate, and unreachable names stay `label3`, as the code dims them today (`SidebarViewController.swift:1300`).
14. **Can't-be-found, sidebar against page.** Today the sidebar marks any record with no live device (`:457-459`, `:468`) while the page leaves out This Mac and waits for the search (`SpeakersPageViewController.swift:247-248`). Both now read one set, defined under "The counting rule".
15. **The page caption's 7 pt dots** (the sidebar brief's question 6): the overview removes that caption, so there is nothing to follow.

## Open questions for the owner

Each was built with the default named; the mockup shows the default.

1. **Unavailable beside the kind counts, or on its own row below them?** You said "another row" for away speakers, and COPY.md wrote it as a second row. Default: one strip, Unavailable as the fifth tile after a rule, "Available" over the other four. It keeps every number on one line and the card short; the second row would give Unavailable room to carry the can't-be-found count inline.
2. **The total under "Speakers".** Default: "20 speakers", with its own placeholder while looking. Alternative: no caption at all.
3. **Hold "can't be found" until the first search settles.** On a cold launch every remembered speaker has no live device for a few seconds. Default: yes; until then the sidebar says ", unavailable" and shows no "Can't be found" tooltip. The dot is a ring either way.
4. **A filled grey dot can read as "offline"** to anyone used to chat apps; inside Audiout grey `rim` is the connected ring's colour. Default: ship `rim` as ruled and look at it in the live build.
5. **The real dark sidebar ground is unmeasured.** At `#2C2C2E` the dot is 2.99:1. Default: keep `rim` and the 2 pt ring; the builder measures the ground once on a real window and pins the figure in a contrast test; under 3:1 it comes back to you.
6. **Remove the unused gold active marker** (`IconLabelCellView.activeMarkerView`, `SidebarViewController.swift:815-828`) with the playing state. Default: yes, same change.
7. **Bluetooth speakers while Bluetooth access is off.** Without access macOS does not list paired speakers (`BTDeviceEnumerator.swift:113-118`), so a remembered one looks never seen. Default: count it in Unavailable, leave it out of Forget, and have the sidebar say ", unavailable" for it.
8. **The search can end before Bonjour answers.** This Mac and Bluetooth arrive at once and feed the overall tracker, so a slow network can hit the 0.5 s quiet window first; AirPlay and Cast then show 0 and update live. Default: leave the rule alone, because changing it moves when `speaker:library_counted` fires. Alternative: feed only network speakers (`Device.Kind.isDiscoveredOverLocalNetwork`) to the overall tracker and arm the 10 s ceiling at the first update.
9. **Kinds this Mac has never had.** Default: always show all five tiles, zeros in the quieter ink. Alternative: hide a kind the library has never held; quieter for someone with no Cast speakers, but tiles can then appear mid-search.
10. **Local Network access off.** Every network speaker then looks never seen, and Forget would offer them all. Default: while Local Network access is known to be off, hide the can't-be-found row and say ", unavailable" in the sidebar. The page has no Local Network row today; that would be its own decision.
11. **"Hide when not in use" could become "Only while playing"** (`AudioutCore/SpeakerLibraryStore.swift:14`, shared with the popover's speaker menu, `AudioutPopoverUI/PopoverController.swift:3327`), so every value finishes "Show in Mixer: …". Default: leave it; nothing breaks.
