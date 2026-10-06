# M overview: the Speakers page, counts that add up

Made with impeccable `shape`. The owner brief (`../OWNER-BRIEF.md`) stood in for the interview, because this agent has no question tool. Also applied: the owner's 2026-10-04 ruling, relayed by the coordinator. "Available" means reachable on the network (reading (b) in the brief). A speaker the Mac can't find looks the same as one that is away, and nothing is drawn in red. Visual base: L (`../L/`), which the owner said looks really good.

Mockup: `mockup.html` (the moving highlight runs live; "Replay a launch" plays the fill-in order), `mockup.png`, `mockup-dark.png`. The PNGs park the highlight on one placeholder per strip, so a still frame shows it.

## Job

People open this page to answer "how many speakers do I have, and how many can I use right now?" Today it reads "Done looking · 8 found · 8 away", and the kind counts include speakers that can't be reached, so nothing adds up. After this change every number is a count of real rows in the sidebar, and the numbers add up to the header.

## Decisions

1. **Five entries, always, in one strip.** AirPlay · Bluetooth · Cast · This Mac, then a 1 pt `containerEdge` divider and **Away**. A kind with no speakers shows 0, so the strip never changes shape and always adds up. L hid empty kinds; with numbers filling in one at a time, a strip that grows tiles mid-search would jump.
2. **Each speaker is counted exactly once** (rule below). The header caption is the total: "20 speakers". 4 + 0 + 3 + 1 + 12 = 20 for the owner's fleet.
3. **"Unknown kind" goes in Away, and its tile is removed.** A record's kind is `nil` only when the Mac has neither a live device nor saved details for it (`SpeakerLibraryController.swift:302-303`: `kind: device?.kind ?? metadata?.kind`). So it never has a live device and can never be available. In practice it is a scene member saved before the library kept names.
4. **Away = away + can't be found** (owner ruling). The Away glyph is the sidebar's own not-reachable mark (`SidebarPresenceDotView` in its `.away` state, so it follows the sidebar ruling: a `rim` ring). The count of sidebar rings and the Away number therefore always match.
5. **Forget stays a separate row, shown only when true.** It acts on part of Away: the speakers that have **not appeared since Audiout opened**. A tile can't hold a button without breaking the strip's rhythm. The row sits directly under the strip, its glyph is the same ring, and its title is "Not seen since Audiout opened" with "Forget 6 speakers…". That makes it read as part of Away rather than as more speakers on top. The red triangle and "N speakers can't be found" go (owner ruling: no red).
6. **No search status line.** The spinner, "Looking for speakers…", the green check, "Done looking" and "All N speakers found" all go. While a number is unknown it shows a placeholder with a moving highlight (the owner's "shimmer"), and each number replaces its own placeholder when its category is known.
7. **Row order:** strip → Forget (only when true, only after the search) → Bluetooth access is off (only when true) → Pair Bluetooth speaker… (always). L had Bluetooth first. Forget moves up because it explains the number directly above it.
8. **A count of 0 draws in `label3`**, one step quieter than `label`, so the eye lands on the kinds that have speakers. The glyph and label ink are unchanged.
9. **Strip glyphs use the outline symbols**, so all five tiles share one stroke: `airplayaudio`, `radio` (the current Bluetooth glyph is `radio.fill`), `tv.and.hifispeaker` (currently `.fill`), `laptopcomputer`. The rows keep their own glyphs.

## The counting rule

For each record in `library.records`:

| Record | Goes to |
|---|---|
| `isLocalDevice` (`SpeakerLibraryController.swift:101`) | This Mac (the owner: "the Mac would always be connected") |
| otherwise `isAvailable` (`:105`) and kind `homePod`, `appleTV`, `airportExpress`, `sonos`, `generic` | AirPlay |
| otherwise `isAvailable` and kind `bluetooth` | Bluetooth (available = connected to this Mac) |
| otherwise `isAvailable` and kind `cast` | Cast |
| everything else, including kind `nil` | Away |

- **Header total** = `records.count`, which is every row the sidebar lists. The sum holds by construction.
- **Forget set** = Away records with `liveDevice == nil` (not seen since Audiout opened; `deviceRemoved` keeps a speaker that was seen and then dropped, `OutputBackend.swift:28-30`). Bluetooth records are left out while Bluetooth access is off (open question 1).

## When each number is known

There is no "finished" signal from the network, so "known" comes from timing. Events arrive one device at a time (`BackendEvent`, `OutputBackend.swift:24`).

| Category | Known when | Source in code |
|---|---|---|
| This Mac | the local output is in the device list. The backend adds it before any search starts, so in practice it is known at once | `NativeBackend.swift:2066` |
| Bluetooth | its live ids have not changed for 0.5 s, timed from launch (the tracker is started at once, so an empty list is also known after 0.5 s). macOS gives the whole list in one pass: Core Audio plus the paired list, sent once after start | `BTDeviceEnumerator.swift:124-125, 196-200`; `DiscoverySettleTracker.start()` `:47` |
| AirPlay | its live ids have not changed for 0.5 s after the first AirPlay speaker answers, or the whole search is done, whichever comes first. The tracker is not started early, because Bonjour answers arrive over time | `NativeDiscovery.swift:813-814` |
| Cast | same as AirPlay, for kind `cast` | `CastBrowser.swift:93` |
| Away, and the header total | the whole search is done (`SpeakerSearch.isDone`, rule unchanged: no change in live ids for 0.5 s, or the 10 s ceiling). Until then a remembered speaker may still answer, and a new one may still raise the total | `SpeakersPageViewController.swift:48-51, 75-91` |

After the search, every number is live for the rest of the launch. A speaker switching on or off changes the numbers in place with the 180 ms fade, and no placeholder comes back. A page first opened after the search has finished never shows a placeholder. Every placeholder lasts at least 0.5 s by construction, except This Mac's, which normally never draws, so no flicker rule is needed.

## States

| State | Header | AirPlay · Bluetooth · Cast · This Mac · Away | Rows |
|---|---|---|---|
| First launch, still counting | placeholder + "speakers" | placeholder · placeholder → 0 at 0.5 s · placeholder · 1 · placeholder | Pair |
| First launch, nothing on the network (done) | 1 speaker | 0 · 0 · 0 · 1 · 0 | Pair |
| Mid-search, owner's fleet, 1.5 s | placeholder + "speakers" | 4 · 0 · placeholder · 1 · placeholder | Pair (Forget waits for the search) |
| Done, some not reachable, owner's fleet | 20 speakers | 4 · 0 · 3 · 1 · 12 | Not seen since Audiout opened [Forget 6 speakers…], Pair |
| Done, every speaker reachable | 12 speakers | 7 · 2 · 2 · 1 · 0 | Pair |
| Bluetooth access off | 14 speakers | 6 · 1 · 2 · 1 · 4 | Not seen since Audiout opened [Forget 2 speakers…], Bluetooth access is off [Open Privacy Settings… / Allow Bluetooth…], Pair |
| After Forget | the total and Away drop by the number forgotten; the Forget row goes when the set is empty | | |

The owner's fleet: six paired Bluetooth speakers are switched off but listed by macOS, so they are away and not in Forget. Five AirPlay speakers and one with no saved kind have not appeared, so Forget offers those six.

## Tokens and geometry

Unchanged from L unless named. Pane width 443 (`SurfaceLayout.swift:13` 653 − `:17` 210). Column top `GroupsPaneLayout.columnTopInset` 28 (`GroupsPaneLayout.swift:42`), header `headerPadding` 16 (`:86`), icon to title 12 (`:88`), card gap `sectionGap` 20 (`:103`), column cap `contentMaxWidth` 415 (`:61`). Icon well 48 (`DeviceIconWellView.swift:66`).

- Card: `GroupedSectionView` `.card` (`GroupedSectionView.swift:73`), fill `raised` (`Tokens.swift:218`), edge and in-card dividers `containerEdge` (`Tokens.swift:295`, `GroupedSectionView.swift:170`), radius `Radius.panel` 26 (`Tokens.swift:1445`).
- Strip: inset 18 from the card edge (`ListRowView.leadingInset`, `ListRowView.swift:14`), 12 pt top, 11 pt bottom, five equal tiles. The Away tile carries a 1 pt `containerEdge` leading rule (inset 2 pt top and bottom) and 14 pt padding before its glyph. `hairline` is not allowed on `raised`.
- Tile: 16 pt glyph in `label2` (`ListRowView.glyph`, `ListRowView.swift:45`), 6 pt gap, count in `Tokens.Font.heading` (`Tokens.swift:1269`) with tabular digits, ink `label` (`Tokens.swift:94`), or `label3` (`:129`) for 0. Label 1 pt below, in `Tokens.Font.caption` (`:1286`) and `label2` (`:113`).
- Away glyph: `SidebarPresenceDotView` `.away`, 9 pt (`SidebarViewController.swift:952-955`), centred in the 16 pt glyph box. It draws whatever the sidebar ruling sets; the mockup shows a `rim` ring (`Tokens.swift:311`, 4.78:1 light, 3.39:1 dark on `raised`).
- Rows: `ListRowView`, 44 pt minimum (`ListRowView.swift:17`). The Forget row's glyph is the same 9 pt ring.
- Header caption: `caption` / `label2`, text "N speakers" ("1 speaker").
- Placeholder: fill `Tokens.Color.meter` (`Tokens.swift:327`; light `#C6C9CE` 1.59:1, dark `#464C55` about 1.75:1 on `raised`, with Increase Contrast values of its own). This is a second user of the meter's empty-track grey; the meaning carries over: a reading not taken yet. No new token.

## Motion

- **Placeholder.** For a count: 20 × 12 pt, corner radius 3, starting where the first digit will start (6 pt after the glyph) and centred on the count's 20 pt line. For the header: 16 × 8 pt, radius 2.5, 4 pt before "speakers".
- **Moving highlight.** One per page. A horizontal gradient 44 pt wide: clear, then the highlight colour, then clear. Highlight colour = `meter.blended(withFraction: 0.70, of: .white)` in light and `0.30` in dark, so in both appearances the highlight lightens the grey. It travels in pane coordinates from 44 pt before the leading edge to the trailing edge (443 pt) in **1.1 s**, timing `cubic-bezier(0.45, 0, 0.55, 1)`, then rests **0.5 s**: a **1.6 s** period, repeating. Each placeholder shows only the part of that one gradient that crosses it, so the light visibly runs left to right through the header and then the strip, AirPlay to Away. To build it: clip each placeholder to its bounds and give it a gradient sublayer animating `position.x` from `-44 - x` to `443 - x` (x = the placeholder's offset in the pane), key times [0, 0.6875, 1]. All placeholders share one `beginTime`, taken once when the first placeholder appears, so they stay in step.
- **Arrival.** The placeholder and the number crossfade in **180 ms**, `cubic-bezier(0.16, 1, 0.3, 1)`. Nothing moves and the number does not count up. That placeholder's animation is removed.
- **Stops.** The animation pauses while the page is off screen, and stops for good when the last placeholder fills.
- **Reduce Motion.** The highlight is never added: placeholders are plain `meter` fill and hold still. The 180 ms fade stays, since it is opacity only. Read `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` when placeholders appear, and follow live changes through `redrawOnAccessibilityDisplayChange()` (`AccessibilityDisplayRedraw.swift:33`), which already fires on that notification.

## Accessibility

- **Strip.** One group, labelled "Speaker counts". Each tile is one static-text element (the placeholder, glyph and label are not elements). Its label is the kind name and its value is:
  - AirPlay "4 available" / Bluetooth "0 available" / Cast "3 available" / This Mac "1 available"
  - Away "12 not available right now"
  - Any tile while counting: "still counting"
- **Header caption** value: "20 speakers", or "still counting".
- **When a number arrives**, post `.valueChanged` on that tile. VoiceOver speaks it only if focus is on it, so a focused user hears "3 available" and nobody else is interrupted.
- **When the search finishes**, if the window is key and the page is on screen, post one low-priority `.announcementRequested`: "Counted 20 speakers: 8 available, 12 not available right now." Nothing else is announced.
- **Help text** (tooltip and VoiceOver hint, like the rows):
  - AirPlay: "AirPlay speakers on your network right now."
  - Bluetooth: "Bluetooth speakers connected to this Mac right now."
  - Cast: "Cast speakers on your network right now."
  - This Mac: "This Mac's own output."
  - Away: "Speakers you've used that aren't available right now: switched off, out of range, or not seen since Audiout opened."
  - Forget row: "6 of the 12 away haven't appeared since Audiout opened." plus the existing scene sentence ("Forgetting them takes them out of 2 scenes.").
- **Increase Contrast.** `meter` already has Increase Contrast values, and the highlight fractions stay the same. Placeholders carry no information VoiceOver doesn't also give.
- **Keyboard.** No new focusable controls. Forget, Bluetooth access and Pair keep their current buttons.

## Builder notes

- **Analytics.** `speaker:library_counted` stays exactly as it is: same name, same nine properties from `SpeakerLibraryCounts.analyticsProperties` (`SpeakersPageViewController.swift:31-35`), and it still fires once from `SpeakerSearch.finish()` (`:86-91`). The page's five numbers and the Forget set are worked out beside those fields, never added to them.
- **`SpeakerSearch`** reports which categories are known and calls the page back when that changes. It needs one `DiscoverySettleTracker` each for Bluetooth (started at once), AirPlay and Cast (armed on first arrival); the overall rule is unchanged. The page's `isSearchDone` becomes that richer state.
  - Cheaper fallback, if per-kind tracking is not worth it: AirPlay and Cast fill with Away at search done. This Mac and Bluetooth still come first.
- **Removed:** the spinner, the green check, the caption dots, the Unknown tile, the red Forget glyph and its "can't be found" titles.
- **Test hooks to rewrite:** `test_subtitleText`, `test_kinds`, `test_discoveryShowsSpinner`.
- **Docs to change with the code.** These now describe the old page:
  - `AudioutWindowUI/AGENTS.md` map line ("search result, kinds, Bluetooth, lost, Pair")
  - DESIGN.md "Layout" → "Speakers page" paragraph
  - DESIGN.md "Speakers Sidebar and Pages" second-to-last paragraph, which still describes an even older subtitle and is already stale

## Open questions (recommended default first)

1. **Bluetooth speakers in Forget while access is off.** Without access, macOS does not list paired speakers (`BTDeviceEnumerator.swift:113-118`), so a remembered Bluetooth speaker looks never-seen, and today's page offers to forget it. Default: count it in Away but leave it out of Forget.
2. **The search can end before Bonjour answers.** This Mac and Bluetooth arrive at once and feed the overall tracker, so a slow network can hit the 0.5 s quiet window first. AirPlay and Cast then show 0 and update live. Default: leave the rule alone, because changing it moves when the analytics event fires. Alternative: feed only network speakers (`Device.Kind.isDiscoveredOverLocalNetwork`) to the overall tracker, and arm the 10 s ceiling at the first update. That is the coordinator's call.
3. **Kinds this Mac has never had.** Default: always show all five. Alternative: L's rule, hiding a kind the library has never held. It is quieter for someone with no Cast speakers, but tiles can then appear mid-search.
4. **Wording elsewhere.** The device page still says "Can't be found" (`DeviceDetailViewController.swift:20, 641`), and so does the sidebar's spoken label (`SidebarViewController.swift:1314`). Default: "Not seen since Audiout opened" in both, to match the no-warning ruling. That belongs to the sidebar and device-page briefs.
5. **Local Network access off.** Every network speaker then looks never-seen, and Forget would offer them all. Default: hide Forget while Local Network access is known to be off. This page has no Local Network row today, so this needs its own decision.
6. **The word "Away".** Default: keep it. It is the sidebar's word and fits the 83 pt tile. The alternative, "Not available", is longer and reads as a fault.
