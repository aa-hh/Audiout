# Direction B: the Mixer's configuration twin

**Job and audience.** Someone at home opens Scenes › Speakers to decide which speakers the Mixer lists. Nothing here plays or connects.

**Thesis.** The Mixer minus its instruments: gold header with a "Show in Mixer" legend, the Mixer's transport subsections (This Mac first, Missing Speakers last, Pair Bluetooth speaker… closing the list), 42 pt single-line rows on its column grid. No rail, nodes, sliders or mute. Status sits right-aligned after the name; the choice fills the 140 pt trailing column.

**Control choice: small pop-up, not segmented.** "Hide when not in use" cannot fit a third of 140 pt, and the Mixer already puts a pop-up in that column (Main Audio's Output).

**Focal moment.** One column of choices under one legend. The only gold below the header is TV's status: TV is in use, so it stays visible whatever its choice.

**States.** Normal; selected rows (neutral wash, header legend becomes "2 selected" plus one pop-up, "Mixed" when choices differ, "Shown while in use" on a hidden in-use row); unavailable and not connected (cooler name ink); missing (no transport, no status); Bluetooth denied (second header note plus link button; unconnected Bluetooth rows absent); empty (This Mac plus the Pair row, never blank).

**Trade-offs.** Versus today: no table headers; the Mixer's type and rhythm instead. Versus A: no rounded containers or captions, so status must stay one or two words.

**Mapping.** `PopoverColumnGrid` columns, `DeviceIcon`, `DeviceRowView` ink rules, Mixer card/subsection headers (`PopoverPanelViewController`), `NSPopUpButton` (small), `NSTableView` selection, `SpeakerMixerVisibility`.
