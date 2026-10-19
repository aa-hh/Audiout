# Critique: Speakers tab, direction M

Method: dual-agent (A: a260ad1183db7a7ae · B: a0718ea842488df21). Run with impeccable `critique` on 2026-10-04. Code claims checked against `claude/speakers-nav` at 95f5fa60.

## Score

| # | Heuristic | Score | Key issue |
|---|---|---|---|
| 1 | Visibility of system status | 3 | Each number gets its own placeholder, which is clear. But the search can count as done before AirPlay answers, and numbers that look final then change. |
| 2 | Match with the real world | 3 | Plain words throughout. A paired Bluetooth speaker is counted "Unavailable" ("can't reach") while its own page says "Not connected", and Audiout can connect it. |
| 3 | User control and freedom | 2 | Forget asks first, but the sheet names nobody, and scene places don't come back. |
| 4 | Consistency and standards | 2 | A hollow `rim` ring means "connected" in the Mixer and "not reachable" in this sidebar. Unreachable rows dim to warm `label3` here but to cool `labelCool2` in the Mixer. |
| 5 | Error prevention | 2 | Forget can be offered for speakers that simply haven't answered yet. Right-click Forget has no wait at all. |
| 6 | Recognition rather than recall | 2 | You can't see which 6 of the 12 ringed rows can't be found without hovering each one. |
| 7 | Flexibility and efficiency | 2 | The counts are text only. Nothing takes you from "12 Unavailable" to those rows. |
| 8 | Aesthetic and minimalist design | 3 | Status line gone, zeros quieter, one card. Some redundancy: "Speakers" appears four times, and "1 This Mac" never changes. |
| 9 | Error recovery | 2 | With Local Network access off, the page shows a wall of Unavailable with no reason and no fix. |
| 10 | Help and documentation | 3 | Every count and the can't-be-found row have a tooltip, but only on hover. |
| **Total** | | **24/40** | **Acceptable.** Every fix below fits inside this direction; none needs a new one. |

## Design specificity

**Review:** it's made for this product. The counts come from `library.records`, so the header total equals the sidebar's row count by construction. The dot reuses the Mixer's `rim`, the placeholder reuses `meter`, and almost every string is one the app already ships. A row of counts in a card is a common form, and that's right for an app screen. The brief's file:line citations hold. The problems are in what the brief didn't trace: the Mixer's own use of the ring, the timing on a slow network, and the Bluetooth connect path.

**Detector:** 40 findings from the command line (exit 2), and 42 in the light browser scan / 37 in dark. None is a defect in the mocked window:
- 11 px text is AppKit's 11 pt small system font.
- The radii (10/12/26/999) are DESIGN.md's scale; the detector fails to match px against pt.
- The colours (close button, window shadow, white menu text, `#E9E9EA`) are drawn by AppKit.
- The truncation flag is the ellipsis a native text field draws.
- The tooltip overlap is how a native tooltip looks.

The real findings are all in the annotation notes around the window: 10.5 px captions, 4.4:1 note text in light, lines of about 125 characters, and "No success line: the zero is the answer." breaking the no-colon-reveal writing rule. One flag is worth keeping: "Move 2 (SONOS Bedroom)" and "Sonos Move (SONOS Kitchen)" truncate at 210 pt (see harden).

**Overlays:** the scan ran in a tab that was closed afterwards, so no overlay is visible now. Both servers it started are stopped, and the mockup's checksum didn't change.

## Against the owner's brief

| Ask | Verdict | Evidence |
|---|---|---|
| System Audio as its own highlighted section | **Met** | "System Audio" title, Main Audio on the same plate as Overview, a 16 pt gap. One gap: the plate doesn't say what Main Audio is doing, and he asked that people "see what it is". |
| A speakers section whose subsections read as belonging to it | **Partly** | It reads that way visually: title, plate, subsection headers stepped in 16 pt in quieter ink. But "Shown in Mixer" is styled exactly like the row caption "Shown while playing", and VoiceOver hears three flat groups, not a section with two parts. |
| Connected-colour two-state dot | **Met as worded, clashes in use** | Filled `rim` means reachable, a 2 pt `rim` ring means not reachable, and there is no red. But in the Mixer the hollow `rim` ring is the connected-and-silent mark (`RouteArmedDotView.swift:183-186`, `HaloRingView.swift:243-262`), and an unconnected speaker has no ring there at all. Problem 3. |
| Counts that add up: per kind available, plus one unavailable entry | **Met on the sums, not on the form** | 4 + 0 + 3 + 1 + 12 = 20 = the sidebar's rows, with 8 filled dots and 12 rings. He said "another row" for away speakers; M made it a fifth count beside the others, then added a second ring-marked line under it. Problem 4. |
| No "done looking" line | **Met** | Spinner, green check and "Done looking" are gone. The total "20 speakers" takes the slot. |
| Per-number loading shimmer | **Met** | One shared moving highlight, each number replacing its own placeholder, a Reduce Motion fallback. It's only as honest as the "known" rule under it (problem 1). |

## Problems, ranked

**1. [P1] The overview can show wrong numbers that look final.**
- How: `SpeakerSearch` arms its 0.5 s quiet window on the first live device (`SpeakersPageViewController.swift:75-84`). This Mac is there at once and Bluetooth arrives in one pass, so if Bonjour's first AirPlay answer takes longer than 0.5 s, the search ends without it.
- Scenario: a cold launch on a busy network. The page settles on "0 AirPlay · 0 Cast · 15 Unavailable", the shimmer stops, and it offers "9 speakers can't be found [Forget 9 speakers…]". Over the next second it creeps to 4 · 3 · 12. Since the shimmer stopping is now the only "done" signal, the wrong state looked final.
- The mockup's timeline (AirPlay known at 1.5 s, done at 2.1 s) only shows the case where it goes right.
- Fix: give the page its own rule. Arm the AirPlay and Cast trackers at launch, the way Bluetooth's is, with a longer quiet window (about 1.5 to 2 s). Fill Unavailable, the total and the can't-be-found row only when all four kinds are known or the 10 s ceiling passes. `speaker:library_counted` keeps firing from `SpeakerSearch.finish()`, unchanged.
- Command: harden.

**2. [P1] Forget acts on speakers the user can't pick out.**
- What changed: today the red triangle marks the can't-be-found speakers in the sidebar. M removes it (owner's ruling), so all 12 unreachable rows wear the same ring. The confirmation sheet names nobody: "Forget 6 speakers?" / "They will be removed from 2 scenes." (`MixerWindowController.swift:571-576`).
- Scenario: the owner keeps an Onkyo he only switches on for films. He can't tell whether it's one of the six without hovering 12 rows, and the sheet won't say either.
- Fix: the sheet names them, for example "teevee, Missing speaker, Onkyo TX-8220 and 3 more will be removed from 2 scenes." Then add one line that is true of the code: a forgotten speaker that comes back is listed again (`SpeakerLibraryController.swift:291`), but not in its scenes.
- Optional: clicking the row's title selects those rows in the sidebar using the standard multiple selection. The page still lists nothing.
- Command: clarify.

**3. [P1] The ring means opposite things in the Mixer and the sidebar.**
- Scenario: Kitchen HomePod is connected and silent, and in the Mixer its status dot is a hollow grey ring. Switch to Speakers and that ring now marks Bedroom, the speaker the Mac can't reach, while Kitchen has a filled dot. Same colour, same shape, same window, opposite meaning.
- He asked for "the connected design language". The brief took the Mixer's colour and turned its shape around.
- This needs the owner's decision before anyone builds. Options:
  - (a) Keep it as ruled and accept the clash.
  - (b) Unreachable rows draw no dot, matching the Mixer, where an unconnected speaker has no ring. The dimmed name and the spoken ", unavailable" carry the state, and the overview's Unavailable mark becomes a dimmed speaker glyph.
  - (c) Reachable rows draw the hollow ring and unreachable rows draw nothing.
- Option (b) or (c) contradicts his "unconnected is just the rim of the dot", so put it to him; don't decide it for him.

**4. [P2] Two ring-marked numbers stacked on top of each other invite adding them.**
- Scenario: "○ 12 Unavailable" in the strip, then "○ 6 speakers can't be found" right under it. A first-timer reads 18 unreachable speakers.
- The brief relies on the shared ring to signal "part of"; the same ring on two lines reads as "more of the same".
- He also asked for "another row".
- Fix: open question 1's alternative, with the can't-be-found count folded into that row (see Open questions).
- Command: layout.

**5. [P2] Paired Bluetooth speakers are called unreachable when the app can connect them.**
- Scenario: a JBL Flip 5 sits switched on and paired on the desk. The overview counts it in "12 Unavailable" with the help text "Speakers your Mac can't reach right now." Its own page says "Not connected" (`SpeakerLibraryController.swift:19, 120`). Clicking its Mixer row connects it (`BTConnectionManager.swift:49-59`).
- Fix: keep one Unavailable count, but make the words true:
  - Help text: "Speakers that are switched off, out of reach, or not connected."
  - A Bluetooth ring in the sidebar speaks ", not connected".
- Command: clarify.

**6. [P2] The brown he called depressing stays on 12 rows.**
- An unreachable row's name and icon dim to `label3` (`SidebarViewController.swift:1298-1300`), which is warm: `#6B6459` light, `#9E947F` dark (`Tokens.swift:129-131`). The subsection headers use the same ink.
- Warm Signal reserves warmth for wherever sound is going, and the Mixer dims an unavailable speaker to the cool `labelCool2` (`DeviceRowView.swift:1177`).
- Scenario: the dots go grey as he asked, but the owner's fleet still shows 12 brown names under them.
- Fix: dim unreachable rows to `labelCool2` (or `labelCool`) and re-measure contrast.
- Command: colorize.

**7. [P2] With Local Network access off, the page gives no reason.**
- Scenario: a user on macOS 15 declined Local Network. The page reads "0 · 0 · 0 · 1 | 16 Unavailable". Under open question 10's default, the can't-be-found row is hidden and nothing says why. He decides the app is broken.
- Fix: a "Local Network access is off [Open Privacy Settings…]" row, shown only when true, using the same pattern as the Bluetooth row. It reads the signal the popover already uses (`AppDelegate.swift:1389`).
- Command: harden.

**8. [P3] "Shown while playing" can appear when nothing plays.**
- The caption follows `isInUse`, which is also true for a speaker that is connecting, connected but silent, or in the current scene (`SpeakerLibraryController.swift:124-125, 292-297`). That's the same flaw the brief used to remove the gold dot. It also sits under a header that says "Hidden".
- Fix: "Shown while in use", matching the setting's own "Hide when not in use".
- Command: clarify.

## Persona red flags

- **Alex (power user):** the counts are dead text, so "12 Unavailable" can't select those rows to hide them in one go. "4 AirPlay" doesn't tell him he owns 9; a tooltip "4 of 9 AirPlay speakers available" would. Reachable and unreachable rows mix alphabetically, even though the library already sorts reachable first (`SpeakerLibraryController.swift:306-307`).
- **Sam (VoiceOver, keyboard):** "Speakers", "Shown in Mixer" and "Hidden unless playing" are three top-level groups, so the nesting is visual only. The 16 pt spacer is a real outline row that has to be kept out of VoiceOver and out of the arrow-key path; extra top padding on the "Speakers" title row needs neither. The placeholder under Reduce Motion is `meter` at 1.59:1 in light, below the 3:1 floor for non-text, and with motion off it's the only "still looking" cue.
- **Jordan (first-timer):** one view has three names for overlapping things: "Main Audio", "This Mac", "MacBook Pro Speakers". A filled grey dot can read as "offline" (open question 4), and there's no legend. He adds 12 and 6.
- **The household Mac user from PRODUCT.md** (several AirPlay speakers, a couple of Bluetooth ones, no audio vocabulary): their switched-on Bluetooth speaker shows as unreachable (problem 5). The only destructive offer on the page doesn't say what it removes (problem 2).

## Minor observations

- The 9 pt ring used as a row glyph is about half the optical size of the 16 pt symbols in the rows beside it, so the can't-be-found row looks lighter than Pair.
- "Available" sits left-aligned over AirPlay with nothing spanning the four counts, so it can read as AirPlay's own label.
- "Unavailable" is 60.3 pt in a 64.4 pt slot. Any longer translation breaks it. The own-row layout removes this.
- The new "Can't be found" row tooltip can block the system tooltip that shows a cut-off name in full. Keep `allowsExpansionToolTips` working on the name field.
- Right-click Forget isn't held until the search is done (`SidebarViewController.swift:388-391, 457-459`). Gate it with open question 3.
- The Overview plate opens a page titled "Speakers".
- Two rows called "casty" are told apart only by their icon. That's the owner's data, not the design's fault, but tooltips could add the kind.
- The moving highlight is new custom drawing. DESIGN.md's Don't list wants it named in `AudioutWindowUI/AGENTS.md`, which isn't in the brief's list of docs that change.
- Stock AppKit: nothing in M is web-only. The plates are `PlateRowView`. The five counts with a caption over four and a full-height divider map to `NSGridView` or nested `NSStackView`s. The highlight is a `CAGradientLayer` inside each placeholder, animating `position.x` from one shared `beginTime`. The selected-row ink reads `backgroundStyle`. The menus and tooltips are stock.

## Open questions: where I disagree with the default used

The defaults I don't list (2, 3, 5, 6, 7, 9, 11) I agree with.

1. **Unavailable: give it its own row.** He said "another row". One row below the four kind counts, "○ 12 unavailable", carries the can't-be-found part inline: "6 not seen since Audiout opened [Forget 6 speakers…]". This fixes problem 4, gives the four tiles about 97 pt each instead of 77.4, and when nothing is lost the card is the same height as M's version. At 0 the row reads "No speakers unavailable" in `label3`.
4. **Decide the dot before building, not in the live build.** The bigger risk is the clash with the Mixer (problem 3), not the chat-app reading.
8. **Give the page its own "known" rule** (problem 1). Leave the analytics trigger alone: the event keeps firing from `SpeakerSearch.finish()`. Only the page waits longer.
10. **Hide Forget, and also show the reason.** Add the "Local Network access is off" row (problem 7). Hiding the Forget row alone leaves 16 unexplained Unavailable.

## Recommended follow-up passes

First, before any pass: put problem 3 (the ring) and open question 1 (own row) to the owner.

1. **harden**
   - Replace the page's "known" rule as in problem 1 (AirPlay and Cast armed at launch, about 1.5 to 2 s quiet, 10 s ceiling; Unavailable, the total and the can't-be-found row only when all four kinds are known), without touching `speaker:library_counted`.
   - Hold right-click Forget and the "Can't be found" tooltip until the same point.
   - Add the Local Network access row.
   - Draw 0 speakers, about 60 speakers, the two long Sonos names, and a longer "Unavailable" translation.
2. **clarify**
   - Forget sheet names the speakers: first three, then "and N more", plus the "listed again if it comes back, not in its scenes" line.
   - Bluetooth wording: help text "switched off, out of reach, or not connected", spoken ", not connected" for Bluetooth rings.
   - "Shown while playing" becomes "Shown while in use".
   - Settle "Overview" plate against "Speakers" page title.
   - Decide whether the Main Audio plate gets a one-line caption saying what it's doing.
3. **layout**
   - Rebuild the card as four kind tiles under one "Available" caption that visibly spans them, then one Unavailable row with the can't-be-found count and Forget inline.
   - Replace the spacer outline row with top padding on the "Speakers" title row.
   - Size the 9 pt ring inside a 16 pt box so it sits optically level with the row symbols.
4. **audit** (accessibility)
   - VoiceOver structure: give "Shown in Mixer" and "Hidden unless playing" their parent "Speakers" (nest at zero indent, or carry it in the label).
   - Visual and spoken parity for can't-be-found.
   - Measure `rim` on the real dark source-list ground at 1x (2.99:1 at the dark end).
   - Under Reduce Motion, replace the 1.59:1 still placeholder with an en dash in `label3`.
   - Check that arrow keys skip the title rows.
5. **colorize**
   - Unreachable names and icons dim to the cool `labelCool2` the Mixer uses for Unavailable instead of warm `label3`, and so do the subsection headers. Warmth then stays where sound goes, and the brown leaves the sidebar.
   - Re-measure contrast on the source-list ground in all four modes.
   - If the Main Audio plate gains a caption, it takes gold only while audio flows.
6. **typeset**
   - The sidebar now has three 11 pt styles, and "Shown in Mixer" is identical to the row caption "Shown while playing".
   - Give the subsection header its own step, for example a heavier weight or `label2`, so it reads as a header and not a row note.
   - Check that the 16 pt semibold tabular counts and the quieter zeros hold their rhythm across all five panels.
7. **polish** (last)
   - After the owner's ring decision and the passes above: dark-mode plate edges, the "▭ speakers" header placeholder, tile baselines, the dot ink on both selection pills, and every state panel redrawn and re-rendered in light and dark.
