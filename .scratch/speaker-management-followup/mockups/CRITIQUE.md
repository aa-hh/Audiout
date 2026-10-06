# Speakers page: critique of A, B, C

Static mockups, reviewed in one pass; no detector run. B's dark PNG is identical to its light one, so B has no dark view.

All three repeat the seven speakers the sidebar already lists beside them. That second list is why the page reads as a second app, and why the overview and the detail feel unrelated.

| # | Heuristic | A | B | C |
|---|---|---|---|---|
| 1 | System status | 3 | 3 | 3 |
| 2 | Real-world match | 2 | 2 | 2 |
| 3 | Control and freedom | 1 | 3 | 3 |
| 4 | Consistency | 3 | 2 | 2 |
| 5 | Error prevention | 2 | 2 | 3 |
| 6 | Recognition | 2 | 3 | 2 |
| 7 | Efficiency | 2 | 3 | 2 |
| 8 | Minimalism | 2 | 2 | 3 |
| 9 | Error recovery | 2 | 2 | 2 |
| 10 | Help | 2 | 2 | 3 |
| | **Total /40** | **21** | **24** | **25** |

## A: scene-editor grammar
1. The choice is a caption, not a control. Changing it takes a right-click or a selection, so the page's one job is hidden.
2. There are five rounded containers for seven speakers, and three of them hold one row each. That is one card per item.
3. The wording drifts between "Always shown in Mixer", "Always in Mixer" and "Hidden from Mixer", and none of them matches the menu's "Hide when not in use".

**Keep:** icon wells and trailing captions, which make A look like the scene editor beside it.

## B: Mixer twin
1. It is the shipped page restyled: the same column of seven pop-ups the owner rejected.
2. Gold appears where no audio flows. The "Speakers" header is gold, and TV's "Connected" is gold text saying "playing" next to a word that says "connected".
3. Each row has two targets, a pop-up and a chevron. One-row sections carry collapse arrows.

**Keep:** the Mixer's transport order and the closing "Pair Bluetooth speaker…" row.

## C: list over inspector
1. The name "Bedroom" appears three times in one view: sidebar, list and inspector. The list adds nothing to the sidebar.
2. The choice is invisible until a row is selected. "Hidden" and a bare "Always" in the list need the inspector to explain them.
3. Bulk change lives in an inspector whose meaning shifts when several rows are selected, and the Equalizer sits below a draggable divider.

**Keep:** the caption "Bedroom stays in the Mixer while it's unavailable…". It is the only line in any of the three that says what a choice does.

## Unused design system parts
- **Membership rail and bus nodes:** fit. The scene editor already uses a gold rail with a filled node to mean "member" on a configuration-only screen.
- **Signal dot and ring states:** fit for live state only. They can mark TV as in use, never a saved setting.
- **Gold meaning "audio in the mix":** allowed on a speaker in use and on a call to action. Never on headers or status words.
- **Scene-card chips:** fit, as a summary strip of what the Mixer will show.
- **Failure pill** (glyph inside the `.well`): fits unavailable and missing rows, the same mark the Mixer uses.
- **`.well` recess:** fits, as a sunk area for hidden or away speakers.
- **Hybrid voice rule:** a console nameplate on the header is allowed; none used it.

## The mental model
The three-value menu bundles two questions: is this speaker in my Mixer, and should it stay there while it's away.

1. **Shown and Hidden lists**, with the hidden list sunk in a `.well`; moving a speaker between them is the whole interaction. *Risk:* a hidden speaker that is playing still needs somewhere to say "Shown while in use".
2. **The rail as the Mixer list:** a filled node means "in the Mixer". *Risk:* the same node means scene membership one click away.
3. **A switch plus "Keep showing when away".** Off = Hide when not in use, on = When available, on with the box ticked = Always. *Risk:* a switch reading off while the speaker sits in the Mixer because it is playing (Principle 2).
4. **The sidebar's Speakers row becomes the page.** Its child rows go, each row states where the speaker is ("Here now", "Away"), and the choice moves into detail. *Risk:* bulk change becomes a menu command you can't see.
5. **Forget a speaker.** Most "Always" choices exist to keep dead speakers around, so offer Forget on missing ones and default the rest to When available. *Risk:* forgetting a speaker removes it from scenes, so it needs undo and a count of affected scenes.

## Shortlist
1. **Rail as the Mixer list, with "Keep showing when away" as each row's trailing control (seeds 2 and 3).** Gold only on filled nodes and a speaker in use. Lens: impeccable `shape` plus `operate.md` consistency.
2. **The collection becomes the page, with Forget (seeds 4 and 5).** Remove the sidebar's speaker children. Lens: impeccable `distill` plus `design:design-critique` cognitive load.
3. **Shown and Hidden lists with a `.well` and a chip summary (seed 1).** Lens: `unslop-ui`, then `design-audit` on every gold mark.
