# L: the Speakers page as counts

**Ask (Alec).** Too much space, unclear message. Counts by kind, a one-line "can't be found" row, and nothing stretched to the full height.

**Header.** 48 pt well, "Speakers". The caption line under it becomes the search result. The "20 speakers: 20 in the Mixer, 0 hidden" caption goes. The sidebar's "Hidden unless playing" group already shows the hidden ones.

| State | Caption line |
|---|---|
| Looking | small spinner, "Looking for speakers on your network… · 6 found so far" |
| Done, every speaker found | green mark, "All 20 speakers found" |
| Done, some away | green mark, "Done looking · ● 8 found · ○ 11 away" (the sidebar's own dots) |

**When looking counts as done.** The device list has not changed for 0.5 s (`DiscoverySettleTracker`, the same quiet window the popover's first open uses), with a ceiling so a network that never goes quiet still finishes. It is done once per launch. Whether every speaker is reachable doesn't affect it.

**One card** (`GroupedSectionView`, `.card`), top-aligned, ending at its last row:
1. Kinds row: glyph, count, label for each kind that has at least one: AirPlay (HomePod, Apple TV, AirPort Express, Sonos, other AirPlay), Bluetooth, Cast, This Mac, Unknown (a speaker whose kind was never learned). Every kept speaker is counted, lost ones included.
2. "Bluetooth access is off" + the existing action button. Shown only when true.
3. "N speaker(s) can't be found" + "Forget N speaker(s)…". Shown only when true, and only after looking is done.
4. "Pair Bluetooth speaker…" + chevron. Always shown.

Rows 2 to 4 are one line each (`ListRowView` with no caption). The sentences they used to carry move to the tooltip and the VoiceOver hint. The scene count is in the Forget confirmation already.

**Built from** `GroupsPaneLayout` spacing, `DeviceIconWellView`, `GroupedSectionView`, `ListRowView`, `SidebarPresenceDotView` (the caption's dots), `DeviceIcon` glyphs, `Tokens.Font.heading` (counts), `Tokens.Font.caption` + `Tokens.Color.label2` (labels and caption line), `Tokens.Color.failure` (lost glyph), `NSColor.systemGreen` (done mark). No new tokens.
