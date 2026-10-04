# Colorize: Speakers tab, direction M with sidebar direction C

Made with impeccable `colorize`, 2026-10-04, against `claude/speakers-nav` HEAD b9b70310 (none of the cited files has uncommitted edits). Rule applied: the Speakers tab never shows sound (`AudioutWindowUI/AGENTS.md`: configuration only; the sidebar shows presence, never routing), so under Warm Signal none of its ink is warm. Text that is not primary takes `labelCool`, glyphs take `labelCool2`, primary text stays `label`. No new token.

## Amendments

1. **Unreachable rows** (direction C "Rows"; `SidebarViewController.swift:1298` icon, `:1300` name). Name `label3` → `labelCool` (light `#4E5A63`, dark `#A9B3BB`, Increase Contrast `#414B53` / `#C0C8CD`). Icon `label3` → `labelCool2` (`#5F6A73`, `#818C94`, IC `#464E55` / `#A6AEB3`). `labelCool2` stays off text in the sidebar: 4.06:1 on the lightest dark ground. That puts the sidebar's unreachable name one rung brighter than the Mixer's (`labelCool2`, `DeviceRowView.swift:2445`), because the Mixer's ground is `panel`, where `labelCool2` passes (5.23:1). direction-c/mockup.html already draws this (`:95-96`); M/mockup.html `:94` still draws `label3`.

2. **Subsection headers** "Shown in Mixer" and "Hidden unless in use". M had `label3` (BRIEF.md row 6), C had `label2` (C brief, Geometry; mockup `:84`). Both become `labelCool`. Not `labelCool2`: these are text, and it fails 4.5:1 in dark.

3. **Section titles** "System Audio" and "Speakers": `label2` (`SidebarViewController.swift:1251`, the shared header cell) → `labelCool`, `captionEmphasized` unchanged. `label2` light `#6B5F4E` is the brown the owner rejected. `Tokens.swift:497-498` defines `labelCool` as "the same second-rung job as `label2` on a surface that carries no warmth of its own", which describes the system source list exactly. After items 2 and 3 every header in the sidebar uses one ink, and weight separates the two levels (see Touches other passes).

4. **Caption "Shown while in use"** (`statusLabel`, `SidebarViewController.swift:850`): `label3` → `labelCool`. It is not gold, because it follows `isInUse`, not sound (CLARIFY.md 3).

5. **Divider row** (C): the glyph `antenna.radiowaves.left.and.right.slash` and the label "N unavailable" both take `labelCool`, as C has it. The rule stays `Tokens.Color.separator`, the system separator colour (black or white at 9.8 %, measured): 1.24:1 light and 1.34:1 dark, with no floor because the label says the same thing. `hairline` would measure 1.02:1 on the dark source list and `containerEdge` 1.37:1, so neither does better.

6. **Plate chevrons** (Main Audio, Overview; `SidebarViewController.swift:838`): `label3` → `labelCool2`. Measured on the unselected plate's `raised`: 5.30 light, 4.59 dark. Plate titles and icons stay `label`.

7. **Selected rows, both selection pills.** Every ink in a selected cell (name, icon, caption, chevron, and the gold "Playing" fallback from item 10) draws `label`. This replaces M's "Selected rows" paragraph, which was about the dot that C removed.
   - Why: on the grey selection pill shown when the list is not focused (`unemphasizedSelectedContentBackgroundColor`, measured `#DCDCDC` light / `#464646` dark), `labelCool` text measures 4.43:1 in dark and `labelCool2` glyphs 2.75:1. Both fail. `label` measures 11.65 light and 7.33 dark.
   - On the accent selection pill shown when the list is focused, AppKit draws text and template icons white. Measured on this Mac (macOS 27) with a custom `textColor` and with a custom `contentTintColor`: both turn `#FFFFFF`. White measures 5.37:1 on `#0064E1` light and 6.27:1 on `#0059D1` dark (default blue accent). Setting `label` keeps the white on older macOS too, because AppKit has always whitened its own label colours.
   - Mechanism: nothing in `Sources/` reads `backgroundStyle` today, and a selection in an unfocused list leaves the cell's `backgroundStyle` at `.normal`, so the cell can't tell from it. The row view has to tell the cell. `rowViewForItem` returns a custom row view for the Overview plate only (`SidebarViewController.swift:1157-1166`). Give speaker rows and the Main Audio plate one too, and have each row view re-ink its cell when `isSelected` or `isEmphasized` changes. `PlateRowView` already watches `isSelected` (`:945`).
   - While a row is selected, its position under the divider and its spoken ", unavailable" still say it is unreachable.
   - Mockups: direction-c draws the accent state right (`.row.sel`, `:100-101`). The window's Overview plate is drawn on the grey pill (`.plate.sel`, `:79`), so its chevron becomes `label`. Add one unreachable row, selected on the grey pill, to the "Select, drag, keyboard, VoiceOver" panel.

8. **Overview page** (M BRIEF.md "Tokens and geometry" `:165-171`; direction-c/mockup.html `:123-142`). Change the inks at the call sites in `SpeakersPageViewController`, not in `ListRowView`'s defaults: the only other `ListRowView` consumer is the speaker page (`DeviceDetailViewController.swift:104-106`), which item 11 leaves to the owner.
   - Header caption "20 speakers", the "Available" caption, the kind labels and "Unavailable": `label2` (`captionField`, `SpeakersPageViewController.swift:314`) → `labelCool`. Changing `captionField` covers all of them.
   - Count glyphs, the Unavailable glyph included: `label2` (the default at `ListRowView.swift:45`) → `labelCool2`. The sidebar's divider glyph stays `labelCool` (item 5). The shape is what links the two, and an 11 pt glyph beside 11 pt text reads as one label in one ink.
   - Counts stay `label` (`:353`). A zero goes from M's `label3` to `labelCool2`: 4.59:1 on dark `raised`, the tightest pass in this note.
   - Row glyphs (Bluetooth access, Local Network from HARDEN.md 7, `questionmark.circle` for can't be found from C, `plus.circle` for Pair) → `labelCool2`. Pair's chevron `label2` (`:416`) → `labelCool2`. Row titles stay `label` and the buttons stay stock.
   - The header icon well is already cool: icon `labelCool` (`DeviceIconWellView.swift:154`), edge `containerEdge` (`:286`). Both mockups draw it in `label2` (`.idw`: M `:102`, C `:123`). That is a mockup error; fix it.
   - Placeholders: `meter` and its moving highlight (`meter` blended with white) are already cool grey, so nothing changes. If the audit pass replaces the still Reduce Motion placeholder with an en dash, the dash takes `labelCool2`, the zero ink.

9. **Kept on purpose.**
   - `label` is `NSColor.labelColor` (`Tokens.swift:94`), measured black or white at 84.7 %. It is neutral, not warm, and it is the source list's own ink. It stays on reachable names and icons, plate titles and icons, counts, and row titles.
   - The plate (`raised` fill, `containerEdge` edge, `SidebarViewController.swift:936-938`) and the card (`raised` fill, `containerEdge` edge and rule) are cool already.
   - The header strip's idle tabs stay `label2` (DESIGN.md Surface Header Strip). Every tab shares the strip, so it is outside this pass.
   - Stock and untouched: the Add scene bar, the fold's Show/Hide, buttons, menus, tooltips, the drop outline.

10. **Gold, red and green after M, C and this pass.**
    - Sidebar and overview: none. These leave with M and C:
      - the gold `activeMarkerView` (`SidebarViewController.swift:815-828`);
      - the dot's `ember` and `gold` states (`:978-992`; `ember` is gold's dim companion and was the brown dot);
      - the `failure` triangle (`:993-1000`);
      - the overview's red triangle (`SpeakersPageViewController.swift:260`);
      - the `.systemGreen` check (`:289`), a raw system hue that bypasses `Tokens`.
    - `DeviceIconWellView` draws gold only when `isActiveGroup` is set, and only `GroupEditorViewController.swift:789` sets it, so never in this tab.
    - The one gold this tab may show is CLARIFY.md 5's fallback, if the owner takes it: "Playing" on the Main Audio plate. It uses `goldText`, because `gold` may not set text (`Tokens.swift:578`). It shows only while a Main Audio speaker is route-armed and connected, the state that turns the Mixer's dot gold (`DeviceRowView.swift:683`). Unselected on `raised`: 5.66 light, 8.55 dark (Subtle 5.21 / 5.91). Selected, item 7 sets it to `label`, because `goldText` on the grey pill measures 4.31 light and fails.
    - Green: only the Equalizer mark on a speaker's page, a site the Equalizer-Hue Fence allows (DESIGN.md). Red: only the speaker page's "Can't be found" glyph (`DeviceDetailViewController.swift:216`); see owner call 2.

11. **Speaker pages and Main Audio page.** These are in the same tab but outside M's mockups, and they still set `label2`: `DeviceDetailViewController.swift:211, 258, 265, 268, 294, 912, 931` and `MainOutDetailViewController.swift:103, 128`. The `ListRowView` caption default (`ListRowView.swift:65`) also feeds the speaker page's Show in Mixer row. The same mapping applies: text `labelCool`, glyphs `labelCool2`. Owner call 1.

12. **Briefs, mockups, docs and tests to update.**
    - M/BRIEF.md: row 6 (subsection headers `label3`), the Row states table (`:62-63`, `label3`), "Selected rows" (`:44`), resolved conflict 13 (keeps `label3`), and `:167`, `:170` (tile glyph and header caption in `label2`, zero in `label3`).
    - direction-c/BRIEF.md: Geometry ("`caption` and `label2`" for group headers). Its contrast table lists `labelCool` under Increase Contrast as "not measured"; the measured figures are in the table below.
    - Both mockups, light and dark HTML: `.title`, `.sub`, `.c`, `.tot`, `.kinds .capt`, `.kinds .lab` → `--cool`; `.plate .chev`, `.kinds .tp`, `.num.zero`, `.li .g`, `.li .go` → `--cool2`; `.plate.sel .chev` → `--label`; `.idw` → `--cool`. M/mockup.html needs `--cool` and `--cool2` declared (C's `:13`, `:26`).
    - DESIGN.md `:678-717` (Speakers Sidebar and Pages) still describes the ember, gold and failure dots and the `systemGreen` mark, and `:497-513` (Speakers page) still describes the search caption. Rewrite both with the code, and add one sentence: the Speakers tab shows no sound, so its secondary ink is cool.
    - Stale, flag only: `AudioutWindowUI/AGENTS-HISTORY.md:278` says "the sidebar stay[s] stock", but the sidebar has drawn `label2`, `label3` and `ember` since before this change. Guard 12 blocks rewriting history lines.
    - `Tokens.swift:116-117` lists "subsection headers" as a `label3` job. After this change the sidebar's headers no longer use `label3`. No token changes.
    - Tests: one test that fails if a sidebar row, sidebar header or overview element is set in `label2`, `label3`, `ember` or `gold` (catches the brown coming back), on the pattern of `GroupsInkTemperatureTests`. Pin `labelCool` at 4.5:1 or better and `labelCool2` at 3:1 or better against `#2C2C2E`, beside the existing contrast pins.

## Contrast

WCAG 2.x, computed from the token hexes (script in the session scratchpad).
- Sidebar ground: `_sourceListBackgroundColor`, measured `#F6F6F6` at 80 % light and `#2C2C2C` at 90.2 % dark, composited over the window. Bracketed `#E8E8EA`–`#F8F8F8` light and `#1E1E20`–`#2C2C2E` dark. This is M's bracket with the light top raised to `#F8F8F8` (the colour over a white window); the worst case for each mode is unchanged.
- Grounds author no Increase Contrast value, so `warmDynamic` falls back to the standard hex (`Tokens.swift:1510-1512`).
- \* marks a system colour (`label`, `separator`, the two selection pills, the source-list ground). `NSAppearance(named:)` returns nil for both accessibility appearances, so their Increase Contrast forms can't be rendered offscreen. Those cells repeat the standard figure.

| Element | Token | Ground | Light | Light IC | Dark | Dark IC | Floor | Result |
|---|---|---|---|---|---|---|---|---|
| Section titles, subsection headers, unreachable names, "Shown while in use", divider label and glyph | `labelCool` | sidebar | 5.79–6.67 | 7.28–8.39 | 6.54–7.81 | 8.22–9.82 | 4.5 | pass |
| Unreachable icons | `labelCool2` | sidebar | 4.52–5.21 | 6.92–7.97 | 4.06–4.84 | 6.19–7.39 | 3 | pass (fails 4.5 in dark, so never text) |
| Reachable names and icons, plate titles and icons | `label` | sidebar | 12.76–14.26 | 12.76–14.26\* | 10.43–12.21 | 10.43–12.21\* | 4.5 | pass |
| Divider rule | `separator` | sidebar | 1.24 | 1.24\* | 1.34–1.36 | 1.34–1.36\* | none | the label carries it |
| Plate chevron, unselected | `labelCool2` | `raised` | 5.30 | 8.11 | 4.59 | 7.00 | 3 | pass |
| "Playing" fallback, unselected (Full / Subtle) | `goldText` | `raised` | 5.66 / 5.21 | 8.14 / 8.09 | 8.55 / 5.91 | 9.84 / 7.42 | 4.5 | pass |
| Any ink in a selected cell, list not focused | `label` | grey pill `#DCDCDC` / `#464646` | 11.65 | 11.65\* | 7.33 | 7.33\* | 4.5 | pass |
| Rejected for that state: `labelCool` | | grey pill | 5.16 | 6.50 | 4.43 | 5.57 | 4.5 | fails dark |
| Rejected for that state: `labelCool2` | | grey pill | 4.03 | 6.17 | 2.75 | 4.19 | 3 | fails dark |
| Rejected for that state: `goldText` (Full) | | grey pill | 4.31 | 6.19 | 5.12 | 5.89 | 4.5 | fails light |
| Any ink in a selected cell, list focused | `label`, drawn white by AppKit | accent pill `#0064E1` / `#0059D1` | 5.37 | 5.37\* | 6.27 | 6.27\* | 4.5 | pass |
| "Available", kind labels, "Unavailable" | `labelCool` | `raised` | 6.79 | 8.54 | 7.40 | 9.30 | 4.5 | pass |
| Count glyphs, row glyphs, Pair chevron | `labelCool2` | `raised` | 5.30 | 8.11 | 4.59 | 7.00 | 3 | pass |
| Zero counts (and an en dash, if the audit pass takes it) | `labelCool2` | `raised` | 5.30 | 8.11 | 4.59 | 7.00 | 4.5 | pass |
| Counts, row titles | `label` | `raised` | 14.46 | 14.46\* | 11.64 | 11.64\* | 4.5 | pass |
| Header caption "20 speakers" | `labelCool` | `panel` | 6.79 | 8.54 | 8.43 | 10.59 | 4.5 | pass |

## Touches other passes

- **Typeset.** Section titles, subsection headers and the "Shown while in use" caption now share `labelCool`, so weight and position separate them, never a warm ink. A subsection header that needs its own step takes `labelCool` at a heavier weight; `Tokens.Font.captionMedium` already lists section sub-headers among its jobs (`Tokens.swift:1294-1296`). If typeset reaches for `label2`, the brown comes back.
- **Layout.** If layout adds a bracket or rule spanning the four kind counts, it takes `containerEdge`. `hairline` is banned on `raised` (`Tokens.swift:258-261`). The spacer row versus top padding has no colour in it.
- **Audit.** The dark source-list ground is still unmeasured on a real window. At `#2C2C2E`, the worst end, `labelCool` measures 6.54 and `labelCool2` 4.06, so the old 2.99:1 worry about `rim` went with the dot. The still `meter` placeholder (1.59:1 light) is the audit pass's to fix; if it fixes it with an en dash, the dash is `labelCool2`. Selected-row ink (item 7) needs a check on macOS 14 (`scripts/run-on-vm.sh`). Setting `label` makes the result independent of the OS version, but only this Mac was measured.
- **Clarify.** The header text ("Hidden unless in use" or "Hidden unless playing") doesn't change any colour.

## Owner calls

1. **Speaker pages and the Main Audio page, same tab** (item 11). Default: change them in the same build, nine `label2` sites plus the `ListRowView` caption default. Otherwise clicking from Overview to a speaker switches the pane from cool captions to warm ones.
2. **The red "Can't be found" glyph on a speaker's page** (`DeviceDetailViewController.swift:216`, which M kept). You said "on this screen you don't have to show them in red", and the overview's row is already losing its red for `questionmark.circle`. Default: the speaker page matches the overview, with `questionmark.circle` in `labelCool2`. `failure` stays for real connection failures.
