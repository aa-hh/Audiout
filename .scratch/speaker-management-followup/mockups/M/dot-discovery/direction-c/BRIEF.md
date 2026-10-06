# Direction C: reachability shown by where a row sits

Made with impeccable `shape`. Inputs: `M/OWNER-BRIEF.md` (rulings at the end), `M/BRIEF.md`, `M/CRITIQUE.md`, `M/mockup.png`. No interview was possible, so the owner's rulings stand in for one; assumptions are marked. Line numbers are on `claude/speakers-nav` at 95f5fa60.

Mockup: `mockup.html`, `mockup.png`, `mockup-dark.png`. The 653 pt window shows the owner's 20 speakers after the search, Overview selected. Beside it: the divider row up close and how the overview's count maps to it, a speaker dropping off, launch, then selection and drag, and the three options set aside.

## The direction

No row carries a reachability mark. Inside each visibility group, reachable speakers come first, alphabetically. Under them, a divider row reads "8 unavailable", with a no-signal glyph and a rule, and the unreachable speakers follow it, alphabetically, in the Mixer's cool dim ink. The overview's fifth count wears the same glyph and equals the dividers added together (8 + 4 = 12).

Direction b changes the row. This one leaves the row alone and moves it.

## Options weighed

| Option | Verdict |
|---|---|
| **A. A divider row inside each group, always open** | **Chosen.** Reachability is read from position and the divider's words. The groups stay the Show in Mixer setting. Every speaker stays one click away. |
| B. A folded "N unavailable" row per group | Set aside. Your 20 rows would shrink to 8 plus 2, but a speaker set to Show even when unavailable is still in the Mixer, greyed (`SpeakerLibraryController.swift:124-129`), and would vanish from the sidebar. That breaks the rule that the first group never folds (`SidebarViewController.swift:1119-1124`), and puts its page, Forget and drag behind a click. |
| C. A trailing glyph on unreachable rows only, alphabetical order kept | Set aside. Nothing ever moves, which is its one strength. But it changes the row (direction b's ground), takes 18 pt from names, and for your fleet the "unusual" state is 12 of 20 rows, so it reads as a column of noise. It is the fallback if the moving rows below test badly. |
| D. One connectivity glyph shared with the overview | Folded into A: the divider's glyph is that glyph. |

## Sidebar

### Structure, top to bottom

System Audio title, Main Audio plate, 16 pt gap, Speakers title, Overview plate: all as M. Then, per group:

1. Group header ("Shown in Mixer" / "Hidden unless playing").
2. Reachable speakers, This Mac first, then alphabetical.
3. The divider row, only when the group has at least one unreachable speaker.
4. Unreachable speakers, alphabetical.

"Hidden unless playing" still folds as a whole through the stock Show/Hide, and its divider folds with it. A group whose speakers are all unreachable shows its divider directly under the header.

### The divider row

- 24 pt high. It is a child of its group like the speaker rows, so the outline treats it as part of the group.
- Glyph: SF Symbol `antenna.radiowaves.left.and.right.slash`, 11 pt, `Tokens.Color.labelCool`, centred in the 22 pt icon column. It is a shape, it is not red, it is not gold, and it is not a ring.
- Label: "N unavailable" ("1 unavailable"), `Tokens.Font.caption` (11 pt), `labelCool`, tabular digits, starting on the name column.
- Rule: 1 pt `Tokens.Color.separator` from 8 pt after the label to the trailing inset, vertically centred. It marks where the reachable rows end.
- Not selectable, no menu of its own. A drop on it goes to its group's header.

### Rows

- **The dot goes, for every row.** Reachable rows draw icon and name in `label`, as any source list does.
- Unreachable rows: name in `labelCool`, icon in `labelCool2`. Both are the Mixer's cool rungs, not the warm `label3` the critique flagged (problem 6).
- The dim is the second cue; position and the divider's words come first. In light mode the step from `label` to `labelCool` is small, and that is accepted.
- Can't-be-found speakers sit among the unavailable ones with no extra mark (no red, per the ruling). Their tooltip "Can't be found", the spoken ", can't be found", and the right-click Forget stay as M has them.

**Contrast**, on the sidebar ground bracketed as in M (`#E8E8EA`–`#F5F5F6` light, `#1E1E20`–`#2C2C2E` dark):

| Ink | Light | Light, Increase Contrast | Dark | Dark, Increase Contrast |
|---|---|---|---|---|
| `labelCool` (names, divider label and glyph) | 5.79–6.50 | not measured | 6.54–7.81 | not measured |
| `labelCool2` (icons, a graphic, 3:1 floor) | 4.52–5.08 | 6.92–7.77 | 4.06–4.84 | 6.19–7.39 |

`labelCool2` drops to 4.06:1 on the darkest dark ground, under the 4.5:1 text floor, so it is kept off text.

### Geometry

Dropping the 9 pt dot and its 7 pt gap gives names 16 pt back: the name column grows from 128 to 144 pt (210 − 18 leading − 22 icon − 8 gap − 18 trailing). "MacBook Pro Speakers" (139.9 pt) fits again.

Rows still truncate "Move 2 (SONOS Bedroom)" and "Sonos Move (SONOS Kitchen)".

New grid:
- x 18: titles, group headers, plate icons, speaker icons, the divider's glyph.
- x 48: names and the divider's label.

M stepped its group headers in 16 pt to line up with icons that sat after the dot. With the dot gone, the headers sit at x 18, still lined up with the icons. They are set in `caption` and `label2`, and the section titles keep `captionEmphasized`, so the two levels differ by weight.

## When rows move

The main risk, so the rules are exact.

1. **At launch, the split waits for the first search.** Until `SpeakerSearch` is done (`SpeakersPageViewController.swift:48-51, 75-91`, the moment M fills the overview's Unavailable count and total), each group is one alphabetical list with no divider.
   - A speaker that has not answered is dim, which is true: nothing has been seen of it.
   - A speaker that answers brightens in place.
   - When the search is done, the unseen rows slide under the new dividers in one move.
   - Splitting from the first frame would move a row up every time a speaker answered: 7 moves in 2 s on your fleet.
   - A window opened after the search never shows the move.
2. **Afterwards, the ink changes at once and the position follows.** A speaker that drops off dims immediately. Its row moves under the divider with the stock outline move animation (`moveItem(at:inParent:to:inParent:)` inside `beginUpdates`/`endUpdates`, about 0.25 s). The divider's count changes in the same update, and the divider is inserted or removed with it.
3. **Nothing moves under the user.** Moves wait while the pointer is over the sidebar, a context menu from it is open, or a drag is in progress. They apply together when that ends. The ink is already right, so the wait only delays position.
4. **No extra delay for speakers that blink off.** Removals already wait 3 s before they reach the list: AirPlay through `NativeDiscovery.defaultRemoveGrace` (`NativeDiscovery.swift:283`), Cast through `NativeBackend.defaultCastAbsenceGrace` (`NativeBackend.swift:1132`).
5. **Reduce Motion:** moves apply without the slide.
6. **Selection:** a selected row that moves stays selected and its page stays open. The list does not scroll to follow it.
7. **Forget:** forgotten rows are removed with the stock remove animation; the divider count drops, and the divider goes when its part is empty.

The library already sorts reachable speakers first (`SpeakerLibraryController.swift:306-307`). Today the sidebar re-sorts alphabetically (`SidebarViewController.swift:516-523`) and rebuilds with `reloadData` (`:538`), so no row has ever moved. Moving rows are what this direction adds.

## Drag, selection, keyboard, VoiceOver

- **Drag.** Unchanged: a drop anywhere in a group's rows lands on its header (`validateDrop`, `SidebarViewController.swift:1091-1097`). The divider forwards a drop on itself to its parent header. A dropped speaker lands in the matching part of its new group.
- **Multiple selection.** Shift-click ranges span the divider and skip it. Each group's unavailable speakers sit together, so selecting all of them for Hide or Forget takes one click and one shift-click, which the critique's power user asked for. No new control.
- **Keyboard.** Arrow keys skip the divider (`shouldSelectItem` returns false for it, as for headers, `:1134-1137`).
- **VoiceOver.** The divider is one static-text element, "8 unavailable speakers". Rows keep ", unavailable" and ", can't be found" (`:1312-1317`), because arrow-key navigation never lands on the divider.

## Overview

M's page with two glyph changes:
- **Unavailable**, the fifth count (owner's ruling), wears `antenna.radiowaves.left.and.right.slash` in `label2`, like the other count glyphs. Its number is the dividers added together.
- **The can't-be-found row** takes `questionmark.circle` instead of the ring. The strip and the row no longer share a mark, so "12" and "6 can't be found" stop reading as 18 (critique problem 4).

The counting rule, the shimmer, the strings and the analytics are M's, unchanged.

## Rulings check

| Ruling | Here |
|---|---|
| Filled/solid = reachable, in the connected colour family | No row draws a mark, so nothing contradicts it. The panel "Your filled mark kept" draws the `rim` disc on reachable rows only, on top of this structure, if you want the mark back. |
| No red, no gold | None in the sidebar. |
| Not colour alone | Position plus the divider's words and glyph carry it. The cool ink only supports them. |
| The Mixer's hollow ring keeps its meaning | No ring anywhere in the sidebar or the overview. |
| Neither the ring nor "no dot" | The rejected "no dot" was critique option (b): unreachable rows lose their dot but stay mixed in with the others, so dim ink alone carries the state. Here every row loses the dot, and the label says where the unreachable ones start. You may still read it as "no dot"; that is the second risk below. |
| No page re-lists the sidebar | The overview only counts. |
| The groups are the Show in Mixer setting | The split is inside each group. No speaker changes group because of reachability. |

## Risks

1. **Rows move.** A speaker's place depends on its state, so someone who finds rows by alphabetical memory looks in two places. Rules 1 to 3 under "When rows move" limit how often rows move, and stop them moving under the pointer, but they cannot remove it. If this tests badly, option C keeps the order fixed.
2. **"No dot" may read as what you already turned down.** The panel "Your filled mark kept" is the cheap answer: the same structure plus the filled `rim` disc on reachable rows only. It costs the 16 pt of name width back.
3. **The Mixer orders by kind, then name** (`PopoverController.swift:2022-2023`), and puts no unreachable speakers last. The sidebar's order and the Mixer's already differ today, so this adds no new mismatch, but it does not mirror the Mixer either.

## Builder notes

- `SidebarViewController.Node.Payload` gains a divider case carrying its count. It is not a group item: the header styling stays on the group headers. Not selectable, no menu.
- `reload(devices:presentationRecords:)` (`:512-548`): split each group on `SpeakerPresentationRecord.isAvailable` (or This Mac). Diff against the current tree and issue moves, inserts and removes instead of `reloadData` once the first search is done. Before then, keep the alphabetical single list. The sidebar reads the same "search done" signal as the overview (M's builder note on `SpeakerSearch`).
- Pointer hold: a tracking area on the sidebar's scroll view, menu-tracking notifications, and the drag session. Pending moves apply on exit.
- `validateDrop`/`acceptDrop` (`:1091-1105`): retarget a proposal on the divider to its parent header.
- Remove `SidebarPresenceDotView` (`:952` onward) and `dotState(for:)` (`:466-471`). The spoken suffixes stay.
- `SpeakersPageViewController`: the Unavailable tile glyph and the can't-be-found row glyph change. Nothing else.
- Analytics: no event changes. `speaker:library_counted` fires as in M.
- Docs that change with the code: DESIGN.md "Speakers Sidebar and Pages" (the dot paragraph, `DESIGN.md:678-694`); the `AudioutWindowUI/AGENTS.md` map line "Speaker list: presence dots" becomes "reachable first, divider, unavailable".
- Tests: `SidebarActionsTests.swift:123-124` pins dot states and goes. New tests cover the split, a divider that appears and disappears, the split held before search done, and moves held while the pointer is inside.

## Open questions for the owner

1. Is a moving row acceptable in exchange for one place to look? If not, option C.
2. Keep the filled `rim` disc on reachable rows as well (the "Your filled mark kept" panel)? Default: no.
3. Divider wording: "8 unavailable" (default, matches the overview's "Unavailable"), or "8 not available right now"?
4. Assumed: the pointer-hold rule needs no time limit, because the ink already tells the truth while a move waits. Say if a row left above the divider for a long stretch would bother you.
