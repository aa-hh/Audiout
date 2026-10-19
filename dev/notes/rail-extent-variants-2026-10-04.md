# Membership rail: where it starts and stops (2026-10-04)

Read from `claude/ring-glyph-fixes` at c3c8ecb6. Mocks: `rail-extent-variants-2026-10-04.png` (today on the left, proposed on the right).
Paths are short: `Overlay` = `AudioutCore/Sources/AudioutSharedUI/BusRailOverlayView.swift`, `Host` = `AudioutPopoverUI/PopoverController+SyncDrawer.swift`, `Panel` = `AudioutPopoverUI/PopoverPanelViewController.swift`, `PC` = `AudioutPopoverUI/PopoverController.swift`.

## How it works today, in four lines

- The host finds the lowest speaker the rail reaches, a member that is connected or connecting, in the full list. Hidden rows count, rows the user hid from the list do not (Host:228-242, `railReaches` Overlay:476-481).
- If that speaker sits in a collapsed section, the host tells the overlay to cut the rail at that section (Host:237-241, Panel:437-449).
- The overlay draws the end dot at the collapsed body's **floor**: a zero-height strip directly under the header, so the dot sits on the header's bottom edge, not beside it (Overlay:1020-1042, dot at :328-331, line at :426-429; `clipBand` :285-290).
- Only ONE cut exists. Collapsed sections above it get no mark, whether or not they hide a member.

The screenshot is the last two lines together. A member is folded into Bluetooth, so the dot lands on the Bluetooth header's bottom edge, which is the footer's top edge. The line passes AirPlay and Cast with nothing to say whether they hide anything.

## Situations

Tone (gold armed / ember idle / `railDormant`) never changes the extent: one colour for hook, line and dot (Overlay:341-343, :396). Dormant means the Output popup holds a group the checked set differs from (PC:2886-2895). A non-diverging group and "Selected Speakers" draw the same rail. So the table has one row per structure, and tone is S15.

| id | structure | state | today (file:line) | proposed |
|---|---|---|---|---|
| S1 | all expanded | lowest reached speaker visible, connected | line ends a 3 pt gap above its node (Overlay:406) | same |
| S2 | any | nothing reached (no member, or only failed ones) | no line, no hook, no Main Audio ring (Overlay:354-357, `isLive` :920, Host:250 `setRailLive`) | same |
| S3 | a collapsed section hides only non-members, below the lowest reached speaker | — | no cut, header gets nothing (Host:237-241 finds no collapsed section holding the lowest reached) | same |
| S4 | one collapsed section hides the lowest reached speaker | — | line runs to the header's bottom edge, 5 pt dot there; reads as belonging to the next header or the footer (Overlay:1041, :328) | dot centred on the header's own line, beside the chevron |
| S5 | two or more collapsed sections hide reached speakers (owner's screenshot) | — | dot only at the lowest one's bottom edge; upper ones unmarked (single `deviceSection`, Panel:437) | a dot on every header that hides a reached speaker; line passes through upper dots, ends on the lowest |
| S6 | a collapsed section hides a reached speaker, a visible reached speaker sits lower | — | no cut; line passes the collapsed header unmarked (Host:233-236 only looks at the lowest) | dot on that header, line passes through it |
| S7 | visible rows below the end (in open sections under a cut, or under the lowest member) | non-member or failed | node only, no line, no detour (Overlay:1022, :383) | same |
| S8 | Output Speakers card collapsed over a reached speaker | — | dot at the card body's floor: the card header's bottom edge, or below the "Inactive" note when dormant (the note is a header-region row, PC:1779-1782) | dot centred on the card header's line |
| S9 | Output Speakers card collapsed, nothing reached inside | — | no rail (S2) | same |
| S10 | System Audio card collapsed | — | rail starts at a dot centred on that header (Overlay:315-321, :1001-1015) | same; S4/S8 now use this same centring |
| S11 | only the Mac's outputs listed (Bluetooth header still renders for its Connect row, PC:1946-1951) | Mac selected / Mac playing alone (`localFallbackOutput`) | ends at the Mac node | same |
| S11b | same | Mac not selected | S2: no rail | same |
| S12 | speakers hidden with the hide feature | — | not in the list, never decide anything; a selected hidden speaker still lists (PC:2127-2131) | same |
| S13 | lowest reached speaker is connecting | — | ends above its dashed node (connecting counts as reached, Overlay:478) | same |
| S14 | lowest member failed | — | never reached: line ends at the reached speaker above; red node alone (Overlay:476-481). A failed speaker folded into a collapsed section gets no dot | same |
| S15 | any | armed / idle / dormant | tone only, same extent | same |
| S16 | reached speaker scrolled below the bottom of the list (no collapsed section involved) | — | line runs to the list's bottom edge, dot there (card body is the scroll viewport, Overlay:1020-1042) | line runs to the edge, no dot (open question 2) |
| S17 | rows scrolled off the top of the list | — | their stops are dropped; line runs straight down from the hook (Overlay:261-263) | same |
| S18 | the collapsed section that ends the rail is itself scrolled out of view | — | cut is read from that section's own position, outside the viewport, so line and detours can draw over the Applications card, or over the fixed card header above the list. **From code reading, not seen live**: only the top edge is ever clamped (Overlay:261) | clamp to the visible list: line runs to the list's edge, no dot |
| S19 | Groups window editor | — | shares `BusRailOverlayView`/`RailPlan` but passes no sections (`GroupEditorViewController.swift:963-969`), so nothing collapses; ends at the lowest checked row | not affected |
| S20 | mid-collapse animation | — | end follows the shrinking floor every frame (Overlay:214-229) | dot travels from the floor to the header's centre as the body closes |

## Contradictions in today's code

1. `RailPlan.resolve`'s doc says the cut "lands at the section header once fully collapsed" (Overlay:991-992), and `AudioutPopoverUI/AGENTS-HISTORY.md:21` says "CUT at THAT subsection's header". The code lands it on the header's **bottom edge** (`floorY`, Overlay:1041). `headerTerminusY` (Overlay:295-298) exists but only the origin side uses it.
2. The origin side centres its dot on the header (S10). The far end does not, so the two ends of one rail follow different rules.
3. The host names one cut section (Panel:437). Any other collapsed section that hides a member cannot be shown, which is S5 and S6.
4. A scrolled list clamps the top (Overlay:256-263) but not the bottom when a subsection is the cut (S18).

Nothing in `DESIGN.md` or `docs/SPEC.md` decides the extent rules. `docs/SPEC.md` has no §4.7 rail text; "§4.7" in code comments refers to the dormant tone, now in `DESIGN.md` around line 771. The extent rules live only in the AGENTS files (`AudioutPopoverUI/AGENTS.md:20-21`, `AudioutSharedUI/AGENTS.md:24`) and in code comments.

## Proposed rule set

1. The rail starts at the Main Audio ring's hook; when System Audio is collapsed it starts at a dot centred on that header.
2. The rail exists only while some listed speaker is reached: a member that is connected or connecting, visible or folded away. A failed member and a non-member never count.
3. A collapsed header (subsection or the Output Speakers card) that hides a reached speaker carries the end dot, centred on the header's own line in the rail column.
4. The rail ends at the lowest of: a visible reached speaker's node, or a dotted header. It passes straight through any dot above that.
5. A collapsed header that hides no reached speaker gets no dot. The line passes it if a later end lies below; otherwise nothing is drawn beside it.
6. Above the end, non-members are detoured. Below the end, rows show their node and no line.
7. The rail never draws outside the visible list. A reached speaker scrolled past an edge ends the line at that edge, with no dot.
8. Armed, idle and dormant change the colour only, never where the rail starts or stops.

Changes from today: the dot moves to the header's centre line (S4, S8); every header hiding a reached speaker gets a dot (S5, S6); the scroll edge clamps at the bottom too and drops the dot there (S16, S18). In code that means: `RailPlan.Input` takes a list of collapsed headers, each with its centre y and whether it hides a reached speaker, in place of the single `deviceSection` + `dropsHiddenRows`. The host computes the list in `updateRailRows` from the full order it already walks.

## Open questions for the owner

1. **Dot on every header that hides a member, or only the lowest?** Recommend every one: otherwise AirPlay-hiding-a-member and Cast-hiding-nothing look identical, which is what the screenshot shows. Alternative: only the lowest, as today but centred. Fewer dots, but S6 stays unmarked.
2. **Speaker scrolled past the list's edge: dot at the edge, or no dot?** Recommend no dot: the row is scrolled, not folded, and a line running into the edge already says "continues below". Alternative: keep today's dot so every cut reads the same.
3. **Should a collapsed section that hides a failed speaker show anything?** Recommend nothing on the rail (failed is never reached, rule 2); the failure belongs on the header itself if anywhere, which is outside the rail.
