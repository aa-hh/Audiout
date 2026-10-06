# M, sidebar: two sections and a two-state dot

Design only. Names are placeholders ("System Audio", "Speakers", "Shown in the Mixer", "Hidden unless playing"); the copy pass replaces them. The owner brief (`../OWNER-BRIEF.md`) stood in for the shape interview. The owner's later ruling (2026-10-04) is applied: filled dot = reachable on the network, everything else rim only, no warning glyph. Mockup: `mockup.html` / `mockup.png` / `mockup-dark.png`, the owner's 20 speakers from `../L`.

Line numbers are on `claude/speakers-nav` at 95f5fa60.

## Job

The Speakers tab sidebar is the only speaker list. It has two jobs: make Main Audio (the main output) the obvious place to control what the Mac plays, and list every speaker with whether the Mac can reach it, sorted by Mixer visibility. App UI: scanning and native expectations come before expression.

## Structure, top to bottom

| # | Row | Treatment |
|---|---|---|
| 1 | Section title "System Audio" | The existing header cell (`SidebarViewController.swift:1242-1265`): `Tokens.Font.captionEmphasized` (11 pt semibold), `Tokens.Color.label2`, flush with the cell's leading edge. |
| 2 | Main Audio plate | The Speakers plate's treatment, unchanged: `PlateRowView` (`:906-946`), 36 pt, `Tokens.Color.raised` fill, 1 pt `Tokens.Color.containerEdge`, `Tokens.Layout.Radius.control`, 10 pt side inset; `DeviceIcon.mainAudioSymbolName` at the cell's leading edge (no dot slot); `Tokens.Font.bodyEmphasized`; `chevron.right` 10 pt semibold in `label3`. Selected, the source list's own pill stands alone (existing rule, `:895-905`). Today `.mainOut` is a flat row with an empty dot slot (`:1180-1182`); it moves onto the plate path that `rowViewForItem` and `heightOfRowByItem` give `.speakersOverview` (`:1139-1166`). |
| 3 | 16 pt gap | A non-selectable spacer row: no text, no menu, no drop, nothing spoken. It is what tells the two sections apart. |
| 4 | Speakers plate | Unchanged. It now heads the second section. |
| 5 | Subsection "Shown in the Mixer" | A group row as today (drop target, never folds). New style: `Tokens.Font.caption` (11 pt regular), `Tokens.Color.label3` (its own doc names "subsection headers" as a `label3` job, `Tokens.swift:117`). Text starts 16 pt in from the cell's leading edge: `SidebarPresenceDotView.side` 9 (`:955`) + `dotToIconGap` 7 (`:1330`), so it lines up with the speaker icons. No gap between the Speakers plate and this row. |
| 6 | Speaker rows | Geometry unchanged. New dot (below). |
| 7 | Subsection "Hidden unless playing" | Same style as row 5. Still only when it has rows, still folds through the stock Show/Hide. |
| 8 | Add scene bar | Unchanged. |

**Why the rows are not indented.** Indenting is how Finder and Mail show nesting, but the name column cannot spare the width. The code's own note says 210 pt fits "MacBook Pro Speakers" (139.9 pt in the system font) and 200 pt did not; that was before the dot. With the dot slot, the name column works out to about 128 pt (210 − 28 cell insets − 46 for dot, gap, icon, gap − 8 trailing), so that name already truncates, as L's mockup shows. One indent level (about 16 pt) would cut every name to about 112 pt. The nesting comes from three things instead: the section title keeps the outer column, the subsection headers step in 16 pt and drop to regular weight and `label3`, and the Speakers plate sits flush on its first header while 16 pt separates the two sections. Source lists have one stock header level; the header cell is already custom (`makeHeaderLabel`), so the second style is a font, colour and constraint constant, not new drawing.

## The dot

**Two states.** Filled: the speaker is reachable on the network (connected ones included). Rim only: anything else, meaning away, can't be found, or not seen yet this launch.

**Colour: `Tokens.Color.rim`** (`Tokens.swift:311-314`: dark `#6B767D`, dark Increase Contrast `#818B90`, light `#66717A`, light Increase Contrast `#586269`). This is the Mixer's connected colour:
- The glyph ring's connected form strokes `rim` (`HaloRingView.swift:243-249`). That view carries connection state alone; `joinsSpine` swaps in gold only on Main Audio's ring.
- The Mixer's status dot, connected and silent, is a hollow ring in the ring's colour, which is `rim` (`HaloRingView.swift:262` hands it over, `RouteArmedDotView.swift:183-186` strokes it), 1.5 pt (`PopoverColumnGrid.swift:397`). Ring strokes elsewhere on the row are 1.6 pt (`PopoverColumnGrid.swift:325`).
- Gold appears only while playing: the dot becomes a gold disc with a 1 pt `ember` edge (`RouteArmedDotView.swift:181-182`, `PopoverColumnGrid.swift:393`) and the rail's member node is gold (`MembershipBusView.swift:268-272`). Gold means live audio (`AudioutWindowUI/AGENTS.md`), so it cannot mark "reachable".

**Geometry.** 9 pt, unchanged. Filled: a `rim` disc. Rim only: a 2 pt `rim` stroke inside the 9 pt edge (path inset 1 pt), leaving a 5 pt hole. 2 pt instead of the Mixer's 1.5 pt because the ring now also stands for "can't be found", and on the darker end of the estimated dark ground it measures 2.99:1, where a thinner anti-aliased line renders below its colour's ratio. Same width in every mode; Increase Contrast changes only the colour.

**Selected rows.** `rim` fails on both selection pills (2.03:1 on the dark grey pill, about 1.2:1 on the accent pill), so a selected row draws the same shape in the row's text colour: `Tokens.Color.label` on the grey pill (8.44 dark, 11.58 light), white (`NSColor.alternateSelectedControlTextColor`) on the accent pill when the list has focus (4.8 to 6.4). The cell reads its `backgroundStyle` (`.emphasized` means the accent pill) and its row's `isSelected`. Today's ember dot has the same problem; this fixes it.

**Contrast of `rim`** (WCAG ratios; the sidebar ground is the system source-list colour, not `panel`, per `MixerWindowController.swift:169-173`, and nobody has measured it since the 2026-09-03 migration, so it is bracketed at `#E8E8EA`–`#F5F5F6` light and `#1E1E20`–`#2C2C2E` dark):

| `rim` against | Light | Light, IC | Dark | Dark, IC |
|---|---|---|---|---|
| Sidebar ground | 4.08–4.58 | 5.10–5.73 | 2.99–3.58 | 4.00–4.78 |
| Grey selection pill | 3.43 | 4.29 | 2.03 | 2.71 |
| Accent selection pill | ≈1.2 | ≈1.2 | ≈1.2 | ≈1.2 |

Today's `ember` measures 2.78–3.32 on the same dark band, so `rim` is no step down. `rim` is not remapped by the accent dial (`ember` was), so the dots look the same in Full and Subtle. Header inks on the ground band: `label2` 5.09–7.41, `label3` 4.64–5.54.

## States

| Speaker | Dot | Row ink | Spoken suffix |
|---|---|---|---|
| Reachable, including connected or playing | filled | `label` | none |
| This Mac | filled | `label` | none |
| Away | rim only | `label3`, as today | ", unavailable" (copy pass may change) |
| Can't be found | rim only | `label3`, as today | ", can't be found", plus tooltip "Can't be found" |
| Not seen yet this launch | rim only | `label3` | see open question 2 |
| Hidden and in use | filled | `label`, 40 pt row with caption "In the Mixer while it plays" | caption suffix, as today |
| Selected | same shape, row's text colour | pill ink | unchanged |

Also drawn in the mockup: the second group folded (stock Show on hover), a drag onto the other group's header (stock drop outline), and the right-click menu on a speaker the Mac can't find.

## Today's "playing" state: removed

1. The owner's rule allows two states.
2. It never meant playing. It fires on `connectionState == .connected` (`SidebarViewController.swift:469`), so a muted or silent connected speaker went gold. The Mixer turns its dot gold only when the row is route-armed and connected (`DeviceRowView.swift:683`), so the sidebar already disagreed with the Mixer.
3. The folder rule says the sidebar dot shows presence, never routing; gold is reserved for live audio.
4. Nothing is lost. A connected speaker is reachable, so it draws filled. The Mixer shows what plays, and the hidden-and-in-use caption stays.

For the builder: `SidebarPresenceDotView.State` drops `.playing` and `.lost`; the ", playing" suffix goes (`:1316`); `SidebarActionsTests.swift:123-124` pins `.playing` and `.lost` and changes with it. `DESIGN.md` "Speakers Sidebar and Pages" describes the ember, gold and triangle dots and the "In the Mixer" header, and updates in the same change. No analytics event changes.

## A speaker the Mac can't find: what still marks it

The warning glyph leaves the sidebar only. Still there:
- Right-click: **Forget "Name"…** appears only for these speakers (`SidebarViewController.swift:388-391`, several selected `:412-417`). It is the sidebar's one item that exists only for them.
- Tooltip "Can't be found" on the row (new; today the tooltip is only the id of a speaker whose details are unknown, `:1191`, and the two combine). This gives a pointer user what VoiceOver already says.
- VoiceOver keeps ", can't be found" (`:1314`).
- Selecting the row opens its page: failure glyph, "Can't be found", and Forget (`DeviceDetailViewController.swift:641`).
- The Speakers page carries the count and "Forget N speakers…".
- A speaker with unknown details still reads "Missing speaker".

## Accessibility

- The dot stays drawing only; the row's label carries the state (`:1308-1321`).
- Shape carries the state, so one hue suffices and colour blindness changes nothing.
- Increase Contrast resolves `rim`'s own hexes live; the view already repaints on the display-options change (`:965`).
- Nothing animates, so Reduce Motion has nothing to stop.
- Plates are ordinary selectable rows; section title, subsection headers and the gap row are not selectable, so arrow keys skip them.
- Main Audio plate speaks "Main Audio"; the copy pass may add a second phrase the way the Speakers plate says "Speakers, manage speakers" (`:1178`).

## Open questions, each with my default

1. **A title above the Speakers plate, matching "System Audio"?** Default: no. The plate names its own section; a "Speakers" header over a "Speakers" plate repeats a word. If the copy pass names the second section something else, add it in the section-title style above the plate and keep the 16 pt gap.
2. **Hold "can't be found" until the first search settles**, as the Speakers page does? On a cold launch every remembered speaker has no live device yet, so the tooltip and spoken suffix would say "can't be found" for all of them for a few seconds. Default: yes; until the search is done, say ", unavailable" instead. The dot is rim only either way.
3. **A filled grey dot can read as "offline"** to anyone used to chat apps. Inside Audiout, grey `rim` is the connected ring's colour. Default: ship `rim` as ruled; look at it in the live build.
4. **The real dark ground is unmeasured.** At `#2C2C2E` the dot is 2.99:1 at standard contrast. Default: keep `rim` and the 2 pt stroke; the builder measures the ground once on a real window and pins the figure in a contrast test; if it lands under 3:1 the owner decides.
5. **Remove `IconLabelCellView.activeMarkerView`** (`:815-828`, a gold speaker glyph that no row shows) with the playing state. Default: yes, same change.
6. **The Speakers page caption reuses this dot at 7 pt.** It follows automatically. Default: no separate work; the overview redesign may drop those dots anyway.
7. **Caption width for the copy pass.** "In the Mixer while it plays" is 132 pt at 11 pt in a column of about 128 pt, so it truncates today. Default: the copy pass keeps that caption under about 125 pt; names keep truncating at the tail.
