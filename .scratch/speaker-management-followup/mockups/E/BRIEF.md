# Direction E: the Mixer's line, drawn as a lineup

**Thesis.** An ember rail hangs from a Mixer well, running down every speaker in Mixer order. A speaker the Mixer shows sits on the line; one it leaves out makes the line bend around it. The pop-up holds the rule; the node shows its result now.

**Focal moment.** The one bend, at hidden Onkyo. Changing a pop-up re-bends the line in 200 ms (instant under Reduce Motion).

**States.**
- Filled ember, on the line: the Mixer shows it now (This Mac; Always; When available and reachable).
- Small hollow ember, line bends around: the Mixer leaves it out now (hidden; When available but unreachable).
- Filled gold: shown and sounding. TV only; status "Playing now" in goldText. A hidden speaker that starts playing returns to the line in gold, "Shown while in use".
- Unreachable speakers set to Always stay on the line in cool ink. Missing shows no transport. The failure pill appears only when a speaker in use fails.

**Off the line.** The Bluetooth-denied note sits below the line's end with no node: it is not a speaker. Unconnected Bluetooth speakers disappear because the Mac cannot list them.

**Reuse.** `MembershipBusView` + `BusRailOverlayView` drawn as `GroupEditorViewController` draws an inactive scene: ember rail, filled or detoured nodes, gold armed node. Rows: `DeviceIconWellView`, small stock `NSPopUpButton`, `NSTableView` multi-select with a bulk pop-up reading Mixed and the existing context menu.

**Rules bent.** The rail means scene membership in the editor and Mixer visibility here. The node is drawing, never a checkbox, so the folder rule against membership controls doubling as visibility controls holds; DESIGN.md's rail entry needs a line naming this meaning. The Bluetooth button stays stock, not gold, keeping gold for sound.

**Trade-off.** Two rails, two meanings, one click apart.
