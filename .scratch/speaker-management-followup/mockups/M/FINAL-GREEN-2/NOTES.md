# FINAL-GREEN-2: what changed from FINAL-GREEN

One view of the Speakers tab as it would ship after the owner's rulings on the green pass (OWNER-BRIEF.md, last section). `mockup.png` light, `mockup-dark.png` dark.

## Changed

- **Width 713 pt**, as main now draws it (`SurfaceLayout.width`, widened 2026-10-04). Content pane 443 → 503 pt; the page column 415 → 475 pt (`GroupsPaneLayout.contentMaxWidth` is derived from it). On the overview the four kind tiles take the extra 60 pt (92.4 pt each); Unavailable keeps its 77.4 pt minimum, as FINAL/BRIEF.md §2.3 builds the strip.
- **Header strip neutral, as today.** The green Speakers seat and the gold Mixer seat are gone: grey 18 % seat, `label` glyph and name, idle glyphs `label2`. The capsule now carries its `containerEdge` hairline and sits at x 26, as `SurfaceToolbarSeatButton.swift` draws it with the close button hidden.
- **Green equalizer mark restored** beside the Equalizer title on a shaped speaker (Sonos Move, "Bass 3 dB", Reset). It hides when the curve is flat, matching `refreshEQTitleRow()`.
- **Second speaker page added**: TV, flat curve ("Flat", no mark, no Reset), status "Connected", grey pill with focus in the page. The shaped speaker has the blue pill, as right after a click.
- **The three open green touches** are drawn exactly as FINAL-GREEN drew them, each with a numbered callout outside the window: 1 "Available" and counts above zero, 2 the plus on Pair Bluetooth speaker, 3 "Ready" / "Connected" on a speaker page.
- **Text matched to the code**: summary "Bass 3 dB" (`EQEditorView.gainText` prints no plus sign), readouts "3 dB", "0 dB", "Center" (FINAL-GREEN drew "+3 dB" and blank readouts).
- **Dropped**: the header comparison strips, sidebar pill crops, placement table, token box and Mixer-row crop. They argued points the owner has since ruled on.

## For the owner

- If 3 is kept alongside the kept mark, a shaped speaker's page shows the same green twice with two meanings: the Mac can reach it ("Ready") and its curve is shaped (the mark). The top-right window shows exactly that.

## Not edited

- `FINAL-GREEN/BRIEF.md` still specifies the coloured header seats (§1 "The header seat", §3 row 1, §5 items 11-13, §6 Surface Header Strip, §7 call 1) and the mark's removal (§2, §5 items 9-10 and 13-14, §6 Equalizer lines). Those parts no longer hold under the ruling.
