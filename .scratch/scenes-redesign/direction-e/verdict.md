# Scenes tab: verdict on A–D, and what E is

Judged in Operate mode against the owner's three complaints: Scenes must read as the sibling of Mixer and Speakers, the cards must stop feeling foreign, the editor must stop drifting.

## A · sibling of Speakers

**Best element.** The editor stops being a pushed page. It is the page: no "‹ Scenes" band, no Done, rename commits on focus loss. The delete lands where Speakers puts Forget. The empty state is honest and offers both ways a scene gets made.

**Why not as is.** A 210 pt sidebar for two to five names spends 30 % of the surface on chrome and hides the one thing a scene is, its members, behind a selection. The overview then says less than today's cards ("4 speakers" instead of who). A sidebar earns its width on Speakers because the fleet is long and stays selected while you work on a page; scenes are few and their content is wide.

**E takes:** the editor with no push and no Done; the "Add scene" bar at the end of the list, where Speakers puts it; the creation sheet kept.

## B · Mixer rows

**Best element.** One column in the Mixer's own grammar: the 42 pt row, the column grid, the `Speakers` and `Source` legends, and the Mixer's own `FeedPillView` pills saying "System" or "Music" on the scene they feed. That is the honest "playing" mark: the same pill, meaning the same thing, read-only in both places. Three scenes or eight, it is one list you read down.

**Why not as is.** Every scene row wears Main Audio's 34 pt ring and hook, so the tab shows three origins, and the Mixer's whole rail grammar rests on there being one. A ring on a Mixer row also means connection state, which a scene does not have. The card title going gold claims audio is coming out of rows that are configuration. Dropping the sheet into an unsaved row adds a state machine (leave the tab, Escape, zero members) to a surface visited rarely.

**E takes:** the whole list topology, the row anatomy, the pills, expand-in-place on `FoldAnimator`, the "Add scene" row built like the Mixer's Pair row, one scene open at a time.

## C · console plates

**Best element.** Every member named on the overview, on a short run of the Mixer's rail. The delete row with a caption ("Removes Downstairs from Scenes and from Main Audio's menu. Your speakers stay as they are.") is the clearest delete in the four. The Main Audio menu's two-line entries are a small, true improvement.

**Why not as is.** It is still a card grid, two columns of plates in a new custom cell under a new custom layout, which is the complaint restated with better cards. The push, the back band and Done all survive. An 8-member plate is 308 pt tall; eight scenes are a wall.

**E takes:** the unavailable member named first in the row's caption so truncation can never hide it; the delete caption's wording; the two-line menu entries as an open decision.

## D · patch bay

**Best element.** Editing is one click with every membership visible at once; nothing is behind a push. The speaker rows in the Mixer's order with the Mixer's subsection headers are the tightest tie to the Mixer on the speaker axis.

**Why not as is.** An 84 pt column cannot hold a scene's identity: names wrap, "Feeding" moves to a second table, rename, icon and delete live only in a context menu. Past five scenes the popover scrolls sideways, which no macOS menu-bar surface does. A first-time user sees a field of dots and has to learn that a line through a dot means membership.

**E takes:** the fleet inside an open scene in the Mixer's order under the Mixer's `AirPlay Speakers` / `Bluetooth Speakers` headers; the unavailable member's dimmed node on a line that still passes through it.

## What E decides

1. **One column, no sidebar, no grid.** Scenes are few and wide; the Mixer's list fits that. Width goes to names and pills, not to a sidebar of three rows (A) or 84 pt columns (D).
2. **A scene row is a Mixer row with the group's own identity, not Main Audio's.** The glyph sits in the icon column with `GroupIdentityGlowView` behind it, exactly as the Main Audio row draws a scene destination. No ring: rings mean connection state. One origin per tab.
3. **"Playing" is the pill, the ink and the rail, never a control.** `System` in `goldText` on the playing scene, `label` name ink, and, when that scene is open, a gold rail. The card title stays `label2`.
4. **The editor is the row opened in place.** The fleet folds out under the scene on `FoldAnimator`, indented, under the Mixer's subsection headers. The editor's own rail hooks out of the seat and runs down the gutter: gold on the playing scene, `ember` otherwise, the `unarmedLineTone` the editor sets today. Nodes are the editor's `MembershipBusView` checkboxes. One scene open at a time, so there is one rail, as on the Mixer.
5. **Rename and icon stay discoverable.** The open scene's name is the editor's `WarmNameFieldCell` (bordered plus pencil means editable, the module's rule), and a small `Change icon…` text action follows it, the Mixer header's "Manage speakers…" grammar. No action lives only in a context menu.
6. **Delete is a `CardMessageRow`** closing the open scene: the "saved as you go" line with one small `Delete scene…` button. The free-floating band is gone.
7. **Creation keeps the sheet.** The "Add scene" row and ⌘N open `GroupCreationSheetController` unchanged. Folding creation into an unsaved row is deferred as an open decision.
8. **Dropped from today:** the card grid, the dashed tile, member chips, the push, the back band, Done/Save, the 48 pt well on the overview. Every job they did has a home above.
