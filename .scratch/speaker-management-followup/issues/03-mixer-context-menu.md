# 03 Mixer row context menu: three visibility choices + "Speaker settings…"
Status: todo

`PopoverController.speakerVisibilityMenuItems(for:)`: offer When available, Always, Hide
when not in use (checkmark on current), then a separator and "Speaker settings…" that
calls the existing `onManageSpeakers`-style host hook but selects that speaker's detail
(`showSurface(.groups, selecting: .device(id))`). Analytics: capture at the choke point
if a visibility event already exists; otherwise add it to audiout-shared
`docs/analytics-events.md` first.
