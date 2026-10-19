# F: A's topology, E2's parts, no status

Owner's rulings, 2026-10-06: Scenes is a sibling of Speakers (direction A's sidebar plus page), and the tab shows what a scene contains, nothing about what is sounding.

## Kept from A

- The 210 pt sidebar lists the scenes with `SidebarViewController`'s parts: `SidebarHeaderCellView` for the one title, **Scenes**; `IconLabelCellView` rows; the stock selection pill; the bottom add bar reading **Add scene** (⌘N). Rows are the 12 pt taller row the Speakers sidebar uses for a captioned speaker; the caption is the count and nothing more ("3 speakers").
- The page is the editor. No push, no "‹ Scenes" band, no Done. Rename commits on Return or focus loss, so changing the selection commits it; Escape reverts.
- `PageHeaderView` at the rail-free 14 pt inset, level with a speaker's page: `DeviceIconWellView` with `GroupIdentityGlowView` behind it, the pencil badge opening `IconPickerViewController`, the `WarmNameFieldCell` field as the title, the count as the caption.
- A **Speakers** title (body, `label2`), then one `GroupedSectionView` `.card` at the `row` radius, the radius every box on a speaker's page takes.
- "Delete scene…" in an action band under the card, where the speaker page hangs Forget.
- The tab opens with the first scene selected, in saved order.

## Carried over from E2

- Membership rows are `MembershipRowView` in its plain checkbox form, the creation sheet's own rows: no rail, no nodes. The ticks say membership; nothing on the tab says where audio goes.
- The card's `containerEdge` dividers and the sidebar's stock separation carry the boundaries; the hairline-between-scenes idea has no job here because the sidebar is the list.
- The delete band is the saved-as-you-go line with one small button: "Changes are saved as you go." The second sentence ("They don't change what's playing now.") is status text and is gone.
- The creation sheet stays behind "Add scene" and ⌘N; the icon picker stays behind the well.

## Dropped, per ruling 2

- "Playing", "Feeding Music", the gold wave glyph, the gold well edge, `label`-versus-`labelCool` ink by playing state, and the playing note. Every name on the tab is `label`, every glyph `label`, every well edge `containerEdge`. The one state left is a fact about the scene's setup: a member the Mac can't reach keeps `MembershipRowView`'s own "Unavailable" ("Not connected" for Bluetooth) at the row's trailing edge, `labelCool` name and `labelCool2` glyph, and nothing else anywhere says so.
- "Change icon…" as a text action: the well's pencil badge is that affordance on a page; the text action existed only because a 26 pt row seat had no badge.

## Decided here

- **Where an unavailable member sits:** the card lists every speaker in the Speakers sidebar's order, This Mac first, then the speakers the Mac can reach by name, then the ones it can't by name, annotated. Same order as the list the user just left, and an unreachable speaker never splits the ones you can act on today.
- **Empty state, with no status to show:** the sidebar says "No scenes yet" under its title; the page opens with a plain well (`rectangle.3.group`, `isEditable` off), the title "Scenes" in `heading`, the caption "No scenes yet", then one `.card` of two `ListRowView` rows that say what a scene is and how it is made: "Add scene…" with a stock button and the caption "Pick the speakers that play together. You switch to a scene from Main Audio in the Mixer.", and "Or start from the Mixer" with the caption "Select speakers there, then choose Save selected speakers as scene from Main Audio's menu." No gold button: there is no call to action on a configuration tab, only two doors.
