# E → E2: what moved and why

Three owner notes on E (2026-10-06). Everything E decided and these do not touch is unchanged: one column, no sidebar, no grid, scene rows in the Mixer's grammar with the magenta glow in the icon column, open in place, rename field plus "Change icon…", `CardMessageRow` delete, "Add scene" row opening the kept sheet, one scene open at a time.

## 1. The Source column and the Speakers count are gone

- The `FeedPillView` pills were the Mixer's routing objects on a tab where routing is not set. Dropped.
- "Playing" is now a status caption in the row's trailing slot: the gold `speaker.wave.2.fill` glyph and the word "Playing" in `goldText`, the editor header's existing badge (`buildPlayingBadge`) and the card's old meta clause, placed where a Mixer row puts a status caption while its controls are unavailable and where a membership row puts "Unavailable". Text in a caption slot reads as a fact; a pill in a column read as a setting. "Feeding Music" keeps the card's old wording in the same slot, in `labelCool`.
- The count column was not earning 40 pt once the names were in the caption. The count now leads the caption ("3 speakers · Bedroom HomePod unavailable · Office, Sonos Move"), so it is always visible and truncation only ever eats names at the tail. The card header loses its legends.

## 2. Boundaries, with the system's own parts

- **Between scene rows:** a 1 pt `hairline` divider starting at the icon column, `GroupedSectionView`'s `.bare` style (divider-only list; DESIGN.md records it unused today). Chosen over the row wash because a wash marks hover or selection, never structure, and over a `.card` per scene because a box is earned by holding a different instrument, and a folded scene row is the same instrument as its neighbours.
- **The open scene's fleet sits in a `GroupedSectionView` `.card`** mounted under the row the way the Mixer mounts its inset cards under a device row: starting at the icon column, 4 pt above and below, `control` radius. The checklist is a different instrument from the scene list, so it earns the box. In light `raised` is the ground, so the `containerEdge` outline is what draws the box; in dark the fill lifts it. The delete `CardMessageRow` sits under the card, outside it, so the card holds only membership.
- Checked in both appearances in the mock: hairlines at `#2A2E33` / `#CBCED4`, card edge at `#3D4247` / `#AEB3BB`.

## 3. The rail is dropped

Kept only if it carried something nothing else did. On this tab it carried two things: "how far down the scene reaches", which the checklist's ticks say row by row, and gold-versus-ember for playing, which the trailing caption now says in words. What it also said, a line in the Mixer's gutter, is "audio reaches these", and for a saved scene that is false. So membership is `MembershipRowView` in its plain checkbox form, the one the creation sheet already shows (`.systemSheet` host): creating and editing a scene now look the same. With the rail gone, E's one invention (a rail hooking out of a 26 pt row seat) goes with it, and the Mixer subsection headers inside the open scene go too, since they existed to make the rail read as the Mixer's; the rows keep the Mixer's order (This Mac first, then by name) so a speaker sits in the same place on both tabs.
